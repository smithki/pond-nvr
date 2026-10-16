// Sound to a camera's speaker over its own RTSP: ONVIF's backchannel (ONVIF Streaming Specification, 5.3).
// A DESCRIBE that asks for it (Require: www.onvif.org/ver20/backchannel) gets an extra audio track the
// client sends on (a=sendonly, as the client sees it), usually G.711 at 8 kHz; SETUP and PLAY it over the
// same TCP connection, then send RTP on its interleaved channel. 20 ms to a packet; a GET_PARAMETER now and
// then keeps the session alive, and what the camera sends back (its RTCP) is read and dropped.
import Foundation

public final class Backchannel: @unchecked Sendable {
    public static let require = ("Require", "www.onvif.org/ver20/backchannel")

    /// The camera's track for it: its encoding ("PCMU", "PCMA") and clock rate.
    public let track: SDP.Media
    public var sampleRate: Double { Double(track.clockRate) }

    private let client: RTSPClient
    private let transport: RTSPTransport
    private let url: String
    private let lock = NSLock()
    private var pending: [Int16] = []
    private var sequence = UInt16.random(in: 0 ... .max)
    private var timestamp = UInt32.random(in: 0 ... .max)
    private let ssrc = UInt32.random(in: 0 ... .max)
    private var lastKeepalive = Date()
    private var closed = false

    /// The encodings Pond can send.
    static let encodings: Set<String> = ["PCMU", "PCMA"]

    /// Opens the backchannel of the stream at `url` (the camera's main stream); fails with `.notFound` if the
    /// camera offers none Pond can send.
    public init(url: String, username: String, password: String, timeout: Double = 6) throws(RTSPError) {
        guard let parts = URLComponents(string: url), let host = parts.host else { throw .malformed("not an RTSP address") }
        let transport: SocketTransport
        do {
            transport = try SocketTransport(host: host, port: parts.port ?? 554, timeout: timeout)
        } catch {
            throw .transport(error)
        }
        let client = RTSPClient(transport: transport, username: username, password: password, timeout: timeout)
        do throws(RTSPError) {
            let reply = try client.request("DESCRIBE", url, headers: [("Accept", "application/sdp"), Self.require])
            var base = reply.header("content-base") ?? url
            if base.hasSuffix("/") { base.removeLast() }
            let sdp = SDP(reply.bodyText)
            guard let track = sdp.backchannel, Self.encodings.contains(track.encoding.uppercased()), track.clockRate > 0 else {
                throw RTSPError.notFound("a backchannel at \(url)")
            }
            try client.setup(SDP.trackURL(base: base, control: track.control), channel: 0, headers: [Self.require])
            try client.play(base, headers: [Self.require])
            self.track = track
        } catch {
            transport.close()
            throw error
        }
        self.client = client
        self.transport = transport
        self.url = url
    }

    /// The backchannel track the stream at `url` offers, if any Pond can send (a DESCRIBE only: nothing is
    /// set up).
    public static func offered(url: String, username: String, password: String, timeout: Double = 6) -> SDP.Media? {
        guard let parts = URLComponents(string: url), let host = parts.host,
              let transport = try? SocketTransport(host: host, port: parts.port ?? 554, timeout: timeout) else { return nil }
        defer { transport.close() }
        let client = RTSPClient(transport: transport, username: username, password: password, timeout: timeout)
        guard let reply = try? client.request("DESCRIBE", url, headers: [("Accept", "application/sdp"), require]),
              let track = SDP(reply.bodyText).backchannel, encodings.contains(track.encoding.uppercased()) else { return nil }
        return track
    }

    /// Samples at `sampleRate`, sent as they fill packets of 20 ms.
    public func send(_ samples: [Int16]) throws(RTSPError) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw .transport(.closed) }
        pending += samples
        let size = Int(sampleRate / 50)
        while pending.count >= size {
            let frame = Array(pending.prefix(size))
            pending.removeFirst(size)
            try client.sendRaw(packet(frame))
        }
        try client.drain()
        if Date().timeIntervalSince(lastKeepalive) > 20 {
            lastKeepalive = Date()
            try client.sendWithoutReply("GET_PARAMETER", url)
        }
    }

    /// One RTP packet, interleaved on channel 0.
    func packet(_ samples: [Int16]) -> [UInt8] {
        let payload = track.encoding.uppercased() == "PCMA" ? samples.map(G711.aLaw) : samples.map(G711.muLaw)
        var rtp: [UInt8] = [0x80, UInt8(track.payloadType & 0x7F)]
        rtp += [UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        rtp += withUnsafeBytes(of: timestamp.bigEndian, Array.init)
        rtp += withUnsafeBytes(of: ssrc.bigEndian, Array.init)
        rtp += payload
        sequence &+= 1
        timestamp &+= UInt32(samples.count)
        let length = UInt16(rtp.count)
        return [0x24, 0, UInt8(length >> 8), UInt8(length & 0xFF)] + rtp
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        client.teardown(url)
        transport.close()
    }

    deinit { close() }
}

/// G.711: 16-bit samples to 8-bit µ-law (North America, Japan) or A-law (elsewhere), as ITU-T G.711.
public enum G711 {
    public static func muLaw(_ sample: Int16) -> UInt8 {
        let bias = 0x84, clip = 32635
        var s = Int(sample)
        let sign = s < 0 ? 0x80 : 0
        if s < 0 { s = -s }
        s = min(s, clip) + bias
        var exponent = 7
        var mask = 0x4000
        while exponent > 0, s & mask == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (s >> (exponent + 3)) & 0x0F
        return UInt8(~(sign | (exponent << 4) | mantissa) & 0xFF)
    }

    public static func aLaw(_ sample: Int16) -> UInt8 {
        var s = Int(sample) >> 3
        let sign = s >= 0 ? 0x80 : 0
        if s < 0 { s = -s - 1 }
        s = min(s, 0xFFF)
        let value: Int
        if s < 32 {
            value = s >> 1
        } else {
            var exponent = 1
            var t = s >> 5
            while t > 1 {
                t >>= 1
                exponent += 1
            }
            value = (exponent << 4) | ((s >> exponent) & 0x0F)
        }
        return UInt8((sign | value) ^ 0x55)
    }
}
