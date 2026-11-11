import Testing
@testable import Ingest

/// Answers each request with the next scripted chunk of bytes, and records what was sent.
final class ScriptedTransport: RTSPTransport {
    var replies: [[UInt8]]
    var sent: [String] = []
    var pending: [UInt8] = []

    init(_ replies: [[UInt8]]) { self.replies = replies }

    func send(_ bytes: [UInt8]) throws(TransportError) {
        sent.append(String(decoding: bytes, as: UTF8.self))
        if !replies.isEmpty { pending += replies.removeFirst() }
    }

    func receive(timeout: Double) throws(TransportError) -> [UInt8] {
        if pending.isEmpty {
            if replies.isEmpty { return [] }
            pending = replies.removeFirst()   // unsolicited data
        }
        // Hand bytes over in small pieces, so the reader has to join them.
        let n = min(7, pending.count)
        defer { pending.removeFirst(n) }
        return Array(pending.prefix(n))
    }

    func close() {}
}

@Suite struct RTSPTests {
    @Test func readerSplitsResponsesAndInterleavedData() throws {
        var reader = RTSPReader()
        let sr = Fixtures.senderReport(packets: 0)
        reader.feed(Fixtures.interleaved(1, sr) + Fixtures.response("200 OK", ["CSeq: 3", "Session: 1234;timeout=60"]))
        #expect(try reader.next() == .interleaved(InterleavedPacket(channel: 1, data: sr)))
        guard case let .response(r)? = try reader.next() else { Issue.record("no response"); return }
        #expect(r.status == 200)
        #expect(r.header("session") == "1234;timeout=60")
        #expect(try reader.next() == nil)
    }

    @Test func readerWaitsForWholeItems() throws {
        var reader = RTSPReader()
        let bytes = Fixtures.response("200 OK", ["CSeq: 1"], body: "v=0\r\n")
        reader.feed(Array(bytes.prefix(10)))
        #expect(try reader.next() == nil)
        reader.feed(Array(bytes.dropFirst(10).dropLast(2)))
        #expect(try reader.next() == nil)
        reader.feed(Array(bytes.suffix(2)))
        guard case let .response(r)? = try reader.next() else { Issue.record("no response"); return }
        #expect(r.bodyText == "v=0\r\n")
    }

    @Test func readerRejectsGarbage() {
        var reader = RTSPReader()
        reader.feed(Array("HTTP/1.1 200 OK\r\n\r\n".utf8))
        #expect(throws: RTSPReader.ReadError.self) { try reader.next() }
    }

    @Test func aStreamThatLosesItsFramingIsReadOnFromTheNextPacket() throws {
        var reader = RTSPReader()
        let packets: [[UInt8]] = (0 ..< 6).map { (i: Int) -> [UInt8] in
            let data: [UInt8] = (0 ..< 300 + i).map { (j: Int) -> UInt8 in UInt8(truncatingIfNeeded: j &* 13 &+ i) }
            return Fixtures.interleaved(UInt8(i % 2 * 2), data)
        }
        // Two packets, then the end of one whose start never came (bytes that are neither), then the rest.
        let garbage: [UInt8] = (0 ..< 40_000).map { (i: Int) -> UInt8 in
            let byte = UInt8(truncatingIfNeeded: (i &* 7919) % 251 + 3)
            return byte == 0x24 || byte == 0x52 ? 0x25 : byte
        }
        reader.feed(packets[0] + packets[1] + garbage + packets[2] + packets[3])
        var read: [InterleavedPacket] = []
        while let item = try reader.next() { if case let .interleaved(p) = item { read.append(p) } }
        // (Fed in pieces too: the rest a byte or two at a time, as a slow socket might.)
        for byte in (packets[4] + packets[5]).chunked(3) {
            reader.feed(byte)
            while let item = try reader.next() { if case let .interleaved(p) = item { read.append(p) } }
        }
        #expect(read.map(\.data.count) == [300, 301, 302, 303, 304, 305])
        #expect(reader.resyncs == 1 && reader.skipped == garbage.count)
    }

    @Test func aRequestFromTheCameraIsPassedOver() throws {
        var reader = RTSPReader()
        let packet = Fixtures.interleaved(0, [1, 2, 3])
        reader.feed(packet + Array("SET_PARAMETER rtsp://cam/ RTSP/1.0\r\nCSeq: 9\r\nContent-Length: 4\r\n\r\nab\r\n".utf8) + packet)
        #expect(try reader.next() == .interleaved(InterleavedPacket(channel: 0, data: [1, 2, 3])))
        #expect(try reader.next() == .interleaved(InterleavedPacket(channel: 0, data: [1, 2, 3])))
        #expect(reader.skipped == 0)
    }

    @Test func aStreamLostForAMegabyteIsGivenUpOn() throws {
        var reader = RTSPReader()
        reader.feed(Fixtures.interleaved(0, [1]))
        _ = try reader.next()
        reader.feed([UInt8](repeating: 0x11, count: 1_100_000))
        #expect(throws: RTSPReader.ReadError.self) { while try reader.next() != nil {} }
    }

    @Test func describeAnswersTheDigestChallenge() throws {
        let url = "rtsp://192.168.1.41:554/h264Preview_01_main"
        let t = ScriptedTransport([
            Fixtures.response("401 Unauthorized", ["CSeq: 1", #"WWW-Authenticate: Digest realm="BC Streaming Media", nonce="abc""#]),
            Fixtures.response("200 OK", ["CSeq: 2", "Content-Type: application/sdp"], body: Fixtures.mainSDP),
        ])
        let client = RTSPClient(transport: t, username: "admin", password: "pw", timeout: 1)
        let (sdp, base) = try client.describe(url)
        #expect(base == url)
        #expect(sdp.video?.encoding == "H264")
        #expect(t.sent.count == 2)
        #expect(!t.sent[0].contains("Authorization"))
        let expected = AuthChallenge.digest(realm: "BC Streaming Media", nonce: "abc", qop: nil, opaque: nil)
            .authorization(method: "DESCRIBE", uri: url, username: "admin", password: "pw")
        #expect(t.sent[1].contains("Authorization: \(expected)\r\n"))
        #expect(t.sent[1].hasPrefix("DESCRIBE \(url) RTSP/1.0\r\nCSeq: 2\r\n"))
    }

    @Test func wrongPasswordIsUnauthorized() {
        let challenge = #"WWW-Authenticate: Digest realm="BC Streaming Media", nonce="abc""#
        let t = ScriptedTransport([
            Fixtures.response("401 Unauthorized", ["CSeq: 1", challenge]),
            Fixtures.response("401 Unauthorized", ["CSeq: 2", challenge]),
        ])
        let client = RTSPClient(transport: t, username: "admin", password: "wrong", timeout: 1)
        #expect(throws: RTSPError.unauthorized) { try client.describe("rtsp://cam/main") }
    }

    @Test func missingStreamIsNotFound() {
        let t = ScriptedTransport([Fixtures.response("404 Not Found", ["CSeq: 1"])])
        let client = RTSPClient(transport: t, username: "admin", password: "pw", timeout: 1)
        #expect(throws: RTSPError.notFound("rtsp://cam/nope")) { try client.describe("rtsp://cam/nope") }
    }

    @Test func silenceTimesOut() {
        let t = ScriptedTransport([])
        let client = RTSPClient(transport: t, username: "admin", password: "pw", timeout: 0.2)
        #expect(throws: RTSPError.timeout("DESCRIBE")) { try client.describe("rtsp://cam/main") }
    }

    // Reolink sends an RTCP packet before its reply to PLAY; it must not be lost or mistaken for the reply.
    @Test func dataBeforeThePlayReplyIsKept() throws {
        let sr = Fixtures.senderReport(packets: 5)
        let t = ScriptedTransport([
            Fixtures.response("200 OK", ["CSeq: 1", "Session: 99;timeout=60", "Transport: RTP/AVP/TCP;unicast;interleaved=0-1"]),
            Fixtures.interleaved(1, sr) + Fixtures.response("200 OK", ["CSeq: 2", "Session: 99"]),
        ])
        let client = RTSPClient(transport: t, username: "admin", password: "pw", timeout: 1)
        try client.setup("rtsp://cam/main/track1", channel: 0)
        #expect(client.session == "99")
        try client.play("rtsp://cam/main")
        #expect(t.sent[1].contains("Session: 99\r\n"))
        #expect(try client.nextPacket(timeout: 0.1) == InterleavedPacket(channel: 1, data: sr))
        #expect(try client.nextPacket(timeout: 0.1) == nil)
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
