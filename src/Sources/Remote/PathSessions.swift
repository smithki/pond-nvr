// Connecting two paired Ponds: a path found between them (PathFinder), its offer and answer sent sealed through the
// signaling service. The one connecting (a device, or another Pond) sends an offer: its credentials and its own
// addresses, at once; then its public addresses as STUN tells it them. The Pond being reached answers likewise,
// from its fixed port if one's set, and nominates the path (it's the controlling side). Only paired peers' offers
// are answered (RemoteHost opens nothing else).
//
// When this Mac's network changes (NWPathMonitor), a session's path is found again: the connecting side restarts
// (new credentials and candidates, sent as `path.restart`, answered with `path.restarted`), the old path carrying
// on until a new one is chosen; the side being reached asks it to (`path.nudge`).
//
// In M3 a session is the path alone: `connect` measures the round trip with a few pings over it and ends it. M4
// keeps sessions open (`open`), for the encrypted session that carries video.
import Foundation
import Network
import Traversal

public final class PathSessions: @unchecked Sendable {
    public struct Settings: Sendable {
        /// Where to learn this Mac's public addresses (none: not asked, as in mesh mode).
        public var stun: [STUNAddress] = []
        /// The port the Pond being reached answers from (nil: any).
        public var port: UInt16?
        public var shareLocalAddresses = true
        public var mode: Gatherer.Mode = .direct
        /// A relay of one's own: its addresses, and the shared secret this side's credentials are made from.
        public var relay: (addresses: [STUNAddress], secret: String)?
        /// This side's name in the relay's usernames.
        public var name = "pond"
        public var timing = PathFinder.Timing()

        public init() {}
    }

    /// How a connection went.
    public struct Outcome: Sendable {
        public var pair: CandidatePair?
        public var report: PathFinder.Report?
        /// The round trip over the path (seconds), and how long finding it took.
        public var roundTrip: Double?
        public var took: Double
        public var problem: String?
        /// Why no path was found, and what would fix it.
        public var diagnosis: String?

        /// In a few words, without the addresses: "connected over IPv4, through the routers' public addresses, 23 ms".
        public var summary: String {
            if let problem { return problem }
            guard let pair else { return diagnosis ?? "no path found" }
            let family = pair.remote.address.isIPv6 ? "IPv6" : "IPv4"
            let how = switch pair.remote.kind {
            case .host: "on the same network, or straight to its own address"
            case .srflx, .prflx: "through the routers' public addresses"
            case .relay: "through the relay"
            }
            let trip = roundTrip.map { String(format: ", %.0f ms there and back", $0 * 1000) } ?? ""
            return "connected over \(family), \(how)\(trip) (found in \(String(format: "%.1f", took)) s)"
        }
    }

    enum Message {
        static let offer = "path.offer", answer = "path.answer", candidates = "path.candidates", end = "path.end"
        static let restart = "path.restart", restarted = "path.restarted", nudge = "path.nudge"

        struct Offer: Codable {
            var session: UUID
            var credentials: PathFinder.Credentials
            var candidates: [Candidate]
        }

        struct More: Codable {
            var session: UUID
            var candidates: [Candidate]
            /// With the last of them: what the side learned about its network.
            var facts: NetworkFacts?
        }

        struct End: Codable {
            var session: UUID
        }
    }

    final class Session: @unchecked Sendable {
        let id: UUID
        let peer: RemotePeer
        let finder: PathFinder
        /// The socket's port (its candidates gathered again on it after a restart).
        let port: UInt16
        /// Its relayed address, once the relay's given one (offered again after a restart).
        var relayed: Candidate? { get { lock.withLock { _relayed } } set { lock.withLock { _relayed = newValue } } }
        private var _relayed: Candidate?
        /// The other's answer (nil: none came, or the session ended first); and to the latest restart.
        let answer = OneShot<Message.Offer?>()
        var restartAnswer: OneShot<Message.Offer?> { get { lock.withLock { _restartAnswer } } set { lock.withLock { _restartAnswer = newValue } } }
        private var _restartAnswer = OneShot<Message.Offer?>()
        var connectedAt: Date?
        /// What each side learned about its network (the other's as it sent it).
        var mine: NetworkFacts { get { lock.withLock { _mine } } set { lock.withLock { _mine = newValue } } }
        var theirs: NetworkFacts? { get { lock.withLock { _theirs } } set { lock.withLock { _theirs = newValue } } }
        private var _mine = NetworkFacts(), _theirs: NetworkFacts?
        private let lock = NSLock()

        init(id: UUID, peer: RemotePeer, finder: PathFinder, port: UInt16) {
            self.id = id
            self.peer = peer
            self.finder = finder
            self.port = port
        }
    }

    let settings: Settings
    /// A sealed message to a peer: true if it was passed on.
    let send: @Sendable (_ kind: String, _ body: Data, _ to: RemotePeer) async -> Bool
    let log: @Sendable (String) -> Void
    private var sessions: [UUID: Session] = [:]
    private let lock = NSLock()

    /// Pings and their answers over a path (M3's only traffic on it; M4's session starts with other bytes).
    static let ping: UInt8 = 0xFE, pong: UInt8 = 0xFD

    private let network = NWPathMonitor()
    private var lastNetwork: String?

    public init(settings: Settings, send: @escaping @Sendable (String, Data, RemotePeer) async -> Bool,
                log: @escaping @Sendable (String) -> Void) {
        self.settings = settings
        self.send = send
        self.log = log
        // This Mac's network changing (another network joined, an address renewed): every path found again.
        network.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let now = path.availableInterfaces.map(\.name).sorted().joined(separator: ",") + "/\(path.status)"
            let changed = lock.withLock { () -> Bool in
                defer { lastNetwork = now }
                return lastNetwork != nil && lastNetwork != now
            }
            guard changed, path.status == .satisfied else { return }
            for session in lock.withLock({ Array(sessions.values) }) where session.connectedAt != nil {
                Task { await self.restart(session) }
            }
        }
        network.start(queue: DispatchQueue(label: "pond.paths.network"))
    }

    deinit { network.cancel() }

    // MARK: Connecting

    /// A path to `peer` found (or not, and what was seen), its round trip measured, and let go.
    public func connect(to peer: RemotePeer) async -> Outcome {
        var (outcome, session) = await open(to: peer)
        guard let session else { return outcome }
        defer { end(session, tell: true) }
        outcome.roundTrip = await roundTrip(session.finder)
        log("remote: \(peer.name): \(outcome.summary)")
        return outcome
    }

    /// A path to `peer` found, and kept (until `close`): the session, and how it went; or no session, and why.
    func open(to peer: RemotePeer) async -> (Outcome, Session?) {
        let start = Date()
        guard let socket = try? UDPSocket() else { return (Outcome(took: 0, problem: "no UDP socket could be opened"), nil) }
        let finder = PathFinder(role: .controlled, transport: socket, timing: settings.timing)
        let session = Session(id: UUID(), peer: peer, finder: finder, port: socket.port)
        lock.withLock { sessions[session.id] = session }
        var kept = false
        defer { if !kept { end(session, tell: true) } }

        let hosts = Gatherer.hosts(port: socket.port, mode: settings.mode)
        finder.addLocal(hosts)
        session.mine = facts(hosts)
        let offer = Message.Offer(session: session.id, credentials: finder.local, candidates: settings.shareLocalAddresses ? hosts : [])
        log("remote: connecting to \(peer.name)…")
        guard await send(Message.offer, Self.encode(offer), peer) else {
            return (Outcome(took: Date().timeIntervalSince(start), problem: "\(peer.name) isn't connected to the signaling service"), nil)
        }
        Task { await self.trickle(session) }
        Task {
            try? await Task.sleep(for: .seconds(10))
            session.answer.resolve(nil)
        }
        guard let theirs = await session.answer.value else {
            return (Outcome(took: Date().timeIntervalSince(start), problem: "\(peer.name) didn't answer"), nil)
        }
        finder.setRemote(theirs.credentials, candidates: theirs.candidates)
        finder.start()
        let state = await settled(finder)
        guard case let .connected(pair) = state else {
            if case let .failed(report) = state {
                let why = Diagnosis.explain(mine: session.mine, theirs: session.theirs, report: report, peer: peer.name)
                log("remote: no path to \(peer.name). \(why)")
                return (Outcome(report: report, took: Date().timeIntervalSince(start), diagnosis: why), nil)
            }
            return (Outcome(took: Date().timeIntervalSince(start), problem: "the attempt was stopped"), nil)
        }
        session.connectedAt = Date()
        kept = true
        return (Outcome(pair: pair, took: Date().timeIntervalSince(start)), session)
    }

    /// A session let go (the other side told).
    func close(_ session: Session) { end(session, tell: true) }

    /// The session's path found again (this Mac's network changed): the connecting side restarts and tells the
    /// other its new credentials and candidates; the side being reached asks the connecting side to.
    func restart(_ session: Session) async {
        guard lock.withLock({ sessions[session.id] != nil }) else { return }
        if session.finder.role == .controlling {
            _ = await send(Message.nudge, Self.encode(Message.End(session: session.id)), session.peer)
            return
        }
        log("remote: the network changed: finding the path to \(session.peer.name) again")
        let waiting = OneShot<Message.Offer?>()
        session.restartAnswer = waiting
        let (credentials, hosts) = restartFinder(session)
        let offer = Message.Offer(session: session.id, credentials: credentials, candidates: settings.shareLocalAddresses ? hosts : [])
        guard await send(Message.restart, Self.encode(offer), session.peer) else { return }
        Task { await self.trickle(session) }
        Task {
            try? await Task.sleep(for: .seconds(10))
            waiting.resolve(nil)
        }
        if let theirs = await waiting.value {
            session.finder.setRemote(theirs.credentials, candidates: theirs.candidates)
        }
    }

    /// The finder restarted, with this Mac's addresses gathered again.
    private func restartFinder(_ session: Session) -> (PathFinder.Credentials, [Candidate]) {
        let credentials = session.finder.restart()
        let hosts = Gatherer.hosts(port: session.port, mode: settings.mode)
        session.finder.addLocal(hosts)
        session.mine = facts(hosts)
        return (credentials, hosts)
    }

    /// This side's public addresses, sent as they're learned (none in mesh mode); then what it learned about its
    /// network: asked again at each server's next port, a router that shows a different port for it is one that
    /// changes port for every destination.
    private func trickle(_ session: Session) async {
        var seen: Set<STUNAddress> = []
        var facts = session.mine
        for server in settings.stun {
            guard let address = await session.finder.probe(server) else { continue }
            facts.learnedPublic = true
            if facts.changesPort == nil, server.port < .max,
               let other = await session.finder.probe(STUNAddress(ip: server.ip, port: server.port + 1), timeout: 1),
               other.ip == address.ip {
                facts.changesPort = other.port != address.port
            }
            guard seen.insert(address).inserted else { continue }
            let more = Message.More(session: session.id, candidates: [Candidate(kind: .srflx, address: address)])
            _ = await send(Message.candidates, Self.encode(more), session.peer)
        }
        // A relayed address, asked of the relay once a session (and offered whatever else is shared: it's the relay's).
        if let relay = settings.relay, case .direct = settings.mode {
            facts.relay = true
            if let relayed = session.relayed {
                session.finder.addLocal([relayed])
                _ = await send(Message.candidates, Self.encode(Message.More(session: session.id, candidates: [relayed])), session.peer)
            } else {
                let (username, password) = TURNClient.credentials(secret: relay.secret, name: settings.name)
                for address in relay.addresses {
                    guard let (relayed, _) = await session.finder.allocate(.init(address: address, username: username, password: password))
                    else { continue }
                    session.relayed = relayed
                    session.finder.addLocal([relayed])
                    _ = await send(Message.candidates, Self.encode(Message.More(session: session.id, candidates: [relayed])), session.peer)
                    break
                }
                if session.relayed == nil { facts.relayProblem = session.finder.relayProblem ?? "the relay didn't answer" }
            }
        }
        session.mine = facts
        _ = await send(Message.candidates, Self.encode(Message.More(session: session.id, candidates: [], facts: facts)), session.peer)
    }

    /// What this side knows of its network from its own addresses (the rest comes from STUN).
    private func facts(_ hosts: [Candidate]) -> NetworkFacts {
        var facts = NetworkFacts()
        facts.globalIPv6 = hosts.contains { $0.address.isIPv6 }
        if case .mesh = settings.mode {
            facts.mesh = true
            facts.meshAddress = !hosts.isEmpty
        }
        return facts
    }

    private func settled(_ finder: PathFinder) async -> PathFinder.State {
        let deadline = Date().addingTimeInterval(settings.timing.giveUp + 2)
        while Date() < deadline {
            switch finder.state {
            case .connected, .failed, .closed: return finder.state
            default: try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return finder.state
    }

    /// The median of a few pings' round trips over the path.
    private func roundTrip(_ finder: PathFinder) async -> Double? {
        final class Pongs: @unchecked Sendable {
            let lock = NSLock()
            var at: [UInt8: Date] = [:]
        }
        let pongs = Pongs()
        finder.received = { bytes in
            guard bytes.count == 2, bytes[0] == Self.pong else { return }
            pongs.lock.withLock { pongs.at[bytes[1]] = Date() }
        }
        var trips: [Double] = []
        for n in UInt8(0) ..< 5 {
            let sent = Date()
            finder.send([Self.ping, n])
            for _ in 0 ..< 50 where pongs.lock.withLock({ pongs.at[n] == nil }) { try? await Task.sleep(for: .milliseconds(10)) }
            if let back = pongs.lock.withLock({ pongs.at[n] }) { trips.append(back.timeIntervalSince(sent)) }
        }
        return trips.isEmpty ? nil : trips.sorted()[trips.count / 2]
    }

    // MARK: What arrives

    /// A path message from a paired peer.
    func handle(kind: String, body: Data, from peer: RemotePeer) {
        switch kind {
        case Message.offer:
            guard let offer = try? JSONDecoder().decode(Message.Offer.self, from: body) else { return }
            answer(offer, from: peer)
        case Message.answer:
            guard let answer = try? JSONDecoder().decode(Message.Offer.self, from: body),
                  let session = lock.withLock({ sessions[answer.session] }), session.peer == peer else { return }
            session.answer.resolve(answer)
        case Message.candidates:
            guard let more = try? JSONDecoder().decode(Message.More.self, from: body),
                  let session = lock.withLock({ sessions[more.session] }), session.peer == peer else { return }
            if !more.candidates.isEmpty { session.finder.addRemote(more.candidates) }
            if let facts = more.facts { session.theirs = facts }
        case Message.end:
            guard let end = try? JSONDecoder().decode(Message.End.self, from: body),
                  let session = lock.withLock({ sessions[end.session] }), session.peer == peer else { return }
            self.end(session, tell: false)
        case Message.restart:
            // The connecting side's network changed: this side starts over too, and answers.
            guard let offer = try? JSONDecoder().decode(Message.Offer.self, from: body),
                  let session = lock.withLock({ sessions[offer.session] }), session.peer == peer else { return }
            let (credentials, hosts) = restartFinder(session)
            session.finder.setRemote(offer.credentials, candidates: offer.candidates)
            let reply = Message.Offer(session: session.id, credentials: credentials, candidates: settings.shareLocalAddresses ? hosts : [])
            Task {
                _ = await send(Message.restarted, Self.encode(reply), peer)
                await trickle(session)
            }
        case Message.restarted:
            guard let answer = try? JSONDecoder().decode(Message.Offer.self, from: body),
                  let session = lock.withLock({ sessions[answer.session] }), session.peer == peer else { return }
            session.restartAnswer.resolve(answer)
        case Message.nudge:
            guard let nudge = try? JSONDecoder().decode(Message.End.self, from: body),
                  let session = lock.withLock({ sessions[nudge.session] }), session.peer == peer else { return }
            Task { await restart(session) }
        default:
            break
        }
    }

    /// The side being reached: a session for the offer, answered, and its checks begun.
    private func answer(_ offer: Message.Offer, from peer: RemotePeer) {
        guard lock.withLock({ sessions[offer.session] == nil }) else { return }
        var socket = settings.port.flatMap { try? UDPSocket(port: $0) }
        if socket == nil, let port = settings.port { log("! remote: UDP port \(port) is in use: answering from another") }
        if socket == nil { socket = try? UDPSocket() }
        guard let socket else { return log("! remote: no UDP socket could be opened") }
        let finder = PathFinder(role: .controlling, transport: socket, timing: settings.timing)
        let session = Session(id: offer.session, peer: peer, finder: finder, port: socket.port)
        lock.withLock { sessions[offer.session] = session }
        let hosts = Gatherer.hosts(port: socket.port, mode: settings.mode)
        finder.addLocal(hosts)
        session.mine = facts(hosts)
        finder.setRemote(offer.credentials, candidates: offer.candidates)
        // Pings answered; the session let go once found and used, or failed.
        finder.received = { [weak finder] bytes in
            if bytes.count == 2, bytes[0] == Self.ping { finder?.send([Self.pong, bytes[1]]) }
        }
        finder.stateChanged = { [weak self, weak session] state in
            guard let self, let session else { return }
            switch state {
            case let .connected(pair):
                session.connectedAt = Date()
                self.log("remote: \(peer.name) connected over \(pair.remote.address.isIPv6 ? "IPv6" : "IPv4") (\(pair.remote.kind))")
            case let .failed(report):
                self.log("remote: no path to \(peer.name). "
                    + Diagnosis.explain(mine: session.mine, theirs: session.theirs, report: report, peer: peer.name))
                Task { self.end(session, tell: false) }
            default:
                break
            }
        }
        finder.start()
        let reply = Message.Offer(session: offer.session, credentials: finder.local,
                                  candidates: settings.shareLocalAddresses ? hosts : [])
        Task {
            _ = await send(Message.answer, Self.encode(reply), peer)
            await trickle(session)
        }
        // (A session nobody ends is let go after a minute.)
        Task {
            try? await Task.sleep(for: .seconds(60))
            self.end(session, tell: false)
        }
    }

    // MARK: Ending

    private func end(_ session: Session, tell: Bool) {
        guard lock.withLock({ sessions.removeValue(forKey: session.id) }) != nil else { return }
        session.answer.resolve(nil)
        session.finder.close()
        if tell {
            let body = Self.encode(Message.End(session: session.id))
            Task { _ = await send(Message.end, body, session.peer) }
        }
    }

    static func encode(_ value: some Encodable) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }

    /// Where to ask STUN (or a relay): "host:port", or a host alone (`port`), a name looked up, IPv4 and IPv6 alike.
    public static func resolve(_ server: String, port fallback: UInt16 = 3478) -> [STUNAddress] {
        let host: String, port: String
        if server.hasPrefix("["), let close = server.lastIndex(of: "]") {
            host = String(server[server.index(after: server.startIndex) ..< close])
            port = String(server[server.index(after: close)...].dropFirst())
        } else if let colon = server.lastIndex(of: ":"), server.filter({ $0 == ":" }).count == 1 {
            host = String(server[..<colon])
            port = String(server[server.index(after: colon)...])
        } else {
            host = server
            port = String(fallback)
        }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &found) == 0 else { return [] }
        defer { freeaddrinfo(found) }
        var addresses: [STUNAddress] = []
        var next = found
        while let entry = next {
            defer { next = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var ip = a.sin_addr
                addresses.append(STUNAddress(ip: withUnsafeBytes(of: &ip) { Array($0) }, port: UInt16(bigEndian: a.sin_port)))
            case AF_INET6:
                let a = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var ip = a.sin6_addr
                addresses.append(STUNAddress(ip: withUnsafeBytes(of: &ip) { Array($0) }, port: UInt16(bigEndian: a.sin6_port)))
            default:
                continue
            }
        }
        return Array(Set(addresses))
    }
}

/// A value that comes once, awaited before or after it does (the first one given is kept).
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value?
    private var given = false
    private var waiting: [CheckedContinuation<Value, Never>] = []

    func resolve(_ value: Value) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Value, Never>] in
            guard !given else { return [] }
            given = true
            result = value
            defer { self.waiting = [] }
            return self.waiting
        }
        for w in waiting { w.resume(returning: value) }
    }

    var value: Value {
        get async {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> Value? in
                    if given { return result }
                    waiting.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}
