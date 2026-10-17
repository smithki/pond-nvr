// Camera RTP Stream Management, the live-view handshake. The controller writes Setup Endpoints (its address,
// ports and SRTP keys) and reads back ours; then it writes Selected RTP Stream Configuration to start the
// stream (with the resolution, payload type, bitrate and packet size it wants), reconfigure, or end it.
// Field layouts follow HAP-NodeJS's RTPStreamManagement; numbers are little-endian.
import Foundation
import HAP
import NVRCore

enum LE {
    static func u16(_ b: [UInt8]?) -> Int? { guard let b, b.count >= 2 else { return nil }; return Int(b[0]) | Int(b[1]) << 8 }
    static func u32(_ b: [UInt8]?) -> UInt32? {
        guard let b, b.count >= 4 else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
    static func f32(_ b: [UInt8]?) -> Double? { u32(b).map { Double(Float(bitPattern: $0)) } }
    static func bytes16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    static func bytes32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
}

/// What Setup Endpoints asked for, and what we answered.
struct PreparedStream {
    var sessionID: [UInt8]
    var controllerAddress: String
    var videoPort: UInt16
    var videoKey: [UInt8]
    var videoSalt: [UInt8]
    var audioKey: [UInt8]
    var audioSalt: [UInt8]
    var videoSocket: UDPSocket
    var audioSocket: UDPSocket
    var videoSSRC: UInt32
    var audioSSRC: UInt32
}

public final class StreamManagement: @unchecked Sendable {
    /// The camera's main and sub-stream, with its login.
    let main: (url: String, username: String, password: String)
    let sub: (url: String, username: String, password: String)
    let log: @Sendable (String) -> Void
    var statusChanged: (@Sendable (Bool) -> Void)?
    /// Problems and recoveries of the live view, for the status.
    var problem: (@Sendable (HomeKitStatus.Problem.Kind) -> Void)?
    var playing: (@Sendable () -> Void)?
    /// Whether a live view may start (not while the camera is private).
    var allowed: @Sendable () -> Bool = { true }
    /// The accessory's microphone is muted in the Home app: no sound is sent.
    var microphoneMuted: @Sendable () -> Bool = { false }
    private var prepared: PreparedStream?
    private var live: LiveSession?
    private let lock = NSLock()

    /// Re-encode the main stream for each viewer (VideoTranscoder) rather than send a camera stream as is.
    let reencode: Bool

    init(main: (url: String, username: String, password: String), sub: (url: String, username: String, password: String),
         reencode: Bool = false, log: @escaping @Sendable (String) -> Void) {
        self.main = main
        self.sub = sub
        self.reencode = reencode
        self.log = log
    }

    /// What a viewer asks for in a video TLV (start or reconfigure), against the settings so far.
    static func target(_ video: [TLV8Item], current: VideoTranscoder.Target?) -> VideoTranscoder.Target {
        let codec = video.value(0x02).flatMap { try? TLV8.decode($0) } ?? []
        let attributes = video.value(0x03).flatMap { try? TLV8.decode($0) } ?? []
        let rtp = video.value(0x04).flatMap { try? TLV8.decode($0) } ?? []
        return VideoTranscoder.Target(
            width: LE.u16(attributes.value(0x01)) ?? current?.width ?? 1280,
            height: LE.u16(attributes.value(0x02)) ?? current?.height ?? 720,
            bitrate: LE.u16(rtp.value(0x03)) ?? current?.bitrate ?? 299,
            fps: attributes.value(0x03)?.first.map(Int.init) ?? current?.fps ?? 30,
            profile: codec.value(0x01)?.first.map(Int.init) ?? current?.profile ?? 1)
    }

    static func status(_ s: UInt8) -> [UInt8] { CameraTLV.item(0x01, s) }

    /// kbit/s a viewer must allow for the main stream.
    static let mainStreamBitrate = 1500

    /// The live stream's latest keyframe, for snapshots while it runs (no second connection to the camera).
    var latestKeyframe: (nalus: [[UInt8]], sps: [UInt8], pps: [UInt8])? {
        lock.withLock { live?.isStopped == false ? live?.latestKeyframe : nil }
    }

    // MARK: - Setup Endpoints

    func setupEndpoints(_ request: [UInt8]) -> [UInt8] {
        guard let items = try? TLV8.decode(request), let sessionID = items.value(0x01),
              let address = items.value(0x03).flatMap({ try? TLV8.decode($0) }),
              let videoSRTP = items.value(0x04).flatMap({ try? TLV8.decode($0) }),
              let audioSRTP = items.value(0x05).flatMap({ try? TLV8.decode($0) }) else {
            return CameraTLV.item(0x02, 2)
        }
        func reply(_ status: UInt8) -> [UInt8] { CameraTLV.item(0x01, sessionID) + CameraTLV.item(0x02, status) }
        let busy = lock.withLock { live != nil && !(live!.isStopped) }
        guard !busy else { return reply(1) }

        let ipv6 = address.value(0x01)?.first == 1
        guard let host = address.value(0x02).map({ String(decoding: $0, as: UTF8.self) }),
              let videoPort = LE.u16(address.value(0x03)), let audioPort = LE.u16(address.value(0x04)),
              let videoSocket = UDPSocket(ipv6: ipv6), let audioSocket = UDPSocket(ipv6: ipv6),
              videoSocket.connect(to: host, port: UInt16(videoPort)), audioSocket.connect(to: host, port: UInt16(audioPort)),
              let local = videoSocket.localAddress else {
            return reply(2)
        }
        let stream = PreparedStream(sessionID: sessionID, controllerAddress: host, videoPort: UInt16(videoPort),
                                    videoKey: videoSRTP.value(0x02) ?? [], videoSalt: videoSRTP.value(0x03) ?? [],
                                    audioKey: audioSRTP.value(0x02) ?? [], audioSalt: audioSRTP.value(0x03) ?? [],
                                    videoSocket: videoSocket, audioSocket: audioSocket,
                                    videoSSRC: .random(in: 1 ... .max), audioSSRC: .random(in: 1 ... .max))
        lock.withLock { prepared = stream }
        log("… HomeKit live: viewer at \(host) port \(videoPort); sending from \(local) port \(videoSocket.port)")

        let accessoryAddress = CameraTLV.item(0x01, ipv6 ? 1 : 0) + CameraTLV.item(0x02, Array(local.utf8))
            + CameraTLV.item(0x03, LE.bytes16(Int(videoSocket.port))) + CameraTLV.item(0x04, LE.bytes16(Int(audioSocket.port)))
        // The same keys back: HomeKit lets the accessory reuse the controller's.
        let videoParameters = CameraTLV.item(0x01, videoSRTP.value(0x01)?.first ?? 0)
            + CameraTLV.item(0x02, stream.videoKey) + CameraTLV.item(0x03, stream.videoSalt)
        let audioParameters = CameraTLV.item(0x01, audioSRTP.value(0x01)?.first ?? 0)
            + CameraTLV.item(0x02, stream.audioKey) + CameraTLV.item(0x03, stream.audioSalt)
        return reply(0) + CameraTLV.item(0x03, accessoryAddress) + CameraTLV.item(0x04, videoParameters)
            + CameraTLV.item(0x05, audioParameters) + CameraTLV.item(0x06, LE.bytes32(stream.videoSSRC))
            + CameraTLV.item(0x07, LE.bytes32(stream.audioSSRC))
    }

    // MARK: - Selected RTP Stream Configuration

    func selectedConfiguration(_ request: [UInt8]) {
        guard let items = try? TLV8.decode(request),
              let control = items.value(0x01).flatMap({ try? TLV8.decode($0) }),
              let command = control.value(0x02)?.first else { return }
        switch command {
        case 1, 3:   // start, resume
            guard let videoTLV = items.value(0x02).flatMap({ try? TLV8.decode($0) }) else { return }
            start(videoTLV, audio: items.value(0x03).flatMap { try? TLV8.decode($0) })
        case 0, 2:   // end, suspend
            log("… HomeKit live: ended by the viewer")
            stop()
        case 4:      // reconfigure: a new size or bitrate for the stream going on
            guard let videoTLV = items.value(0x02).flatMap({ try? TLV8.decode($0) }) else { return }
            reconfigure(videoTLV)
        default:
            break
        }
    }

    /// The sound asked for, if it is AAC-ELD (the only codec offered).
    static func audioSettings(_ audio: [TLV8Item]?, ssrc: UInt32) -> LiveSession.Audio? {
        guard let audio, audio.value(0x01)?.first == 2 else { return nil }
        let codec = audio.value(0x02).flatMap { try? TLV8.decode($0) } ?? []
        let rtp = audio.value(0x03).flatMap { try? TLV8.decode($0) } ?? []
        let rate = [8000, 16000, 24000][min(2, Int(codec.value(0x03)?.first ?? 1))]
        return LiveSession.Audio(payloadType: rtp.value(0x01)?.first ?? 110, ssrc: ssrc, sampleRate: rate,
                                 maxBitrate: LE.u16(rtp.value(0x03)) ?? 24,
                                 rtcpInterval: LE.f32(rtp.value(0x04)) ?? 5,
                                 packetTime: Int(codec.value(0x04)?.first ?? 30))
    }

    private func start(_ video: [TLV8Item], audio audioTLV: [TLV8Item]?) {
        guard let prepared = lock.withLock({ prepared }) else { return }
        guard allowed() else {
            log("HomeKit live: not started: the camera is private")
            return
        }
        let attributes = video.value(0x03).flatMap { try? TLV8.decode($0) } ?? []
        let rtp = video.value(0x04).flatMap { try? TLV8.decode($0) } ?? []
        let width = LE.u16(attributes.value(0x01)) ?? 1280, height = LE.u16(attributes.value(0x02)) ?? 720
        let settings = LiveSession.Video(payloadType: rtp.value(0x01)?.first ?? 99, ssrc: prepared.videoSSRC,
                                         mtu: LE.u16(rtp.value(0x05)) ?? 1378, rtcpInterval: LE.f32(rtp.value(0x04)) ?? 0.5,
                                         width: width, height: height, maxBitrate: LE.u16(rtp.value(0x03)) ?? 0)
        // Re-encoded: always from the main stream, made to what the viewer asked for.
        // Re-encoded: started at a good quality (the Home app's first ask is far below what it can show),
        // then fitted to what the viewer reports receiving (RateControl).
        let target = reencode ? RateControl.target(bitrate: max(Self.target(video, current: nil).bitrate, RateControl.start),
                                                    profile: Self.target(video, current: nil).profile) : nil
        let source = reencode ? main : self.source(width: width, maxBitrate: settings.maxBitrate)
        log("… HomeKit live: \(width)×\(height) asked, up to \(settings.maxBitrate) kbit/s, packets of \(settings.mtu)")
        let audio = Self.audioSettings(audioTLV, ssrc: prepared.audioSSRC)
        if let audio {
            log("… HomeKit live: sound as AAC-ELD at \(audio.sampleRate / 1000) kHz, up to \(audio.maxBitrate) kbit/s, \(audio.packetTime) ms a packet (\(audio.framesPerPacket.formatted()) frames)")
        } else {
            log("… HomeKit live: no sound asked for")
        }
        // Its lines say which viewer they are about, as two can watch at once.
        let log = self.log, viewer = prepared.controllerAddress
        let session = LiveSession(source: source, socket: prepared.videoSocket, video: settings,
                                  masterKey: prepared.videoKey, masterSalt: prepared.videoSalt) { line in
            log(line.replacingOccurrences(of: "HomeKit live:", with: "HomeKit live (\(viewer)):"))
        }
        if let target {
            session.reencode(to: target)
            log("… HomeKit live: re-encoding from \(target.bitrate) kbit/s, then as the viewer's reports allow")
        }
        if let audio {
            session.enableAudio(audio, socket: prepared.audioSocket, masterKey: prepared.audioKey,
                                masterSalt: prepared.audioSalt, muted: microphoneMuted)
        }
        session.onEnd = { [weak self] in self?.statusChanged?(false) }
        session.onProblem = { [weak self] kind in self?.problem?(kind) }
        session.onPlaying = { [weak self] in self?.playing?() }
        lock.withLock {
            live?.stop()
            live = session
        }
        statusChanged?(true)
        session.start()
    }

    /// The main stream (about 2–3 Mbit/s) only for a large view with the bandwidth for it; otherwise the
    /// sub-stream, which is far lighter. Sending more than the viewer asked for makes it freeze.
    func source(width: Int, maxBitrate: Int) -> (url: String, username: String, password: String) {
        width >= 1280 && maxBitrate >= Self.mainStreamBitrate ? main : sub
    }

    /// The viewer asks for another size or bitrate (its window grew, or the network changed): the stream
    /// that suits it from its next keyframe, if that is the other one.
    private func reconfigure(_ video: [TLV8Item]) {
        let attributes = video.value(0x03).flatMap { try? TLV8.decode($0) } ?? []
        let rtp = video.value(0x04).flatMap { try? TLV8.decode($0) } ?? []
        guard let session = lock.withLock({ live }), !session.isStopped else { return }
        if reencode {
            // The Home app's new ask raises the rate if it is higher; lower, the viewer's reports decide.
            let asked = Self.target(video, current: session.reencodeTarget)
            session.askedFor(bitrate: asked.bitrate)
            log("… HomeKit live: up to \(asked.bitrate) kbit/s now asked")
            return
        }
        let width = LE.u16(attributes.value(0x01)) ?? session.video.width
        let height = LE.u16(attributes.value(0x02)) ?? session.video.height
        let bitrate = LE.u16(rtp.value(0x03)) ?? session.video.maxBitrate
        let next = source(width: width, maxBitrate: bitrate)
        let name = next.url == main.url ? "main stream" : "sub-stream"
        if session.switchSource(to: next) {
            log("… HomeKit live: \(width)×\(height), up to \(bitrate) kbit/s now asked; switching to the \(name)")
        } else {
            log("… HomeKit live: \(width)×\(height), up to \(bitrate) kbit/s now asked; staying on the \(name)")
        }
    }

    func stop() {
        let session = lock.withLock {
            defer { live = nil; prepared = nil }
            return live
        }
        session?.stop()
    }
}
