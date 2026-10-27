// Other Ponds' cameras, as this Mac's app shows them beside its own: one session kept open to each Pond while
// anything of it is shown (closed a minute after the last), their cameras listed, and each camera's live video as a
// stream like a camera's own (a PacketSource), so StreamHub shares it and the app's live view plays it unchanged.
// Its address is `pond-remote://<pond>/<camera>/main|sub`; the app gets it from `remote.cameras`.
import Devices
import Foundation
import Ingest
import NVRCore

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
            let task = Task { [host] () -> PathSessions.Session? in
                guard let peer = host.devices().first(where: { $0.id == pond }) else { return nil }
                return await host.paths.open(to: peer).1
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
