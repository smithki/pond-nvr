// Finding a path between two Ponds: RFC 8445's Interactive Connectivity Establishment, cut down to what two of
// Pond's own need. Each side has a
// username fragment and password, sent the other in the sealed offer and answer, and its candidates; every pair
// of a local candidate and a remote one of the same family is checked with a STUN binding request, signed with the
// other's password, best pair first, one new check every 20 ms. A request from an address not known yet is
// answered too, and that address checked straight back (a peer-reflexive candidate: how two routers that only let
// in what answers their own traffic are got through). The controlling side (the Pond being reached) waits a moment
// after the first pair works for a better one, then nominates the best: both use that pair from then on, checked
// every few seconds to keep the routers' mappings open and to know the other is still there. When either side's
// network changes, both restart: new credentials and candidates, checked again while the old pair still carries
// what's sent, until a new one is chosen.
//
// One socket a session: every check and, later, the media go from it, straight to the other or through a relay of
// one's own (TURN), so a pair is a route: a remote address, and whether it's through the relay. Everything happens
// on the agent's own queue; its callbacks are called there.
import Foundation

public final class PathFinder: @unchecked Sendable {
    public enum Role: Sendable { case controlling, controlled }

    /// A side's username fragment and password for this attempt (new ones on a restart).
    public struct Credentials: Codable, Hashable, Sendable {
        public var ufrag: String
        public var password: String

        public init(ufrag: String, password: String) {
            self.ufrag = ufrag
            self.password = password
        }

        public static func make() -> Credentials {
            let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            func random(_ n: Int) -> String { String((0 ..< n).map { _ in letters.randomElement()! }) }
            return Credentials(ufrag: random(8), password: random(24))
        }
    }

    public enum State: Equatable, Sendable {
        case new
        case checking
        case connected(CandidatePair)
        /// No path found in time, or the connection lost: what was seen, for a diagnosis.
        case failed(Report)
        case closed
    }

    /// What an attempt saw.
    public struct Report: Equatable, Sendable {
        /// Pairs checked, and those that worked.
        public var checked = 0, worked = 0
        /// Whether any check of the other's reached this side.
        public var heardFromPeer = false
        /// Addresses the other side saw this one at (from its answers): this side's public addresses.
        public var seenAs: Set<STUNAddress> = []
        /// A connection that was there, and went (the other stopped answering).
        public var lost = false

        public init(checked: Int = 0, worked: Int = 0) {
            self.checked = checked
            self.worked = worked
        }
    }

    public struct Timing: Sendable {
        /// Between new checks; a check's first wait for an answer, and how many tries it gets (each waiting twice as
        /// long); after the first pair works, how long to wait for a better one before nominating.
        public var pace = 0.02, firstWait = 0.1, tries = 6, nominationWait = 0.25
        /// Keeping the chosen pair: a check this often; lost after this long without an answer.
        public var keepAlive = 5.0, lostAfter = 30.0
        /// No path in this long: failed.
        public var giveUp = 15.0

        public init() {}
    }

    public let role: Role
    public private(set) var local: Credentials
    let transport: PacketTransport
    let timing: Timing
    let tiebreaker = UInt64.random(in: 0 ... .max)
    private let queue = DispatchQueue(label: "pond.pathfinder")
    private var timer: DispatchSourceTimer?

    private var remote: Credentials?
    private var hosts: [Candidate] = []
    private var remotes: [Candidate] = []
    private var pairs: [Pair] = []
    private var triggered: [Route] = []
    private var transactions: [[UInt8]: Transaction] = [:]
    private var nominatedByPeer: Set<Route> = []
    private var nominating: Route?
    private var selected: CandidatePair?
    /// The relay, if there is one (its allocation asked for with `allocate`).
    private var relay: TURNClient?
    /// Looking for a new pair while the chosen one carries on (after a restart).
    private var restarting = false
    private var report = Report()
    private var started: Date?
    private var firstWorked: Date?
    private var lastAnswer = Date()
    private var nextKeepAlive = Date()
    /// Where it's got to (safe to read from anywhere).
    public var state: State { stateLock.withLock { current } }
    private var current: State = .new
    private let stateLock = NSLock()

    /// Told of each change of state (on the agent's queue).
    public var stateChanged: (@Sendable (State) -> Void)?
    /// What the other sends on the chosen pair that isn't STUN (on the agent's queue).
    public var received: (@Sendable ([UInt8]) -> Void)?

    /// Where a pair's packets go: the other's address, straight or through the relay.
    struct Route: Hashable {
        var remote: STUNAddress
        var relayed: Bool
    }

    struct Pair {
        var pair: CandidatePair
        var state: PairState
        var key: Route { Route(remote: pair.remote.address, relayed: pair.local.kind == .relay) }
    }

    enum PairState { case waiting, inProgress, succeeded, failed }

    struct Transaction {
        enum Purpose {
            case check(Route, nominate: Bool)
            case keepAlive(Route)
            case probe(@Sendable (STUNAddress?) -> Void)
        }
        var purpose: Purpose
        var bytes: [UInt8]
        var to: STUNAddress
        /// Through the relay (a check on a relayed pair).
        var relayed = false
        var tries: Int
        var wait: Double
        var next: Date
        /// Each wait twice the last (a check: a path may only open later), or the same (a probe: cheap, and soon).
        var backsOff = true
    }

    public init(role: Role, transport: PacketTransport, timing: Timing = Timing()) {
        self.role = role
        self.transport = transport
        self.timing = timing
        local = .make()
        transport.receive { [weak self] bytes, from in
            guard let self else { return }
            queue.async { self.arrived(bytes, from: from) }
        }
        // Ticking from the start: a probe before the checks begin is retried (and given up on) too.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: timing.pace)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    // MARK: What's known

    /// This side's own candidates: its host (and relay) ones are checked from; all are sent the other.
    public func addLocal(_ candidates: [Candidate]) {
        queue.async { [self] in
            hosts += candidates.filter { ($0.kind == .host || $0.kind == .relay) && !hosts.contains($0) }
            pairUp()
        }
    }

    /// The other side's credentials and candidates (more may come later, with `addRemote`).
    public func setRemote(_ credentials: Credentials, candidates: [Candidate]) {
        queue.async { [self] in
            remote = credentials
            add(candidates)
        }
    }

    public func addRemote(_ candidates: [Candidate]) { queue.async { [self] in add(candidates) } }

    private func add(_ candidates: [Candidate]) {
        for candidate in candidates where !remotes.contains(where: { $0.address == candidate.address }) {
            remotes.append(candidate)
        }
        pairUp()
    }

    /// Every remote candidate paired with this side's best own address of its family, and with its relayed one (if
    /// there is one), best pair first.
    private func pairUp() {
        guard remote != nil else { return }
        for candidate in remotes {
            let family = hosts.filter { $0.address.isIPv6 == candidate.address.isIPv6 }
            for relayed in [false, true] {
                let route = Route(remote: candidate.address, relayed: relayed)
                guard !pairs.contains(where: { $0.key == route }),
                      let mine = family.filter({ ($0.kind == .relay) == relayed }).max(by: { $0.priority < $1.priority }) else { continue }
                pairs.append(Pair(pair: CandidatePair(local: mine, remote: candidate), state: .waiting))
            }
        }
        let controlling = role == .controlling
        pairs.sort { $0.pair.priority(controlling: controlling) > $1.pair.priority(controlling: controlling) }
    }

    // MARK: Running

    /// Checks begin (as soon as there are pairs), until connected, failed, or closed.
    public func start() {
        queue.async { [self] in
            guard state == .new else { return }
            started = Date()
            set(.checking)
        }
    }

    deinit { timer?.cancel() }

    /// Stopped, and its socket closed. (Not from its own callbacks: they run on its queue.)
    public func close() {
        queue.sync {
            timer?.cancel()
            timer = nil
            for (_, t) in transactions { if case let .probe(done) = t.purpose { done(nil) } }
            transactions = [:]
            relay?.close()
            set(.closed)
        }
        transport.close()
    }

    /// Starting over, for a network that changed: new credentials (returned, for the other side), no candidates
    /// (`addLocal` and `setRemote` again with the new ones), checks from scratch; the chosen pair, if there is one,
    /// carries on (and is kept alive) until a new one is chosen. Not connected yet: as a new attempt.
    public func restart() -> Credentials {
        queue.sync {
            local = .make()
            remote = nil
            hosts = []
            remotes = []
            pairs = []
            triggered = []
            transactions = transactions.filter { if case .probe = $0.value.purpose { true } else { false } }
            nominating = nil
            nominatedByPeer = []
            firstWorked = nil
            started = Date()
            report = Report()
            if selected != nil {
                restarting = true
            } else if state != .closed {
                set(.checking)
            }
            return local
        }
    }

    /// Bytes to the other side, on the chosen pair (none chosen yet: dropped).
    public func send(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard let selected else { return }
            route(bytes, to: selected.remote.address, relayed: selected.local.kind == .relay)
        }
    }

    /// The address a STUN server sees this side's socket at (its public one, behind a router), or nil.
    public func probe(_ server: STUNAddress, timeout: Double = 3) async -> STUNAddress? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                // (Answered once: the transaction goes with its answer, or when it's given up on.) Sent again every
                // 100 ms until then: a lost request or answer costs a tenth of a second, not the probe.
                let request = STUNMessage(type: STUNMessage.bindingRequest)
                transactions[request.transaction] = Transaction(purpose: .probe { continuation.resume(returning: $0) },
                                                                bytes: request.encoded(), to: server,
                                                                tries: max(1, Int(timeout / 0.1)), wait: 0.1, next: Date(),
                                                                backsOff: false)
                transmit(request.transaction)
            }
        }
    }

    /// A relayed address asked of a relay (TURN), as a candidate for this side; and the public address the relay saw
    /// this side at. Nil if the relay refused or didn't answer (`relayProblem` says which). Add it with `addLocal`.
    public func allocate(_ server: TURNClient.Server) async -> (relayed: Candidate, seenAs: STUNAddress?)? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let transport = self.transport
                let client = TURNClient(server: server) { bytes, to in transport.send(bytes, to: to) }
                relay = client
                client.allocate { relayed in
                    continuation.resume(returning: relayed.map { (Candidate(kind: .relay, address: $0), client.mapped) })
                }
            }
        }
    }

    /// Why the relay refused, or that it didn't answer.
    public var relayProblem: String? { queue.sync { relay?.problem } }

    /// Bytes on their way: straight to `to`, or through the relay.
    private func route(_ bytes: [UInt8], to: STUNAddress, relayed: Bool) {
        if relayed { relay?.send(bytes, to: to) } else { transport.send(bytes, to: to) }
    }

    private func set(_ new: State) {
        guard new != state else { return }
        stateLock.withLock { current = new }
        stateChanged?(new)
    }

    private func tick() {
        let now = Date()
        relay?.tick(now)
        // Answers not come: tried again, or given up on.
        for (id, t) in transactions where now >= t.next {
            if t.tries > 0 {
                transmit(id)
            } else {
                transactions.removeValue(forKey: id)
                timedOut(t)
            }
        }
        if restarting {
            checkNext()
            nominateIfReady(now)
            // None found in time: the old pair kept, if it still answers (its keep-alives say).
            if let started, now.timeIntervalSince(started) > timing.giveUp { restarting = false }
        }
        switch state {
        case .checking:
            checkNext()
            nominateIfReady(now)
            if let started, now.timeIntervalSince(started) > timing.giveUp {
                fail()
            }
        case let .connected(pair):
            if now >= nextKeepAlive {
                nextKeepAlive = now.addingTimeInterval(timing.keepAlive * Double.random(in: 0.8 ... 1.2))
                let route = Route(remote: pair.remote.address, relayed: pair.local.kind == .relay)
                sendCheck(to: route, purpose: .keepAlive(route))
            }
            if now.timeIntervalSince(lastAnswer) > timing.lostAfter {
                report.lost = true
                fail()
            }
        default:
            break
        }
    }

    private func fail() {
        selected = nil
        set(.failed(report))
    }

    /// The next check: one the other's request asked for first, else the best pair waiting.
    private func checkNext() {
        let key: Route
        if let next = triggered.first {
            triggered.removeFirst()
            key = next
        } else if let waiting = pairs.first(where: { $0.state == .waiting }) {
            key = waiting.key
        } else {
            // Nothing's worked and nothing's left to check: the pairs that failed get another round, until the time's
            // up (on a lossy network, or before the other side's router had opened, all of a check's tries can go).
            if !pairs.isEmpty, pairs.allSatisfy({ $0.state == .failed }) {
                for i in pairs.indices { pairs[i].state = .waiting }
            }
            return
        }
        guard let i = pairs.firstIndex(where: { $0.key == key }), pairs[i].state != .inProgress, pairs[i].state != .succeeded else { return }
        pairs[i].state = .inProgress
        report.checked += 1
        sendCheck(to: key, purpose: .check(key, nominate: false))
    }

    /// The controlling side, once a pair has worked and a moment has passed (or nothing's left to check): the best
    /// pair that worked, nominated.
    private func nominateIfReady(_ now: Date) {
        guard role == .controlling, nominating == nil, let firstWorked else { return }
        let pending = pairs.contains { $0.state == .waiting || $0.state == .inProgress }
        guard now.timeIntervalSince(firstWorked) >= timing.nominationWait || !pending,
              let best = pairs.first(where: { $0.state == .succeeded }) else { return }
        nominating = best.key
        sendCheck(to: best.key, purpose: .check(best.key, nominate: true))
    }

    private func sendCheck(to route: Route, purpose: Transaction.Purpose) {
        guard let remote, let mine = hosts.first(where: { $0.address.isIPv6 == route.remote.isIPv6 && ($0.kind == .relay) == route.relayed })
        else { return }
        var attributes: [STUNMessage.Attribute] = [
            .init(STUNMessage.Attribute.username, Array("\(remote.ufrag):\(local.ufrag)".utf8)),
            .init(STUNMessage.Attribute.priority, STUNMessage.be32(Candidate.priority(.prflx, mine.address))),
            .init(role == .controlling ? STUNMessage.Attribute.iceControlling : STUNMessage.Attribute.iceControlled, Self.be64(tiebreaker)),
        ]
        if case .check(_, nominate: true) = purpose { attributes.append(.init(STUNMessage.Attribute.useCandidate, [])) }
        let request = STUNMessage(type: STUNMessage.bindingRequest, attributes: attributes)
        transactions[request.transaction] = Transaction(purpose: purpose, bytes: request.encoded(integrity: Array(remote.password.utf8)),
                                                        to: route.remote, relayed: route.relayed, tries: timing.tries,
                                                        wait: timing.firstWait, next: Date())
        transmit(request.transaction)
    }

    /// A transaction's request sent (again), its next wait twice as long.
    private func transmit(_ id: [UInt8]) {
        guard var t = transactions[id] else { return }
        route(t.bytes, to: t.to, relayed: t.relayed)
        t.tries -= 1
        t.next = Date().addingTimeInterval(t.wait)
        if t.backsOff { t.wait *= 2 }
        transactions[id] = t
    }

    private func timedOut(_ t: Transaction) {
        switch t.purpose {
        case let .check(key, nominate):
            if let i = pairs.firstIndex(where: { $0.key == key }) { pairs[i].state = .failed }
            if nominate { nominating = nil }
        case .keepAlive:
            break   // (lost only after `lostAfter` without any answer)
        case let .probe(done):
            done(nil)
        }
    }

    // MARK: What arrives

    private func arrived(_ bytes: [UInt8], from: STUNAddress) {
        // The relay's: its own answers (taken by it), or a peer's packet it passed on.
        if let relay, from == relay.server.address {
            if let (data, peer) = relay.handle(bytes) { arrived(data, from: Route(remote: peer, relayed: true)) }
            return
        }
        arrived(bytes, from: Route(remote: from, relayed: false))
    }

    private func arrived(_ bytes: [UInt8], from: Route) {
        guard STUNMessage.looksLikeSTUN(bytes) else {
            if let selected, from == Route(remote: selected.remote.address, relayed: selected.local.kind == .relay) { received?(bytes) }
            return
        }
        guard let message = try? STUNMessage(bytes) else { return }
        switch message.type {
        case STUNMessage.bindingRequest: request(bytes, from: from)
        case STUNMessage.bindingSuccess, STUNMessage.bindingError: answer(message, bytes, from: from)
        default: break
        }
    }

    /// The other side's check: answered (if it's signed with this side's password, for this side), its address
    /// learned if it's new, and checked back.
    private func request(_ bytes: [UInt8], from route: Route) {
        let from = route.remote
        guard let message = try? STUNMessage(bytes, integrity: Array(local.password.utf8)),
              let username = message.attribute(STUNMessage.Attribute.username).map({ String(decoding: $0, as: UTF8.self) }),
              username.hasPrefix(local.ufrag + ":") else { return }
        let answer = STUNMessage(type: STUNMessage.bindingSuccess, transaction: message.transaction, attributes: [
            .init(STUNMessage.Attribute.xorMappedAddress, from.xorEncoded(transaction: message.transaction)),
        ])
        self.route(answer.encoded(integrity: Array(local.password.utf8)), to: from, relayed: route.relayed)
        report.heardFromPeer = true
        if case .connected = state, !restarting { return }
        if !remotes.contains(where: { $0.address == from }) {
            let priority = message.attribute(STUNMessage.Attribute.priority).flatMap { $0.count == 4 ? STUNMessage.be32($0, 0) : nil }
            remotes.append(Candidate(kind: .prflx, address: from, priority: priority))
            pairUp()
        }
        let nominated = message.attribute(STUNMessage.Attribute.useCandidate) != nil && role == .controlled
        if nominated { nominatedByPeer.insert(route) }
        guard let i = pairs.firstIndex(where: { $0.key == route }) else { return }
        if pairs[i].state == .succeeded {
            if nominated { select(pairs[i].pair) }
        } else if pairs[i].state != .inProgress, !triggered.contains(route) {
            // Checked straight back (its answer may be what opens this side's router to it).
            pairs[i].state = .waiting
            triggered.append(route)
        }
    }

    /// An answer to one of this side's requests.
    private func answer(_ message: STUNMessage, _ bytes: [UInt8], from route: Route) {
        let from = route.remote
        guard let t = transactions[message.transaction] else { return }
        if case let .probe(done) = t.purpose {
            transactions.removeValue(forKey: message.transaction)
            done(message.attribute(STUNMessage.Attribute.xorMappedAddress).flatMap { STUNAddress(xorEncoded: $0, transaction: message.transaction) })
            return
        }
        // A check's answer: signed with the other's password, and from where it was sent (else it's not this pair).
        guard let remote, from == t.to, route.relayed == t.relayed,
              (try? STUNMessage(bytes, integrity: Array(remote.password.utf8))) != nil else { return }
        transactions.removeValue(forKey: message.transaction)
        guard message.type == STUNMessage.bindingSuccess else {
            timedOut(t)
            return
        }
        lastAnswer = Date()
        if let seen = message.attribute(STUNMessage.Attribute.xorMappedAddress).flatMap({ STUNAddress(xorEncoded: $0, transaction: message.transaction) }) {
            report.seenAs.insert(seen)
        }
        guard case let .check(key, nominate) = t.purpose, let i = pairs.firstIndex(where: { $0.key == key }) else { return }
        if pairs[i].state != .succeeded { report.worked += 1 }
        pairs[i].state = .succeeded
        if firstWorked == nil { firstWorked = Date() }
        if nominate || (role == .controlled && nominatedByPeer.contains(key)) { select(pairs[i].pair) }
    }

    private func select(_ pair: CandidatePair) {
        guard selected == nil || restarting else { return }
        restarting = false
        selected = pair
        lastAnswer = Date()
        nextKeepAlive = Date().addingTimeInterval(timing.keepAlive)
        set(.connected(pair))
    }

    static func be64(_ v: UInt64) -> [UInt8] { (0 ..< 8).map { UInt8((v >> (56 - 8 * UInt64($0))) & 0xFF) } }
}
