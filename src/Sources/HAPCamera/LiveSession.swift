// One live stream to a controller: the camera's H.264 as it arrives (never re-encoded), cut into RTP packets of
// the size asked for, encrypted with SRTP and sent over UDP, with an RTCP sender report every interval. The
// controller's RTCP coming back keeps the stream alive; without any for 30 s it is stopped.
import Darwin
import Foundation
import Ingest
import NVRCore

/// Where a live stream's packets go, and its viewer's reports come from: a UDP socket to a HomeKit controller, or
/// a remote session's path (Remote).
public protocol MediaTransport: AnyObject, Sendable {
    func send(_ bytes: [UInt8])
    /// The next packet from the viewer, waiting a moment (0.2 s) for one; nil if none came.
    func receive() -> [UInt8]?
}

/// A UDP socket bound to a free port.
public final class UDPSocket: MediaTransport, @unchecked Sendable {
    let fd: Int32
    public let port: UInt16
    let ipv6: Bool

    public init?(ipv6: Bool) {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var bound: Int32
        if ipv6 {
            var a = sockaddr_in6()
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        guard bound == 0, withUnsafeMutablePointer(to: &storage, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length) } }) == 0 else {
            close(fd)
            return nil
        }
        let port = withUnsafePointer(to: &storage) { p in
            ipv6 ? p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
                 : p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        self.fd = fd
        self.port = port
        self.ipv6 = ipv6
    }

    deinit { close(fd) }

    /// Sends to the controller from now on; also makes `localAddress` the address the controller is reached from.
    @discardableResult
    public func connect(to address: String, port: UInt16) -> Bool {
        withSocketAddress(address, port) { sa, len in Darwin.connect(fd, sa, len) == 0 } ?? false
    }

    /// This side's address towards the connected controller.
    public var localAddress: String? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        guard withUnsafeMutablePointer(to: &storage, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length) } }) == 0 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) } }
        guard ok == 0 else { return nil }
        let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.split(separator: "%").first.map(String.init)   // without an IPv6 zone
    }

    public func send(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Waits up to 0.2 s for a datagram.
    public func receive() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buffer, buffer.count, 0)
        return n > 0 ? Array(buffer[0 ..< n]) : nil
    }

    private func withSocketAddress<T>(_ address: String, _ port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        if ipv6 {
            var a = sockaddr_in6()
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, address, &a.sin6_addr) == 1 else { return nil }
            return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &a.sin_addr) == 1 else { return nil }
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    }
}

/// The video part of a live stream, running on its own threads until stopped.
public final class LiveSession: @unchecked Sendable {
    public struct Video: Sendable {
        public var payloadType: UInt8
        public var ssrc: UInt32
        public var mtu: Int
        public var rtcpInterval: Double
        public var width: Int
        public var height: Int
        public var maxBitrate: Int

        public init(payloadType: UInt8, ssrc: UInt32, mtu: Int, rtcpInterval: Double, width: Int, height: Int, maxBitrate: Int) {
            self.payloadType = payloadType
            self.ssrc = ssrc
            self.mtu = mtu
            self.rtcpInterval = rtcpInterval
            self.width = width
            self.height = height
            self.maxBitrate = maxBitrate
        }
    }

    /// The sound HomeKit asked for: AAC-ELD at `sampleRate`, `maxBitrate` kbit/s.
    public struct Audio: Sendable, Equatable {
        public var payloadType: UInt8
        public var ssrc: UInt32
        public var sampleRate: Int
        public var maxBitrate: Int
        public var rtcpInterval: Double
        /// Milliseconds of sound per packet the viewer asked for (20, 30, 40 or 60).
        public var packetTime: Int = 30

        /// Samples of sound per packet: the packet time at the sample rate.
        public var samplesPerPacket: Int { packetTime * sampleRate / 1000 }

        /// AAC-ELD frames (480 samples) per packet on average: one at 24 kHz and 20 ms or 16 kHz and 30 ms, two at
        /// 16 kHz and 60 ms, one and a half (two, then one) at 24 kHz and 30 ms.
        public var framesPerPacket: Double { Double(samplesPerPacket) / Double(AudioTranscoder.eldFrameLength) }
    }

    /// The sound's own socket, keys, packets and clock, set before `start`.
    private struct AudioOut {
        let settings: Audio
        let socket: any MediaTransport
        var sender: SRTPSender
        var packetizer: RTPPacketizer
        let muted: @Sendable () -> Bool
        /// RTP time: samples sent so far, from a random start; it carries on across reconnects.
        var timestamp = UInt32.random(in: 0 ... .max)
        /// Frames waiting to fill a packet, and the RTP time of the first.
        var pending: [[UInt8]] = []
        var pendingTimestamp: UInt32 = 0
        /// Samples sent beyond the packets' share (packets of whole frames can't always match the packet
        /// time; this evens them out).
        var ahead = 0
        /// Since the last status line: packets sent, and frames held back because the microphone is muted.
        var sentPackets = 0
        var mutedFrames = 0
    }
    private var audioOut: AudioOut?

    /// The camera stream being sent; a reconfigure can switch it (main or sub-stream) for the next one.
    private var source: (url: String, username: String, password: String)
    private var switchTo: (url: String, username: String, password: String)?
    /// Set when the camera's stream is re-encoded for this viewer (the camera's "Re-encoded by Pond" setting):
    /// what the viewer asked for.
    private var reencode: VideoTranscoder.Target?
    private var transcoderInUse: VideoTranscoder?
    /// While re-encoding: the rate, steered by the viewer's reports.
    private var rate: RateControl?
    /// The viewer's reports, decrypted.
    private let reports: SRTCPReceiver
    /// The share of packets the viewer last said it lost, for the status line.
    private var viewerLoss: Double?
    let socket: any MediaTransport
    let video: Video
    /// Where the camera's stream is read (shared with the recorder and other viewers).
    let hub: StreamHub
    let log: @Sendable (String) -> Void
    private var sender: SRTPSender
    private var packetizer: RTPPacketizer
    private let stopFlag = NSLock()
    private var stopped = false
    private var lastHeard = Date()
    private var lastTimestamp: UInt32 = 0
    private var keyframe: (nalus: [[UInt8]], sps: [UInt8], pps: [UInt8])?
    /// The latest keyframe sent, for snapshots.
    var latestKeyframe: (nalus: [[UInt8]], sps: [UInt8], pps: [UInt8])? { sendLock.withLock { keyframe } }
    /// Seconds without video from the camera before reconnecting to it: once it is streaming, and for the
    /// first frame (a Reolink starts sending 1–4 s after PLAY).
    static let stallSeconds = 3.0
    static let firstFrameSeconds = 8.0
    private let sendLock = NSLock()
    public var onEnd: (@Sendable () -> Void)?
    /// Something went wrong reaching the camera, or video stopped (the viewer may still be waiting).
    public var onProblem: (@Sendable (HomeKitStatus.Problem.Kind) -> Void)?
    /// Video reached the viewer.
    public var onPlaying: (@Sendable () -> Void)?

    public init(source: (url: String, username: String, password: String), socket: any MediaTransport, video: Video,
                masterKey: [UInt8], masterSalt: [UInt8], hub: StreamHub = .shared, log: @escaping @Sendable (String) -> Void) {
        self.source = source
        self.socket = socket
        self.hub = hub
        self.video = video
        self.log = log
        sender = SRTPSender(masterKey: masterKey, masterSalt: masterSalt)
        reports = SRTCPReceiver(masterKey: masterKey, masterSalt: masterSalt)
        // Room for the RTP header and SRTP's tag inside the packet size asked for.
        packetizer = RTPPacketizer(payloadType: video.payloadType, ssrc: video.ssrc, maxPayload: max(200, video.mtu - 12 - 10))
    }

    var isStopped: Bool { stopFlag.withLock { stopped } }

    /// The stream being sent now.
    public var sourceURL: String { stopFlag.withLock { source.url } }

    /// Re-encode the stream for the viewer, from `target`; set before `start`. The viewer's reports then
    /// steer the rate (RateControl).
    public func reencode(to target: VideoTranscoder.Target) {
        stopFlag.withLock {
            reencode = target
            rate = RateControl(bitrate: target.bitrate)
        }
    }

    /// The Home app asks for more (a reconfigure): the rate rises to it if it is higher.
    public func askedFor(bitrate kbps: Int) {
        let changed = stopFlag.withLock { () -> VideoTranscoder.Target? in
            guard var control = rate, let current = reencode else { return nil }
            let next = control.asked(kbps)
            rate = control
            return next.map { RateControl.target(bitrate: $0, profile: current.profile) }
        }
        if let changed { retarget(changed) }
    }

    /// A report from the viewer: what it lost steers the rate while re-encoding.
    private func viewerReported(_ packet: [UInt8]) {
        guard let rtcp = reports.unprotect(packet),
              let mine = ReceptionReport.parse(rtcp).first(where: { $0.ssrc == video.ssrc }) else { return }
        let changed = stopFlag.withLock { () -> VideoTranscoder.Target? in
            viewerLoss = mine.lostShare
            guard var control = rate, let current = reencode else { return nil }
            // Kept whether or not the rate changes: it counts how long the viewer has been clean.
            let next = control.report(lost: mine.lostShare)
            rate = control
            return next.map { RateControl.target(bitrate: $0, profile: current.profile) }
        }
        guard let changed else { return }
        let why = mine.lostShare > RateControl.clean ? "the viewer lost \(Int(mine.lostShare * 100))% of packets" : "clean for a while"
        log("… HomeKit live: \(why): now \(changed.bitrate) kbit/s, up to \(changed.width)×\(changed.height) at \(changed.fps) fps")
        retarget(changed)
    }

    public var isReencoding: Bool { stopFlag.withLock { reencode != nil } }
    /// What the viewer last asked for, while re-encoding.
    public var reencodeTarget: VideoTranscoder.Target? { stopFlag.withLock { reencode } }

    /// What the viewer asks for now (a reconfigure), while re-encoding: the encoder follows at once.
    public func retarget(_ target: VideoTranscoder.Target) {
        let transcoder = stopFlag.withLock { () -> VideoTranscoder? in
            reencode = target
            return transcoderInUse
        }
        transcoder?.retarget(target)
    }

    /// Sends `next` instead, from its next keyframe on (or its replay of the latest), the viewer none the
    /// wiser: the same packets' numbering and clock carry on. False if it is the one being sent.
    @discardableResult
    public func switchSource(to next: (url: String, username: String, password: String)) -> Bool {
        stopFlag.withLock {
            guard next.url != (switchTo ?? source).url else { return false }
            switchTo = next
            return true
        }
    }

    public func enableAudio(_ audio: Audio, socket: any MediaTransport, masterKey: [UInt8], masterSalt: [UInt8],
                            muted: @escaping @Sendable () -> Bool) {
        sendLock.withLock {
            audioOut = AudioOut(settings: audio, socket: socket, sender: SRTPSender(masterKey: masterKey, masterSalt: masterSalt),
                                packetizer: RTPPacketizer(payloadType: audio.payloadType, ssrc: audio.ssrc, maxPayload: 1000),
                                muted: muted)
        }
    }

    /// Camera AAC frames to the viewer as AAC-ELD, unless the microphone is muted in the Home app.
    private func sendAudio(_ frames: [AACFrame], transcoder: AudioTranscoder?) {
        guard let transcoder, sendLock.withLock({ audioOut != nil }) else { return }
        for frame in frames {
            let eld = transcoder.push(frame.data)
            sendLock.withLock {
                guard var out = audioOut else { return }
                for au in eld {
                    defer { out.timestamp &+= AudioTranscoder.eldFrameLength }
                    if out.muted() {
                        out.pending = []
                        out.ahead = 0
                        out.mutedFrames += 1
                        continue
                    }
                    if out.pending.isEmpty { out.pendingTimestamp = out.timestamp }
                    out.pending.append(au)
                    // A packet once it holds its share of the packet time, less what earlier ones ran over.
                    let held = out.pending.count * Int(AudioTranscoder.eldFrameLength)
                    guard held + out.ahead >= out.settings.samplesPerPacket else { continue }
                    out.ahead += held - out.settings.samplesPerPacket
                    let packet = out.packetizer.packetize(aac: out.pending, timestamp: out.pendingTimestamp)
                    out.socket.send(out.sender.protect(rtp: packet))
                    out.sentPackets += 1
                    out.pending = []
                }
                audioOut = out
            }
        }
    }

    public func start() {
        let streamer = Thread { [self] in stream() }
        streamer.name = "live video"
        streamer.qualityOfService = .userInteractive
        streamer.start()
        let control = Thread { [self] in rtcp() }
        control.name = "live rtcp"
        control.start()
    }

    public func stop() {
        let first = stopFlag.withLock {
            defer { stopped = true }
            return !stopped
        }
        if first { onEnd?() }
    }

    private func send(_ rtp: [UInt8]) {
        sendLock.withLock { socket.send(sender.protect(rtp: rtp)) }
    }

    private func stream() {
        defer { stop() }
        let base = UInt32.random(in: 0 ... .max)
        // Timestamps carry on across reconnects, so the viewer sees one stream.
        var offset: UInt32 = 0
        var attempts = 0
        while !isStopped {
            switch streamOnce(base: base, offset: &offset) {
            case .stopped: return
            case .switched:
                stopFlag.withLock {
                    if let next = switchTo { source = next }
                    switchTo = nil
                }
            case .failed where attempts >= 3: return
            case .failed, .stalled:
                attempts += 1
                log("… HomeKit live: reconnecting to the camera")
            }
        }
    }

    enum Outcome { case stopped, stalled, failed, switched }

    private func streamOnce(base: UInt32, offset: inout UInt32) -> Outcome {
        let session: PacketSource
        let source = stopFlag.withLock { self.source }
        do {
            // Shared with the recorder (and other viewers) when they read the same stream; replayed from its
            // latest keyframe, so the picture starts at once.
            session = try hub.open(url: source.url, username: source.username, password: source.password,
                                                replay: true)
        } catch {
            log("! HomeKit live: camera: \(error.description)")
            onProblem?(.init(error))
            return .failed
        }
        defer {
            session.close()
            // Carry on from here if reconnected: a frame (at 10 fps) after the last one sent.
            offset = sendLock.withLock { lastTimestamp } &- base &+ 9000
        }
        var depacketizer = H264Depacketizer(spropParameterSets: session.video.format["sprop-parameter-sets"])
        let aac = session.audio.map { AACDepacketizer(format: $0.format) }
        let transcoder: AudioTranscoder? = sendLock.withLock { audioOut?.settings }.flatMap { settings in
            session.audio?.format["config"].flatMap {
                AudioTranscoder(config: $0, outputRate: settings.sampleRate, bitrate: min(settings.maxBitrate, 32) * 1000)
            }
        }
        if sendLock.withLock({ audioOut != nil }), transcoder == nil {
            log("! HomeKit live: the camera sends no sound that can be converted; video only")
        }
        // Re-encoding: the transcoder's frames go out on the camera's clock, from the first one sent.
        let encoded = EncodedOutput()
        let startOffset = offset
        let reencoder = stopFlag.withLock { reencode }.map { target in
            VideoTranscoder(target: target) { [weak self] frame in
                guard let self else { return }
                let time = encoded.relative(frame.time)
                let timestamp = base &+ startOffset &+ UInt32(truncatingIfNeeded: time)
                let packets = self.sendLock.withLock { self.packetizer.packetize(frame.nalus, timestamp: timestamp) }
                for p in packets { self.send(p) }
                self.sendLock.withLock { self.lastTimestamp = timestamp }
                encoded.count(packets.reduce(0) { $0 + $1.count })
            }
        }
        stopFlag.withLock { transcoderInUse = reencoder }
        defer { stopFlag.withLock { transcoderInUse = nil } }
        // The camera's frames on its clock, placed evenly (a camera that stamps them when it sends them bunches them
        // up: see FrameRetimer); relative to the first live one, for the viewer's RTP times.
        var unwrap = TimestampUnwrapper()
        var retimer = FrameRetimer()
        var needKeyframe = true
        var started = false
        var first: Int64 = 0
        // Replayed frames (from before this viewer joined) are sent a millisecond apart, so they show as a blink
        // and the picture is live, not as far behind as the keyframe was; live ones carry on from them.
        var replayedFrames: UInt32 = 0
        var caughtUp = false
        var lastFrame = Date()
        var statsFrames = 0, statsBytes = 0, statsSince = Date()
        while !isStopped {
            if stopFlag.withLock({ switchTo != nil }) { return .switched }
            let packet: InterleavedPacket?
            do { packet = try session.next(timeout: 0.5) } catch {
                log("! HomeKit live: camera: \(error.description)")
                onProblem?(.init(error))
                return .failed
            }
            let limit = started ? Self.stallSeconds : Self.firstFrameSeconds
            if Date().timeIntervalSince(lastFrame) > limit {
                log("! HomeKit live: no video from the camera for \(Int(limit)) s")
                onProblem?(.noVideo)
                return .stalled
            }
            if let packet, packet.channel == CameraSession.audioChannel {
                // Sound from the first frame of the picture on, so the two start together.
                // Not the replayed: it would put the sound behind the picture.
                if started, !packet.replayed, let aac, let rtp = RTPPacket(packet.data) {
                    sendAudio(aac.push(rtp), transcoder: transcoder)
                }
                continue
            }
            guard let packet, packet.channel == CameraSession.videoChannel, let rtp = RTPPacket(packet.data) else { continue }
            for unit in depacketizer.push(rtp) {
                lastFrame = Date()
                if let reencoder {
                    // Re-encoded: every frame is decoded (replayed ones too, so the next can be), from a whole
                    // keyframe on; the transcoder sends what it makes.
                    if unit.damaged { needKeyframe = true; continue }
                    if needKeyframe { guard unit.isKeyframe else { continue }; needKeyframe = false }
                    guard let sps = depacketizer.sps, let pps = depacketizer.pps else { continue }
                    if unit.isKeyframe { sendLock.withLock { keyframe = (unit.nalus, sps, pps) } }
                    let cameraTime = retimer.place(unwrap.unwrap(unit.timestamp))
                    if !started {
                        started = true
                        let target = stopFlag.withLock { reencode }
                        log("✓ HomeKit live: re-encoding the main stream\(target.map { " for \($0.width)×\($0.height) at up to \($0.bitrate) kbit/s, \($0.fps) fps" } ?? "")")
                        onPlaying?()
                    }
                    reencoder.push(unit.nalus, sps: sps, pps: pps, time: cameraTime, encode: !packet.replayed)
                    continue
                }
                let placed = retimer.place(unwrap.unwrap(unit.timestamp))
                // From the first whole keyframe; a damaged frame waits for the next keyframe.
                if !started {
                    guard unit.isKeyframe, !unit.damaged, depacketizer.sps != nil else { continue }
                    started = true
                    first = placed
                    log("✓ HomeKit live: streaming the \(source.url.hasSuffix("main") ? "main" : "sub-")stream")
                    onPlaying?()
                }
                var nalus = unit.nalus
                if unit.isKeyframe, let sps = depacketizer.sps, let pps = depacketizer.pps {
                    nalus = [sps, pps] + nalus
                    sendLock.withLock { keyframe = (unit.nalus, sps, pps) }
                }
                let timestamp: UInt32
                if packet.replayed {
                    timestamp = base &+ offset &+ replayedFrames &* 90
                    replayedFrames &+= 1
                } else {
                    if !caughtUp {
                        caughtUp = true
                        first = placed - Int64(replayedFrames) * 90
                    }
                    timestamp = base &+ offset &+ UInt32(truncatingIfNeeded: placed - first)
                }
                let packets = sendLock.withLock { packetizer.packetize(nalus, timestamp: timestamp) }
                for p in packets { send(p) }
                sendLock.withLock { lastTimestamp = timestamp }
                statsFrames += 1
                statsBytes += packets.reduce(0) { $0 + $1.count }
            }
            let elapsed = Date().timeIntervalSince(statsSince)
            if elapsed >= 5 {
                if reencoder != nil { (statsFrames, statsBytes) = encoded.take() }
                let heard = Date().timeIntervalSince(stopFlag.withLock { lastHeard })
                // Sound: packets sent, or why none were.
                let sound = sendLock.withLock { () -> String in
                    guard var out = audioOut else { return "no sound asked for" }
                    defer {
                        out.sentPackets = 0
                        out.mutedFrames = 0
                        audioOut = out
                    }
                    if out.sentPackets > 0 { return "sound \(out.sentPackets) packets" }
                    if out.mutedFrames > 0 { return "sound held back: the Home app has the microphone muted" }
                    return transcoder == nil ? "no sound from the camera to convert" : "no sound from the camera"
                }
                let loss = stopFlag.withLock { viewerLoss }.map { String(format: ", lost %.0f%%", $0 * 100) } ?? ""
                log(String(format: "… HomeKit live: %.1f fps, %.0f kbit/s, %@; viewer last heard %.0f s ago%@",
                           Double(statsFrames) / elapsed, Double(statsBytes) * 8 / elapsed / 1000, sound, heard, loss))
                statsFrames = 0
                statsBytes = 0
                statsSince = Date()
            }
        }
        return .stopped
    }

    /// Sender reports out; the controller's reports in, as a sign it is still watching.
    private func rtcp() {
        var nextReport = Date()
        while !isStopped {
            if let packet = socket.receive() {
                stopFlag.withLock { lastHeard = Date() }
                viewerReported(packet)
            }
            if Date() >= nextReport {
                let report = sendLock.withLock { packetizer.senderReport(rtpTimestamp: lastTimestamp) }
                let protected = sendLock.withLock { sender.protect(rtcp: report) }
                socket.send(protected)
                sendLock.withLock {
                    guard var out = audioOut else { return }
                    let report = out.packetizer.senderReport(rtpTimestamp: out.timestamp)
                    out.socket.send(out.sender.protect(rtcp: report))
                    audioOut = out
                }
                nextReport = Date().addingTimeInterval(max(0.5, video.rtcpInterval))
            }
            if Date().timeIntervalSince(stopFlag.withLock({ lastHeard })) > 30 {
                log("! HomeKit live: nothing from the viewer for 30 s; stopped")
                stop()
            }
        }
    }
}

/// The transcoder's frames, timed from the first one sent, and counted for the status line.
private final class EncodedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Int64?
    private var frames = 0, bytes = 0

    func relative(_ time: Int64) -> Int64 {
        lock.withLock {
            if first == nil { first = time }
            return time - first!
        }
    }

    func count(_ size: Int) { lock.withLock { frames += 1; bytes += size } }

    func take() -> (Int, Int) {
        lock.withLock {
            defer { frames = 0; bytes = 0 }
            return (frames, bytes)
        }
    }
}
