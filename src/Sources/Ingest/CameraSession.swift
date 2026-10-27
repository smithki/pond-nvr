// One playing stream from a camera: video on interleaved channels 0-1, audio (if any) on 2-3, over one
// TCP connection. Keeps the session alive while packets are read.
import Foundation

public final class CameraSession {
    public static let videoChannel: UInt8 = 0
    public static let audioChannel: UInt8 = 2

    public let video: SDP.Media
    public let audio: SDP.Media?
    let client: RTSPClient
    let url: String
    let base: String
    /// Told when a camera's stream lost its framing and was read on from the next packet (the stream's address,
    /// and the bytes skipped): for the service's log.
    nonisolated(unsafe) public static var framingLost: (@Sendable (_ url: String, _ bytes: Int) -> Void)?
    private var framingLostSeen = (times: 0, bytes: 0)
    private var lastKeepalive = Date()
    let keepaliveInterval: Double = 25

    public init(url: String, username: String, password: String, connectTimeout: Double = 5,
                includeAudio: Bool = true) throws(RTSPError) {
        guard let parts = URLComponents(string: url), let host = parts.host else { throw .malformed("bad address \(url)") }
        self.url = url
        let transport: SocketTransport
        do {
            transport = try SocketTransport(host: host, port: parts.port ?? 554, timeout: connectTimeout)
        } catch {
            throw .transport(error)
        }
        client = RTSPClient(transport: transport, username: username, password: password)
        let (sdp, base) = try client.describe(url)
        guard let video = sdp.video else { throw .malformed("the stream has no video") }
        self.base = base
        self.video = video
        try client.setup(SDP.trackURL(base: base, control: video.control), channel: Self.videoChannel)
        var audio: SDP.Media?
        if includeAudio, let a = sdp.audio, a.encoding.uppercased() == "MPEG4-GENERIC" {
            // Some cameras refuse a second track; the recording then simply has no sound.
            if (try? client.setup(SDP.trackURL(base: base, control: a.control), channel: Self.audioChannel)) != nil {
                audio = a
            }
        }
        self.audio = audio
        try client.play(base)
        lastKeepalive = Date()
    }

    /// The next packet, or nil if none arrived within `timeout` seconds.
    public func next(timeout: Double) throws(RTSPError) -> InterleavedPacket? {
        if Date().timeIntervalSince(lastKeepalive) > keepaliveInterval {
            try client.sendWithoutReply("GET_PARAMETER", base)
            lastKeepalive = Date()
        }
        let packet = try client.nextPacket(timeout: min(timeout, keepaliveInterval))
        let lost = client.framingLost
        if lost.times > framingLostSeen.times {
            Self.framingLost?(url, lost.bytes - framingLostSeen.bytes)
            framingLostSeen = lost
        }
        return packet
    }

    public func close() {
        client.teardown(base)
        client.transport.close()
    }
}
