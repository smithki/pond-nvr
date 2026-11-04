// Other Ponds' cameras, as this Mac's app shows them beside its own: one session kept open to each Pond while
// anything of it is shown (closed a minute after the last), their cameras listed, and each camera's live video as a
// stream like a camera's own (a PacketSource), so StreamHub shares it and the app's live view plays it unchanged.
// Its address is `pond-remote://<pond>/<camera>/main|sub`; the app gets it from `remote.cameras`.
import Devices
import Foundation
import Ingest
import NVRCore
import Understanding

public final class RemoteViewing: @unchecked Sendable {
    public static let scheme = "pond-remote"

    let host: RemoteHost
    private let lock = NSLock()
    private var sessions: [String: PathSessions.Session] = [:]
    private var opening: [String: Task<PathSessions.Session?, Never>] = [:]
    /// Streams open per Pond, and when its last one closed (its session closed a minute after).
    private var streams: [String: Int] = [:]
    private var idleSince: [String: Date] = [:]
    /// Each Pond's cameras as last asked, and when.
    private var cameras: [String: (at: Date, cameras: [RemoteAPI.Camera])] = [:]
    private var timer: DispatchSourceTimer?
    /// How the last attempt to reach each Pond went, when it failed.
    private var failed: [String: PathSessions.Outcome] = [:]

    public init(host: RemoteHost) {
        self.host = host
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pond.remote.viewing"))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.closeIdle() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    /// A stream's address.
    public static func url(pond: String, camera: String, main: Bool) -> String {
        "\(scheme)://\(pond)/\(camera)/\(main ? "main" : "sub")"
    }

    static func parse(_ url: String) -> (pond: String, camera: String, main: Bool)? {
        guard let parts = URLComponents(string: url), parts.scheme == scheme, let pond = parts.host else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        guard path.count == 2 else { return nil }
        return (pond, path[0], path[1] != "sub")
    }

    /// Whether an address is a paired Pond's camera's.
    public func isKnown(_ url: String) -> Bool {
        guard let (pond, _, _) = Self.parse(url) else { return false }
        return host.devices().contains { $0.id == pond }
    }

    /// The session to a Pond: the one open, or a new one (one opening at a time).
    func session(_ pond: String) async -> PathSessions.Session? {
        let task = lock.withLock { () -> Task<PathSessions.Session?, Never>? in
            if let open = sessions[pond], host.paths.isOpen(open) { return nil }
            if let opening = opening[pond] { return opening }
            let task = Task { [weak self, host] () -> PathSessions.Session? in
                guard let peer = host.devices().first(where: { $0.id == pond }) else { return nil }
                let (outcome, session) = await host.paths.open(to: peer)
                self?.lock.withLock { self?.failed[pond] = session == nil ? outcome : nil }
                return session
            }
            opening[pond] = task
            return task
        }
        guard let task else { return lock.withLock { sessions[pond] } }
        let opened = await task.value
        lock.withLock {
            opening[pond] = nil
            if let opened { sessions[pond] = opened; idleSince[pond] = idleSince[pond] ?? Date() }
        }
        return opened
    }

    /// Each paired Pond's cameras, asked of each at once (at most every 10 s each): nil for one that couldn't be
    /// reached, with why.
    public func allCameras() async -> [(pond: RemotePeer, cameras: [RemoteAPI.Camera]?, problem: String?)] {
        await withTaskGroup(of: (RemotePeer, [RemoteAPI.Camera]?, String?).self) { group in
            for peer in host.devices() {
                group.addTask { [self] in
                    if let kept = lock.withLock({ cameras[peer.id] }), Date().timeIntervalSince(kept.at) < 10 { return (peer, kept.cameras, nil) }
                    guard let session = await session(peer.id) else { return (peer, nil, "\(peer.name) can\u{2019}t be reached") }
                    do {
                        let found = try await RemoteClient(session: session).cameras()
                        lock.withLock { cameras[peer.id] = (Date(), found) }
                        return (peer, found, nil)
                    } catch {
                        return (peer, nil, "\(peer.name): \(error)")
                    }
                }
            }
            var out: [(RemotePeer, [RemoteAPI.Camera]?, String?)] = []
            for await one in group { out.append(one) }
            return out.sorted { $0.0.name < $1.0.name }
        }
    }

    /// Pictures of Ponds' cameras as last asked (by `camera@pond`), and when: asked again at most every 30 s.
    private var stills: [String: (asked: Date, still: RemoteAPI.Still)] = [:]

    /// A camera's latest recorded picture, as its Pond sends it.
    public func still(pond: String, camera: String) async -> RemoteAPI.Still? {
        let key = ControlSocket.RemotePond.cameraID(camera, pond: pond)
        if let kept = lock.withLock({ stills[key] }), Date().timeIntervalSince(kept.asked) < 30 { return kept.still }
        guard let session = await session(pond), let still = try? await RemoteClient(session: session).still(camera) else {
            return lock.withLock { stills[key]?.still }
        }
        lock.withLock { stills[key] = (Date(), still) }
        return still
    }

    /// Each Pond's events as last asked (for which stretch), and when: asked again at most every 10 s.
    private var events: [String: (asked: Date, from: Date, to: Date?, events: [RemoteAPI.Event])] = [:]
    /// Pictures and clips being fetched, or fetched (by `kind/event@pond`).
    private var files: [String: ControlSocket.RemoteFile] = [:]

    /// Every Pond's events begun from `from` (and before `to`, if given), newest last, as each sends them (one that can't
    /// be reached: its last ones, if any).
    public func allEvents(from: Date, to: Date? = nil) async -> [ControlSocket.RemoteEvent] {
        await withTaskGroup(of: [ControlSocket.RemoteEvent].self) { group in
            for peer in host.devices() {
                group.addTask { [self] in
                    let kept = lock.withLock { events[peer.id] }
                    // (The same stretch, give or take a minute, asked again within 10 s: as it was.)
                    let same = kept.map { abs($0.from.timeIntervalSince(from)) < 60 && $0.to == to } ?? false
                    var found = same ? kept?.events : nil
                    if !same || Date().timeIntervalSince(kept!.asked) > 10,
                       let session = await session(peer.id),
                       let fresh = try? await RemoteClient(session: session).events(.init(since: from, limit: RemoteAPI.mostEvents, until: to)) {
                        lock.withLock { events[peer.id] = (Date(), from, to, fresh) }
                        found = fresh
                    }
                    return (found ?? []).map { Self.here($0, pond: peer.id) }
                }
            }
            var all: [ControlSocket.RemoteEvent] = []
            for await some in group { all += some }
            return all.sorted { $0.start < $1.start }
        }
    }

    /// Each Pond's cameras' recorded stretches, as last asked (for which stretch of time), and when.
    private var coverage: [String: (asked: Date, from: Date, to: Date, spans: RemoteAPI.Coverage)] = [:]

    /// Every Pond's cameras' recorded stretches between two times, and when their recordings begin (by `camera@pond`):
    /// asked of each at most every 20 s for the same stretch.
    public func allCoverage(from: Date, to: Date) async -> (spans: [String: [[Double]]], earliest: [String: Double], private: [String: [[Double]]]) {
        await withTaskGroup(of: RemoteAPI.Coverage.self) { group in
            for peer in host.devices() {
                group.addTask { [self] in
                    var found = lock.withLock { coverage[peer.id] }.flatMap { k in
                        k.from == from && k.to == to && Date().timeIntervalSince(k.asked) < 20 ? k.spans : nil
                    }
                    if found == nil, let session = await session(peer.id),
                       let fresh = try? await RemoteClient(session: session).coverage(from: from, to: to) {
                        lock.withLock { coverage[peer.id] = (Date(), from, to, fresh) }
                        found = fresh
                    }
                    func here<V>(_ d: [String: V]) -> [String: V] {
                        Dictionary(uniqueKeysWithValues: d.map { (ControlSocket.RemotePond.cameraID($0.key, pond: peer.id), $0.value) })
                    }
                    return RemoteAPI.Coverage(spans: here(found?.spans ?? [:]), earliest: here(found?.earliest ?? [:]),
                                              private: here(found?.private ?? [:]))
                }
            }
            var spans: [String: [[Double]]] = [:], earliest: [String: Double] = [:], hidden: [String: [[Double]]] = [:]
            for await some in group {
                spans.merge(some.spans) { a, _ in a }
                earliest.merge(some.earliest) { a, _ in a }
                hidden.merge(some.private ?? [:]) { a, _ in a }
            }
            return (spans, earliest, hidden)
        }
    }

    /// Another Pond's event as this Mac's app has it (its id and its camera's `…@pond`).
    static func here(_ e: RemoteAPI.Event, pond: String) -> ControlSocket.RemoteEvent {
        ControlSocket.RemoteEvent(
            id: ControlSocket.RemotePond.cameraID(e.id, pond: pond), pond: pond, camera: ControlSocket.RemotePond.cameraID(e.camera, pond: pond),
            start: e.start, end: e.end, ongoing: e.ongoing, category: e.category, labels: e.labels, summary: e.sentence ?? e.seen,
            zones: e.zones, picture: e.picture, clipBytes: e.clipBytes, clipStart: e.clipStart,
            box: e.box.map { [$0.x, $0.y, $0.width, $0.height] }, confidence: e.confidence)
    }

    /// A question asked of every other Pond at once (as the app asks this Mac's: the reading, if a part was taken off
    /// it, answered again): each one's answer (its events' ids here, best first), and those events.
    public func searchAll(_ request: ControlSocket.Request) async -> (results: [SearchResult], events: [ControlSocket.RemoteEvent]) {
        await withTaskGroup(of: (SearchResult, [ControlSocket.RemoteEvent])?.self) { group in
            for peer in host.devices() {
                group.addTask { [self] in
                    guard let session = await session(peer.id) else { return nil }
                    let client = RemoteClient(session: session)
                    var asked = request
                    asked.action = "search"
                    asked.camera = ""
                    guard let reply = try? await client.control(asked), var result = reply.search,
                          let found = try? await client.events(.init(ids: result.ids, limit: RemoteAPI.mostEvents)) else { return nil }
                    result.ids = result.ids.map { ControlSocket.RemotePond.cameraID($0, pond: peer.id) }
                    return (result, found.map { Self.here($0, pond: peer.id) })
                }
            }
            var results: [SearchResult] = [], events: [ControlSocket.RemoteEvent] = []
            for await answer in group {
                guard let (result, found) = answer else { continue }
                results.append(result)
                events += found
            }
            return (results, events)
        }
    }

    /// An event's picture or clip (`event@pond`): fetched into the cache if it isn't there or on its way, and how
    /// that's going (asked again for news).
    public func file(_ id: String, clip: Bool) -> ControlSocket.RemoteFile {
        guard let (event, pond) = ControlSocket.RemotePond.split(id) else {
            return .init(path: "", partial: nil, bytes: 0, received: 0, done: false, problem: "which event?")
        }
        let path = ControlSocket.RemoteEvent.file(pond: pond, event: event, clip: clip)
        let key = "\(clip ? "clip" : "picture")/\(id)"
        if FileManager.default.fileExists(atPath: path) {
            return .init(path: path, partial: nil, bytes: 0, received: 0, done: true)
        }
        // (One that failed is tried again when asked again.)
        if let going = lock.withLock({ files[key] }), going.problem == nil { return going }
        let started = ControlSocket.RemoteFile(path: path, partial: nil, bytes: 0, received: 0, done: false)
        lock.withLock { files[key] = started }
        Task { [weak self] in
            guard let self else { return }
            guard let session = await session(pond) else {
                return lock.withLock { files[key]?.problem = "the other Pond can\u{2019}t be reached" }
            }
            let client = RemoteClient(session: session)
            let progress: RemoteClient.Progress = { [weak self] partial, bytes, kept in
                self?.lock.withLock {
                    self?.files[key]?.partial = partial.path
                    self?.files[key]?.bytes = bytes
                    self?.files[key]?.received = kept
                }
            }
            let url = URL(fileURLWithPath: path)
            do {
                _ = clip ? try await client.clip(event, to: url, progress: progress) : try await client.picture(event, to: url, progress: progress)
                lock.withLock {
                    files[key]?.done = true
                    files[key]?.partial = nil
                }
            } catch {
                lock.withLock { files[key]?.problem = "\(error)" }
            }
        }
        return started
    }

    /// How each paired Pond's recording is going: its own word on it, or that it couldn't be asked (and whether
    /// because it isn't connected to the signaling service at all: off, or offline). Nil while this Mac itself isn't
    /// connected to it (then nothing can be said of the others).
    public func health() async -> [(pond: RemotePeer, health: RemoteAPI.Health?, absent: Bool, problem: String?)]? {
        guard host.isReachable else { return nil }
        return await withTaskGroup(of: (RemotePeer, RemoteAPI.Health?, Bool, String?).self) { group in
            for peer in host.devices() {
                group.addTask { [self] in
                    // Over the session open (if any); one that doesn't answer closed, and a new one tried (which finds out
                    // whether the other's there at all).
                    for attempt in 0 ..< 2 {
                        guard let session = await session(peer.id) else {
                            let outcome = lock.withLock { failed[peer.id] }
                            return (peer, nil, outcome?.absent ?? false, outcome?.summary ?? "\(peer.name) can\u{2019}t be reached")
                        }
                        do {
                            return (peer, try await RemoteClient(session: session).health(), false, nil)
                        } catch {
                            guard attempt == 0 else { return (peer, nil, false, "\(peer.name): \(error)") }
                            drop(peer.id, session)
                        }
                    }
                    return (peer, nil, false, nil)
                }
            }
            var out: [(RemotePeer, RemoteAPI.Health?, Bool, String?)] = []
            for await one in group { out.append(one) }
            return out.sorted { $0.0.name < $1.0.name }
        }
    }

    /// A request about one of a Pond's cameras (its controls, privacy), asked of it.
    public func control(pond: String, _ request: ControlSocket.Request) async -> ControlSocket.Reply {
        guard let session = await session(pond) else { return ControlSocket.Reply(error: .failed("the other Pond can\u{2019}t be reached")) }
        do {
            let reply = try await RemoteClient(session: session).control(request)
            if request.action == "privacy.set" { lock.withLock { cameras[pond] = nil } }
            return reply
        } catch {
            return ControlSocket.Reply(error: .failed("\(error)"))
        }
    }

    /// A camera's live video, as a camera's own stream.
    public func open(_ url: String) throws -> PacketSource {
        guard let (pond, camera, main) = Self.parse(url) else { throw RTSPError.notFound(url) }
        // (StreamHub opens streams from a thread of its own, which waits here.)
        let opened = OneShotBox<Result<RemoteStream, RTSPError>>()
        Task { [weak self] in
            guard let self, let session = await session(pond) else { return opened.set(.failure(.transport(.unreachable("the other Pond")))) }
            let request = try? JSONEncoder().encode(LiveRequest(camera: camera, main: main))
            guard let reply = await session.ask("live.start", request) else { return opened.set(.failure(.timeout("live.start"))) }
            if let error = reply.error { return opened.set(.failure(.status(503, error))) }
            guard let body = reply.body, let answer = try? JSONDecoder().decode(LiveAnswer.self, from: body),
                  let viewer = LiveViewer(session: session, answer: answer) else { return opened.set(.failure(.malformed("live.start"))) }
            opened.set(.success(RemoteStream(viewer: viewer, session: session, answer: answer) { [weak self] in self?.closed(pond) }))
        }
        guard let result = opened.wait(seconds: 30) else { throw RTSPError.timeout("the other Pond's video") }
        let stream = try result.get()
        lock.withLock { streams[pond, default: 0] += 1; idleSince[pond] = nil }
        try stream.waitForParameterSets()
        return stream
    }

    /// A session that stopped answering, closed (the next request opens a new one).
    private func drop(_ pond: String, _ session: PathSessions.Session) {
        lock.withLock { if sessions[pond] === session { sessions[pond] = nil } }
        host.paths.close(session)
    }

    private func closed(_ pond: String) {
        lock.withLock {
            streams[pond, default: 1] -= 1
            if streams[pond] == 0 { idleSince[pond] = Date() }
        }
    }

    /// Sessions with nothing shown for a minute, closed.
    private func closeIdle() {
        let closing = lock.withLock { () -> [PathSessions.Session] in
            let idle = idleSince.filter { Date().timeIntervalSince($0.value) > 60 && (streams[$0.key] ?? 0) == 0 }.map(\.key)
            return idle.compactMap { pond in
                idleSince[pond] = nil
                return sessions.removeValue(forKey: pond)
            }
        }
        for session in closing { host.paths.close(session) }
    }
}

/// One camera's video from another Pond: its RTP as it arrives (decrypted), read as a camera's stream is.
final class RemoteStream: PacketSource, @unchecked Sendable {
    private(set) var video: SDP.Media
    let audio: SDP.Media? = nil
    let viewer: LiveViewer
    let session: PathSessions.Session
    let answer: LiveAnswer
    let ended: () -> Void
    private let lock = NSLock()
    private var queue: [[UInt8]] = []
    private let arrived = DispatchSemaphore(value: 0)
    private var sps: [UInt8]?, pps: [UInt8]?
    private var closed = false

    init(viewer: LiveViewer, session: PathSessions.Session, answer: LiveAnswer, ended: @escaping () -> Void) {
        self.viewer = viewer
        self.session = session
        self.answer = answer
        self.ended = ended
        video = SDP("m=video 0 RTP/AVP \(answer.payloadType)\r\na=rtpmap:\(answer.payloadType) H264/90000\r\na=fmtp:\(answer.payloadType) packetization-mode=1\r\n").video!
        viewer.packet = { [weak self] rtp in self?.push(rtp) }
    }

    private func push(_ rtp: [UInt8]) {
        lock.withLock {
            // Its parameter sets as they first come, for the description.
            if sps == nil || pps == nil, let packet = RTPPacket(rtp), let first = packet.payload.first {
                switch first & 0x1F {
                case 7: sps = Array(packet.payload)
                case 8: pps = Array(packet.payload)
                case 24: (sps, pps) = Self.aggregated(Array(packet.payload), sps, pps)
                default: break
                }
            }
            if queue.count < 2000 { queue.append(rtp) }
        }
        arrived.signal()
    }

    /// The SPS and PPS in a STAP-A packet.
    static func aggregated(_ payload: [UInt8], _ sps: [UInt8]?, _ pps: [UInt8]?) -> ([UInt8]?, [UInt8]?) {
        var (sps, pps) = (sps, pps)
        var i = 1
        while i + 2 <= payload.count {
            let n = Int(payload[i]) << 8 | Int(payload[i + 1])
            i += 2
            guard i + n <= payload.count, n > 0 else { break }
            let unit = Array(payload[i ..< i + n])
            if unit[0] & 0x1F == 7 { sps = unit } else if unit[0] & 0x1F == 8 { pps = unit }
            i += n
        }
        return (sps, pps)
    }

    /// Until the stream's parameter sets have come (the description carries them), up to 10 s.
    func waitForParameterSets() throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let (sps, pps) = lock.withLock({ sps.flatMap { s in pps.map { (s, $0) } } }) {
                video.format["sprop-parameter-sets"] = Data(sps).base64EncodedString() + "," + Data(pps).base64EncodedString()
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        close()
        throw RTSPError.timeout("the other Pond's first picture")
    }

    func next(timeout: Double) throws(RTSPError) -> InterleavedPacket? {
        if lock.withLock({ closed }) { throw .transport(.closed) }
        guard arrived.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { queue.isEmpty ? nil : InterleavedPacket(channel: CameraSession.videoChannel, data: queue.removeFirst()) }
    }

    func close() {
        guard lock.withLock({ () -> Bool in
            defer { closed = true }
            return !closed
        }) else { return }
        viewer.stop()
        let session = session, answer = answer
        Task { _ = await session.ask("live.stop", try? JSONEncoder().encode(answer), timeout: 3) }
        ended()
    }
}

/// A value set once from elsewhere, waited for on a thread.
final class OneShotBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private let done = DispatchSemaphore(value: 0)

    func set(_ v: T) {
        lock.withLock { value = v }
        done.signal()
    }

    func wait(seconds: Double) -> T? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return lock.withLock { value }
    }
}
