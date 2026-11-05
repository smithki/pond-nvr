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
// `open` keeps a session open, for the encrypted channel that carries requests and video; `connect` only finds a
// path, measures its round trip with a few pings and ends it (`pond remote connect`).
import CryptoKit
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
        /// Each session's link made worse on purpose (demo mode's slow second home); nil for a real one.
        public var shape: ShapedTransport.Shape?

        public init() {}

        /// A session's socket, shaped if asked.
        func transport(_ socket: DatagramSocket) -> PacketTransport {
            shape.map { ShapedTransport(socket, shape: $0) } ?? socket
        }
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
        /// Found in mesh mode (its addresses the tunnel's).
        public var mesh = false
        /// The other end isn't connected to the signaling service at all (off, or offline): not a path problem.
        public var absent = false

        /// In a few words, without the addresses: "connected over IPv4, through the routers' public addresses, 23 ms".
        public var summary: String {
            if let problem { return problem }
            guard let pair else { return diagnosis ?? "no path found" }
            let family = pair.remote.address.isIPv6 ? "IPv6" : "IPv4"
            let how = switch pair.remote.kind {
            case .host: mesh ? "over your mesh" : "on the same network, or straight to its own address"
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
            /// The public half of the side's one-time key, for the session's keys (SessionKeys); none on a restart,
            /// which keeps them.
            var exchange: Data?
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

    /// A session with a paired peer: its path, its keys, and (once connected) its control channel.
    public final class Session: @unchecked Sendable {
        public let id: UUID
        public let peer: RemotePeer
        let finder: PathFinder
        /// The socket's port (its candidates gathered again on it after a restart).
        let port: UInt16
        /// This side's one-time key, and the session's keys once the other's public half is known.
        let oneTime = Curve25519.KeyAgreement.PrivateKey()
        var keys: SessionKeys? { get { lock.withLock { _keys } } set { lock.withLock { _keys = newValue } } }
        private var _keys: SessionKeys?
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
        weak var owner: PathSessions?

        /// The control channel, from when the session first connects (it carries on across restarts).
        var channel: SecureChannel? { lock.withLock { _channel } }
        private var _channel: SecureChannel?
        /// Requests asked, waiting for their replies (by id).
        private var replies: [UInt64: OneShot<ChannelMessage?>] = [:]
        private var nextRequest: UInt64 = 1
        /// Pings' answers (`connect`'s round trip), by their number.
        private var pongs: [UInt8: Date] = [:]
        /// Video for this side (SRTP and SRTCP: a first byte from 128 to 191), once something's set to take it.
        public var media: (@Sendable ([UInt8]) -> Void)? {
            get { lock.withLock { _media } }
            set { lock.withLock { _media = newValue } }
        }
        private var _media: (@Sendable ([UInt8]) -> Void)?
        /// Each live stream's own, when a session carries several: by the stream's SSRC (in the clear in each packet: an
        /// RTP packet's at its 9th byte, a report about it, which its viewer sends as that SSRC, at its 5th).
        private var routes: [UInt32: @Sendable ([UInt8]) -> Void] = [:]

        /// A stream's packets (or the reports about it) to `take`, from now on; nil: no longer.
        public func route(_ ssrc: UInt32, to take: (@Sendable ([UInt8]) -> Void)?) {
            lock.withLock { routes[ssrc] = take }
        }

        /// Whom a media packet is for: its stream's route, else whatever takes the session's media.
        func taker(of bytes: [UInt8]) -> (@Sendable ([UInt8]) -> Void)? {
            lock.withLock {
                guard !routes.isEmpty, bytes.count >= 12 else { return _media }
                let at = (200 ... 204).contains(bytes[1]) ? 4 : 8
                let ssrc = UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
                return routes[ssrc] ?? _media
            }
        }

        /// Bytes onto the session's path (video, as SRTP).
        public func send(_ bytes: [UInt8]) { finder.send(bytes) }

        /// Everything that arrives on the path, by its first byte.
        func deliver(_ bytes: [UInt8]) {
            guard let first = bytes.first else { return }
            switch first {
            case SecureChannel.marker:
                channel?.handle(bytes)
            case PathSessions.ping where bytes.count == 2:
                finder.send([PathSessions.pong, bytes[1]])
            case PathSessions.pong where bytes.count == 2:
                lock.withLock { pongs[bytes[1]] = Date() }
            case 128 ... 191:
                taker(of: bytes)?(bytes)
            default:
                break
            }
        }

        func pong(_ n: UInt8) -> Date? { lock.withLock { pongs[n] } }

        /// Connected: the control channel opened (once).
        func connected() {
            lock.withLock {
                guard _channel == nil, let keys = _keys else { return }
                let finder = self.finder
                let channel = SecureChannel(keys: keys) { finder.send($0) }
                channel.received = { [weak self] data in self?.arrived(data) }
                _channel = channel
            }
        }

        /// A request to the other side, and its reply (nil: none in time, or the session ended).
        public func ask(_ action: String, _ body: Data? = nil, timeout: Double = 10) async -> (body: Data?, error: String?)? {
            guard let channel else { return nil }
            let waiting = OneShot<ChannelMessage?>()
            let id = lock.withLock { () -> UInt64 in
                defer { nextRequest += 1 }
                replies[nextRequest] = waiting
                return nextRequest
            }
            channel.send(ChannelMessage(id: id, reply: false, action: action, body: body).wire)
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                waiting.resolve(nil)
            }
            defer { _ = lock.withLock { replies.removeValue(forKey: id) } }
            guard let reply = await waiting.value else { return nil }
            return (reply.body, reply.error)
        }

        /// A message on the channel: a reply to one of this side's requests, or a request to answer.
        private func arrived(_ data: Data) {
            guard let message = ChannelMessage(wire: data) else { return }
            if message.reply {
                lock.withLock { replies[message.id] }?.resolve(message)
                return
            }
            guard let action = message.action, let owner else { return }
            Task {
                let (body, error) = await owner.serve(self, action: action, body: message.body)
                channel?.send(ChannelMessage(id: message.id, reply: true, body: body, error: error).wire)
            }
        }

        func closeChannel() { lock.withLock { _channel }?.close() }

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

    /// Pings and their answers over a path, for its round trip (`connect`).
    static let ping: UInt8 = 0xFE, pong: UInt8 = 0xFD

    /// A message on a session's control channel: a request (an action, and what it's about), or the reply to one.
    struct ChannelMessage: Codable {
        var id: UInt64
        var reply: Bool
        var action: String?
        var body: Data?
        var error: String?
        /// (On the wire: whether there's a body after the header.)
        var bodied: Bool?

        init(id: UInt64, reply: Bool, action: String? = nil, body: Data? = nil, error: String? = nil) {
            self.id = id
            self.reply = reply
            self.action = action
            self.body = body
            self.error = error
        }

        /// On the wire: [the header's length, 4 bytes][the header, as JSON][the body as it is] (a clip's bytes, not
        /// base64 inside JSON).
        var wire: Data {
            var header = self
            header.body = nil
            header.bodied = body != nil
            let json = (try? JSONEncoder().encode(header)) ?? Data()
            let length = UInt32(json.count)
            return Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]) + json + (body ?? Data())
        }

        init?(wire: Data) {
            let bytes = [UInt8](wire.prefix(4))
            guard bytes.count == 4 else { return nil }
            let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            let start = wire.startIndex + 4
            guard wire.count >= 4 + length,
                  var message = try? JSONDecoder().decode(ChannelMessage.self, from: wire[start ..< start + length]) else { return nil }
            if message.bodied == true { message.body = Data(wire[(start + length)...]) }
            message.bodied = nil
            self = message
        }
    }

    /// Told when a session ends (its stream, if it has one, stopped with it).
    public var sessionEnded: (@Sendable (Session) -> Void)?

    /// What this side does when the other asks (set by the service): the reply's body, or why not. `ping` is
    /// answered here.
    public var requests: (@Sendable (Session, String, Data?) async -> (Data?, String?))?

    func serve(_ session: Session, action: String, body: Data?) async -> (Data?, String?) {
        if action == "ping" { return (nil, nil) }
        guard let requests else { return (nil, "not supported: \(action)") }
        return await requests(session, action, body)
    }

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
        outcome.roundTrip = await roundTrip(session)
        log("remote: \(peer.name): \(outcome.summary)")
        return outcome
    }

    /// A path to `peer` found, and kept (until `close`): the session, and how it went; or no session, and why.
    public func open(to peer: RemotePeer) async -> (Outcome, Session?) {
        let start = Date()
        guard let socket = try? DatagramSocket() else { return (Outcome(took: 0, problem: "no UDP socket could be opened"), nil) }
        let finder = PathFinder(role: .controlled, transport: settings.transport(socket), timing: settings.timing)
        let session = Session(id: UUID(), peer: peer, finder: finder, port: socket.port)
        session.owner = self
        finder.received = { [weak session] in session?.deliver($0) }
        lock.withLock { sessions[session.id] = session }
        var kept = false
        defer { if !kept { end(session, tell: true) } }

        let hosts = Gatherer.hosts(port: socket.port, mode: settings.mode)
        finder.addLocal(hosts)
        session.mine = facts(hosts)
        let offer = Message.Offer(session: session.id, credentials: finder.local, candidates: settings.shareLocalAddresses ? hosts : [],
                                  exchange: session.oneTime.publicKey.rawRepresentation)
        log("remote: connecting to \(peer.name)…")
        guard await send(Message.offer, Self.encode(offer), peer) else {
            var outcome = Outcome(took: Date().timeIntervalSince(start), problem: "\(peer.name) isn't connected to the signaling service")
            outcome.absent = true
            return (outcome, nil)
        }
        Task { await self.trickle(session) }
        Task {
            try? await Task.sleep(for: .seconds(10))
            session.answer.resolve(nil)
        }
        guard let theirs = await session.answer.value else {
            return (Outcome(took: Date().timeIntervalSince(start), problem: "\(peer.name) didn't answer"), nil)
        }
        guard let exchange = theirs.exchange,
              let keys = try? SessionKeys.derive(mine: session.oneTime, theirs: exchange, session: session.id, controlling: false) else {
            return (Outcome(took: Date().timeIntervalSince(start), problem: "\(peer.name)'s answer had no key for the session"), nil)
        }
        session.keys = keys
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
        session.connected()
        kept = true
        var outcome = Outcome(pair: pair, took: Date().timeIntervalSince(start))
        if case .mesh = settings.mode { outcome.mesh = true }
        return (outcome, session)
    }

    /// A session let go (the other side told).
    public func close(_ session: Session) { end(session, tell: true) }

    /// Every session let go (remote access turned off, or its settings changed).
    public func closeAll() {
        for session in lock.withLock({ Array(sessions.values) }) { end(session, tell: true) }
    }

    /// The sessions connected now: with whom, and how, in words ("IPv6, directly").
    /// Whether a session's still open (not ended by either side, or its path lost).
    public func isOpen(_ session: Session) -> Bool { lock.withLock { sessions[session.id] != nil } }

    /// Those connected now (by their ids), and how: "IPv6, directly", "IPv4, over the mesh".
    public var connected: [(peer: String, how: String)] {
        let mesh = if case .mesh = settings.mode { true } else { false }
        return lock.withLock { Array(sessions.values) }.compactMap { session in
            guard case let .connected(pair) = session.finder.state else { return nil }
            let how = switch (pair.local.kind, pair.remote.kind) {
            case (.relay, _), (_, .relay): "through the relay"
            case (.host, .host): mesh ? "over the mesh" : "directly"
            default: "through the routers"
            }
            return (session.peer.id, "\(pair.remote.address.isIPv6 ? "IPv6" : "IPv4"), \(how)")
        }.sorted { $0.peer < $1.peer }
    }

    /// A session under way, by its id.
    func session(_ id: UUID) -> Session? { lock.withLock { sessions[id] } }

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
    private func roundTrip(_ session: Session) async -> Double? {
        var trips: [Double] = []
        for n in UInt8(0) ..< 5 {
            let sent = Date()
            session.finder.send([Self.ping, n])
            for _ in 0 ..< 50 where session.pong(n) == nil { try? await Task.sleep(for: .milliseconds(10)) }
            if let back = session.pong(n) { trips.append(back.timeIntervalSince(sent)) }
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
        // No key for the session: nothing could be said over it.
        guard let exchange = offer.exchange else { return log("! remote: \(peer.name)'s offer had no key for the session") }
        var socket = settings.port.flatMap { try? DatagramSocket(port: $0) }
        if socket == nil, let port = settings.port { log("! remote: UDP port \(port) is in use: answering from another") }
        if socket == nil { socket = try? DatagramSocket() }
        guard let socket else { return log("! remote: no UDP socket could be opened") }
        let finder = PathFinder(role: .controlling, transport: settings.transport(socket), timing: settings.timing)
        let session = Session(id: offer.session, peer: peer, finder: finder, port: socket.port)
        guard let keys = try? SessionKeys.derive(mine: session.oneTime, theirs: exchange, session: offer.session, controlling: true) else {
            finder.close()
            return log("! remote: \(peer.name)'s key for the session isn't one")
        }
        session.keys = keys
        lock.withLock { sessions[offer.session] = session }
        let hosts = Gatherer.hosts(port: socket.port, mode: settings.mode)
        finder.addLocal(hosts)
        session.mine = facts(hosts)
        finder.setRemote(offer.credentials, candidates: offer.candidates)
        session.owner = self
        finder.received = { [weak session] in session?.deliver($0) }
        finder.stateChanged = { [weak self, weak session] state in
            guard let self, let session else { return }
            switch state {
            case let .connected(pair):
                session.connectedAt = Date()
                session.connected()
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
                                  candidates: settings.shareLocalAddresses ? hosts : [],
                                  exchange: session.oneTime.publicKey.rawRepresentation)
        Task {
            _ = await send(Message.answer, Self.encode(reply), peer)
            await trickle(session)
        }
        // (A session that never connected is let go after a minute; one that did lasts until it's ended, or its
        // path is lost.)
        Task {
            try? await Task.sleep(for: .seconds(60))
            if session.connectedAt == nil { self.end(session, tell: false) }
        }
    }

    // MARK: Ending

    private func end(_ session: Session, tell: Bool) {
        guard lock.withLock({ sessions.removeValue(forKey: session.id) }) != nil else { return }
        session.answer.resolve(nil)
        sessionEnded?(session)
        session.closeChannel()
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
