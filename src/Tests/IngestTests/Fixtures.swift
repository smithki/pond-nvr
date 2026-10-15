// The stream descriptions a Reolink E1 Pro sends (main stream; the sub-stream differs only in its SPS).
enum Fixtures {
    static let mainSDP = """
    v=0\r
    o=- 1791932239284121 1 IN IP4 192.168.0.3\r
    s=Session streamed by "preview"\r
    i=reolink rtsp stream\r
    t=0 0\r
    a=tool:BC Streaming Media v202210012022.10.01\r
    a=type:broadcast\r
    a=control:*\r
    a=range:npt=now-\r
    m=video 0 RTP/AVP 96\r
    c=IN IP4 0.0.0.0\r
    b=AS:8192\r
    a=rtpmap:96 H264/90000\r
    a=fmtp:96 packetization-mode=1;profile-level-id=640033;sprop-parameter-sets=Z2QAM6wVFKAoALWQ,aO48sA==\r
    a=recvonly\r
    a=control:track1\r
    m=audio 0 RTP/AVP 97\r
    c=IN IP4 0.0.0.0\r
    b=AS:8192\r
    a=rtpmap:97 MPEG4-GENERIC/16000\r
    a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1408\r
    a=recvonly\r
    a=control:track2\r

    """

    static let subSDP = mainSDP.replacingOccurrences(of: "Z2QAM6wVFKAoALWQ", with: "Z2QAM6wVFKDgEGQ=")

    static func response(_ status: String, _ headers: [String] = [], body: String = "") -> [UInt8] {
        var text = "RTSP/1.0 \(status)\r\n" + headers.map { $0 + "\r\n" }.joined()
        if !body.isEmpty { text += "Content-Length: \(body.utf8.count)\r\n" }
        return Array((text + "\r\n" + body).utf8)
    }

    static func interleaved(_ channel: UInt8, _ data: [UInt8]) -> [UInt8] {
        [0x24, channel, UInt8(data.count >> 8), UInt8(data.count & 0xFF)] + data
    }

    /// An RTP packet carrying an H.264 payload.
    static func rtp(seq: UInt16, ts: UInt32, payload: [UInt8]) -> [UInt8] {
        [0x80, 0x60, UInt8(seq >> 8), UInt8(seq & 0xFF),
         UInt8(ts >> 24), UInt8(ts >> 16 & 0xFF), UInt8(ts >> 8 & 0xFF), UInt8(ts & 0xFF),
         0x12, 0x34, 0x56, 0x78] + payload
    }

    /// An RTCP sender report saying `packets` were sent.
    static func senderReport(packets: UInt32) -> [UInt8] {
        [0x80, 200, 0x00, 0x06, 0x67, 0x45, 0x0E, 0xEB] + [UInt8](repeating: 0, count: 12)
            + [UInt8(packets >> 24), UInt8(packets >> 16 & 0xFF), UInt8(packets >> 8 & 0xFF), UInt8(packets & 0xFF)]
            + [0, 0, 0, 0]
    }
}
