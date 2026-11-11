// Live video over a remote session. The Pond being reached sends a camera's stream as it sends one to the Home app:
// LiveSession (the camera's own video as it arrives, H.264 or H.265, or re-encoded and steered by the viewer's reports; RTP, SRTP), its
// packets on the session's path instead of a UDP socket of their own, keyed from the session (SessionKeys: the side
// being reached's video key, both ways, as HomeKit's streams use one key). The viewer decrypts what arrives, puts the
// pictures back together, and sends a receiver report twice a second: they keep the stream going (without any for
// 30 s, it's stopped) and say how much was lost (re-encoding then sends less).
//
// Asked for over the control channel: `live.start` (a LiveRequest; answered with a LiveAnswer), `live.stop` (one
// stream, by its SSRC, or all). A session carries as many streams as its viewer asks for (one per camera it shows),
// told apart by their SSRCs. The camera's own stream is passed through as it arrives; a viewer on a weak
// link can ask for it re-encoded to a size and bitrate of its own (Pond's video hardware), which its reports then
// steer (RateControl), as for the Home app on cellular.
import Foundation
import HAPCamera
import Ingest
import Media
import PondProtocol

/// What a viewer asks for.
public struct LiveRequest: Codable, Sendable {
    public var camera: String
    /// The camera's main stream (sharp, more to send) or its sub-stream.
    public var main: Bool
    /// Re-encoded to at most this size, bitrate (kbit/s) and frame rate; nil: the camera's own stream as it is.
    public var reencode: Reencode?

    public struct Reencode: Codable, Sendable {
        public var width: Int, height: Int, kbps: Int, fps: Int

        public init(width: Int, height: Int, kbps: Int, fps: Int) {
            self.width = width
            self.height = height
            self.kbps = kbps
            self.fps = fps
        }
    }

    public init(camera: String, main: Bool, reencode: Reencode? = nil) {
        self.camera = camera
        self.main = main
        self.reencode = reencode
    }
}

/// What the Pond being reached answers: the stream's RTP identity.
public struct LiveAnswer: Codable, Sendable {
    public var ssrc: UInt32
    public var payloadType: UInt8
    /// What comes: the camera's own codec, or H.264 when re-encoded (left out by a Pond from before H.265: H.264).
    public var codec: VideoCodec?

    public var sent: VideoCodec { codec ?? .h264 }
}

/// A session's path as a live stream's transport: packets out onto it; the viewer's (its reports) waited for.
final class SessionTransport: MediaTransport, @unchecked Sendable {
    weak var session: PathSessions.Session?
    private let lock = NSLock()
    private var incoming: [[UInt8]] = []
    private let arrived = DispatchSemaphore(value: 0)

    /// The stream's reports (its viewer sends them as the stream's SSRC).
    init(session: PathSessions.Session, ssrc: UInt32) {
        self.session = session
        session.route(ssrc) { [weak self] bytes in self?.push(bytes) }
    }

    func send(_ bytes: [UInt8]) { session?.send(bytes) }

    func receive() -> [UInt8]? {
        guard arrived.wait(timeout: .now() + 0.2) == .success else { return nil }
        return lock.withLock { incoming.isEmpty ? nil : incoming.removeFirst() }
    }

    private func push(_ bytes: [UInt8]) {
        let kept = lock.withLock { () -> Bool in
            guard incoming.count < 256 else { return false }   // (a reader that's stopped reading: not kept forever)
            incoming.append(bytes)
            return true
        }
        if kept { arrived.signal() }
    }
}

/// The Pond being reached: each session's live stream, started and stopped as its viewer asks.
public final class LiveSender: @unchecked Sendable {
    let hub: StreamHub
    let log: @Sendable (String) -> Void
    /// Each session's streams, by their SSRC.
    private var streams: [UUID: [UInt32: LiveSession]] = [:]
    private let lock = NSLock()

    public init(hub: StreamHub = .shared, log: @escaping @Sendable (String) -> Void) {
        self.hub = hub
        self.log = log
    }

    /// The camera's stream (`source`: its address and login) to the session's viewer, from now on, beside any others
    /// it's sent (a viewer showing several cameras).
    public func start(_ session: PathSessions.Session, source: (url: String, username: String, password: String),
                      reencode: LiveRequest.Reencode? = nil) -> LiveAnswer? {
        guard let keys = session.keys else { return nil }
        // Its codec, from the stream (open already, for the recorder, so this costs nothing); H.264 if re-encoded.
        let probe = reencode == nil ? try? hub.open(url: source.url, username: source.username, password: source.password) : nil
        let codec = probe.flatMap { VideoCodec(encoding: $0.video.encoding) } ?? .h264
        probe?.close()
        let answer = LiveAnswer(ssrc: UInt32.random(in: 1 ... .max), payloadType: 99, codec: codec)
        // Packets small enough for any path (and a relay's wrapping): RTP and SRTP's tag inside 1,200 bytes.
        let video = LiveSession.Video(payloadType: answer.payloadType, ssrc: answer.ssrc, mtu: 1200, rtcpInterval: 0.5,
                                      width: 0, height: 0, maxBitrate: 0)
        let live = LiveSession(source: source, socket: SessionTransport(session: session, ssrc: answer.ssrc), video: video,
                               masterKey: keys.videoSend.key, masterSalt: keys.videoSend.salt, hub: hub, log: log)
        if let reencode {
            // Only while the media engine has room: else the camera's own stream, as it is.
            live.reencodeIfRoom(to: .init(width: reencode.width, height: reencode.height, bitrate: reencode.kbps, fps: reencode.fps, profile: 1),
                                label: "live to \(session.peer.name)")
        }
        let id = session.id, ssrc = answer.ssrc
        live.onEnd = { [weak self, weak session] in
            session?.route(ssrc, to: nil)
            _ = self?.lock.withLock { self?.streams[id]?.removeValue(forKey: ssrc) }
        }
        lock.withLock { streams[id, default: [:]][ssrc] = live }
        live.start()
        return answer
    }

    /// One of the session's streams stopped (by its SSRC), or all of them.
    public func stop(_ session: PathSessions.Session, ssrc: UInt32? = nil) {
        let stopping = lock.withLock { () -> [LiveSession] in
            if let ssrc { return [streams[session.id]?.removeValue(forKey: ssrc)].compactMap { $0 } }
            return Array((streams.removeValue(forKey: session.id) ?? [:]).values)
        }
        for live in stopping { live.stop() }
    }

    /// How many streams are being sent, to every session.
    public var sending: Int { lock.withLock { streams.values.reduce(0) { $0 + $1.count } } }
}

/// The viewer: a session's live stream, decrypted and put back together into pictures, with reports sent back.
public final class LiveViewer: @unchecked Sendable {
    /// What's come so far.
    public struct Counts: Sendable, Equatable {
        public var packets = 0, lost = 0, bytes = 0
        public var pictures = 0, keyframes = 0
        public var firstPicture: Date?
    }

    let session: PathSessions.Session
    let answer: LiveAnswer
    /// Its reports are sent as the stream's own SSRC, so the sender can tell which of its streams they're about.
    var ssrc: UInt32 { answer.ssrc }
    private var srtp: SRTPReceiver
    private var reports: SRTPSender
    private var depacketizer: VideoDepacketizer
    private var counts = Counts()
    private var highest: UInt16?
    private var receivedSinceReport = 0, expectedSinceReport = 0
    private var cumulativeLost: Int32 = 0
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Each picture as it's put back together: its NAL units (the SPS and PPS ahead of a keyframe's), whether it's a
    /// keyframe, its RTP time.
    public var picture: (@Sendable (_ nalus: [[UInt8]], _ keyframe: Bool, _ timestamp: UInt32) -> Void)?
    /// Each RTP packet as it arrives, decrypted (for passing on as a camera's stream is: the app's live view).
    public var packet: (@Sendable (_ rtp: [UInt8]) -> Void)?

    /// For a stream the other side's answered `live.start` with. Nothing's taken until `start`, so that what's set to
    /// take its pictures and packets (`picture`, `packet`) is there for the first.
    public init?(session: PathSessions.Session, answer: LiveAnswer) {
        guard let keys = session.keys else { return nil }
        self.session = session
        self.answer = answer
        depacketizer = VideoDepacketizer(codec: answer.sent)
        // The side being reached's video key, both ways (its stream, and these reports about it).
        srtp = SRTPReceiver(masterKey: keys.videoReceive.key, masterSalt: keys.videoReceive.salt)
        reports = SRTPSender(masterKey: keys.videoReceive.key, masterSalt: keys.videoReceive.salt)
    }

    /// Taking the stream from now on (with what's come of it already: PathSessions keeps it a moment), and reporting
    /// on it.
    public func start() {
        session.route(answer.ssrc) { [weak self] bytes in self?.arrived(bytes) }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pond.viewer"))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.report() }
        timer.resume()
        self.timer = timer
    }

    deinit { stop() }

    public func stop() {
        timer?.cancel()
        timer = nil
        session.route(answer.ssrc, to: nil)
    }

    public var received: Counts { lock.withLock { counts } }

    private func arrived(_ bytes: [UInt8]) {
        // RTP (its payload type in the second byte's low bits); RTCP's types (200–204) are the sender's reports.
        guard bytes.count > 12, !(200 ... 204).contains(bytes[1]) else { return }
        var decrypted: [UInt8]?
        let done = lock.withLock { () -> [(nalus: [[UInt8]], keyframe: Bool, timestamp: UInt32)] in
            guard let packet = srtp.unprotect(bytes), let rtp = RTPPacket(packet), rtp.ssrc == answer.ssrc else { return [] }
            decrypted = packet
            counts.packets += 1
            counts.bytes += bytes.count
            receivedSinceReport += 1
            if let highest {
                let gap = Int(rtp.sequence &- highest)
                if gap > 0, gap < 0x8000 {
                    expectedSinceReport += gap
                    counts.lost += gap - 1
                    cumulativeLost += Int32(gap - 1)
                    self.highest = rtp.sequence
                }
            } else {
                highest = rtp.sequence
                expectedSinceReport += 1
            }
            let units = depacketizer.push(rtp).filter { !$0.damaged }
            for unit in units {
                counts.pictures += 1
                if unit.isKeyframe { counts.keyframes += 1 }
                if counts.firstPicture == nil { counts.firstPicture = Date() }
            }
            // (The depacketizer keeps the parameter sets apart: put back ahead of each keyframe, so it stands alone.)
            let sets = depacketizer.parameterSets?.all ?? []
            return units.map { ($0.isKeyframe && !sets.isEmpty ? sets + $0.nalus : $0.nalus, $0.isKeyframe, $0.timestamp) }
        }
        if let decrypted { packet?(decrypted) }
        for unit in done { picture?(unit.nalus, unit.keyframe, unit.timestamp) }
    }

    /// A receiver report about the stream (RFC 3550 6.4.2): what share was lost since the last one, how many in all,
    /// the highest sequence number.
    private func report() {
        let packet = lock.withLock { () -> [UInt8]? in
            guard let highest else { return nil }
            let fraction = expectedSinceReport > 0
                ? UInt8(min(255, max(0, (expectedSinceReport - receivedSinceReport) * 256 / expectedSinceReport))) : 0
            receivedSinceReport = 0
            expectedSinceReport = 0
            func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
            let lost = UInt32(bitPattern: cumulativeLost) & 0x00FF_FFFF
            let block = be32(answer.ssrc) + [fraction] + Array(be32(lost).dropFirst()) + be32(UInt32(highest)) + be32(0) + be32(0) + be32(0)
            let rr = [0x81, 201, 0, 7] + be32(ssrc) + block
            return reports.protect(rtcp: rr)
        }
        if let packet { session.send(packet) }
    }
}

/// What watching a stream for a while came to.
public struct WatchResult: Sendable {
    public var counts: LiveViewer.Counts
    public var seconds: Double
    /// From asking to the first picture.
    public var firstPictureAfter: Double?
    /// Where the video was kept (a fragmented MP4), if any came.
    public var file: URL?
    public var problem: String?

    /// In words: "142 pictures in 10 s (14.2 a second), 1,820 kbit/s, none lost; the first after 0.9 s; kept in …".
    public var summary: String {
        if let problem { return problem }
        let rate = Double(counts.pictures) / max(0.1, seconds)
        let kbps = Double(counts.bytes * 8) / max(0.1, seconds) / 1000
        let lost = counts.lost == 0 ? "none lost"
            : String(format: "%d lost (%.1f%%)", counts.lost, 100 * Double(counts.lost) / Double(max(1, counts.packets + counts.lost)))
        let first = firstPictureAfter.map { String(format: "; the first after %.1f s", $0) } ?? "; no picture came"
        return String(format: "%d pictures in %.0f s (%.1f a second), %.0f kbit/s, ", counts.pictures, seconds, rate, kbps) + lost + first
            + (file.map { "; kept in \($0.path)" } ?? "")
    }
}

extension RemoteHost {
    /// A camera of a paired Pond's (by its id or name) watched for `seconds`: what came, and the video kept at `file`.
    public func watch(device: String, camera: String, main: Bool, reencode: LiveRequest.Reencode? = nil, seconds: Double,
                      file: URL) async -> WatchResult {
        guard let peer = devices().first(where: { $0.id == device || $0.name == device }) else {
            return WatchResult(counts: .init(), seconds: 0, problem: "no device \(device) (pond remote devices)")
        }
        let (outcome, opened) = await paths.open(to: peer)
        guard let session = opened else { return WatchResult(counts: .init(), seconds: 0, problem: outcome.summary) }
        defer { paths.close(session) }
        let asked = Date()
        guard let reply = await session.ask("live.start", try? JSONEncoder().encode(LiveRequest(camera: camera, main: main, reencode: reencode)))
        else {
            return WatchResult(counts: .init(), seconds: 0, problem: "\(peer.name) didn't answer")
        }
        if let error = reply.error { return WatchResult(counts: .init(), seconds: 0, problem: "\(peer.name): \(error)") }
        guard let body = reply.body, let answer = try? JSONDecoder().decode(LiveAnswer.self, from: body),
              let viewer = LiveViewer(session: session, answer: answer) else {
            return WatchResult(counts: .init(), seconds: 0, problem: "\(peer.name)'s answer wasn't one")
        }
        let keeper = VideoKeeper(file: file)
        viewer.picture = { nalus, keyframe, timestamp in keeper.add(nalus, keyframe: keyframe, timestamp: timestamp) }
        viewer.start()
        try? await Task.sleep(for: .seconds(seconds))
        viewer.stop()
        _ = await session.ask("live.stop", timeout: 3)
        let kept = keeper.finish()
        let counts = viewer.received
        return WatchResult(counts: counts, seconds: seconds, firstPictureAfter: counts.firstPicture.map { $0.timeIntervalSince(asked) },
                           file: kept ? file : nil)
    }
}

/// Pictures kept as a fragmented MP4, from the first keyframe (its SPS saying the picture's size).
final class VideoKeeper: @unchecked Sendable {
    let file: URL
    private var writer: FragmentWriter?
    private var handle: FileHandle?
    private var unwrap = TimestampUnwrapper()
    private var start: Int64?
    private let lock = NSLock()

    private var hevc = false

    init(file: URL) { self.file = file }

    /// The track for a keyframe's leading parameter sets, whichever codec they are.
    static func track(_ nalus: [[UInt8]]) -> VideoTrack? {
        if let first = nalus[0].first, H265.type(first) == H265.vps, nalus.count >= 4, let sps = H265SPS(nal: nalus[1]) {
            return VideoTrack(sps: nalus[1], pps: nalus[2], width: sps.width, height: sps.height,
                              hevc: .init(vps: nalus[0], profileTierLevel: sps.profileTierLevel, chromaFormat: sps.chromaFormat,
                                          bitDepthLuma: sps.bitDepthLuma, bitDepthChroma: sps.bitDepthChroma,
                                          temporalLayers: sps.maxSubLayers, temporalIDNested: sps.temporalIDNesting))
        }
        guard nalus[0].first.map({ $0 & 0x1F == 7 }) == true, let size = H264SPS(nal: nalus[0]) else { return nil }
        return VideoTrack(sps: nalus[0], pps: nalus[1], width: size.width, height: size.height)
    }

    func add(_ nalus: [[UInt8]], keyframe: Bool, timestamp: UInt32) {
        lock.withLock {
            let time = unwrap.unwrap(timestamp)
            if writer == nil {
                // From the first keyframe with its parameter sets ahead of it: H.264's SPS, PPS; or H.265's VPS, SPS, PPS.
                guard keyframe, nalus.count >= 3, let track = Self.track(nalus) else { return }
                hevc = track.hevc != nil
                let w = FragmentWriter(video: track, audio: nil)
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: file.path, contents: nil)
                handle = try? FileHandle(forWritingTo: file)
                try? handle?.write(contentsOf: w.initSegment)
                writer = w
                start = time
            }
            let pictures = nalus.filter { nal in
                guard let first = nal.first else { return false }
                return hevc ? !(H265.vps ... H265.pps).contains(H265.type(first)) : ![7, 8].contains(first & 0x1F)
            }
            if let fragment = writer?.addVideo(time: time - (start ?? time), nalus: pictures, isKeyframe: keyframe) {
                try? handle?.write(contentsOf: fragment)
            }
        }
    }

    /// The rest written: true if anything was.
    func finish() -> Bool {
        lock.withLock {
            if let rest = writer?.finish() { try? handle?.write(contentsOf: rest) }
            try? handle?.close()
            return writer != nil
        }
    }
}
