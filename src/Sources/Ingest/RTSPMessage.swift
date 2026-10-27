// RTSP on the wire: requests out, and a reader that splits what comes back into RTSP responses and
// interleaved data ($, channel, length, packet), in whatever order the camera sends them. Reolink sends an
// RTCP packet before its reply to PLAY, so a reply can never be assumed to come first.
import Foundation

public struct RTSPRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [(String, String)]

    public init(method: String, url: String, headers: [(String, String)] = []) {
        self.method = method
        self.url = url
        self.headers = headers
    }

    public func encoded() -> [UInt8] {
        var text = "\(method) \(url) RTSP/1.0\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        return Array((text + "\r\n").utf8)
    }
}

public struct RTSPResponse: Sendable, Equatable {
    public var status: Int
    public var reason: String
    /// Header names in lowercase; a header sent more than once keeps every value.
    public var headers: [String: [String]]
    public var body: [UInt8]

    public func header(_ name: String) -> String? { headers[name.lowercased()]?.first }
    public var bodyText: String { String(decoding: body, as: UTF8.self) }
}

public struct InterleavedPacket: Sendable, Equatable {
    public var channel: UInt8
    public var data: [UInt8]
    /// From before the reader joined (StreamHub's replay of the latest keyframe on): to catch up with, not
    /// to play at its own time.
    public var replayed: Bool

    public init(channel: UInt8, data: [UInt8], replayed: Bool = false) {
        self.channel = channel
        self.data = data
        self.replayed = replayed
    }
}

public enum RTSPItem: Sendable, Equatable {
    case response(RTSPResponse)
    case interleaved(InterleavedPacket)
}

public struct RTSPReader: Sendable {
    public enum ReadError: Error, Equatable {
        case malformed(String)
    }

    private var buffer: [UInt8] = []
    private var start = 0
    /// Something's been read: past the first reply, bytes that aren't a reply or a packet are a stream that's lost
    /// its framing (found again, below), not an answer that isn't RTSP.
    private var started = false
    /// Bytes skipped to find the framing again, and how many times it was lost.
    public private(set) var skipped = 0, resyncs = 0

    /// Lost for this long (no packet or reply found in it): the stream's given up on.
    static let giveUpAfter = 1 << 20

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) {
        if start > 65536 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer += bytes
    }

    /// The next complete item, or nil if more bytes are needed. A camera's stream that loses its framing now and
    /// then (bytes that are neither a packet nor a reply: Reolink's, a few times a day) is read on from the next
    /// packet, the bytes in between skipped and counted, rather than given up on.
    public mutating func next() throws(ReadError) -> RTSPItem? {
        while true {
            let available = buffer.count - start
            guard available > 0 else { return nil }
            if buffer[start] == 0x24 {   // "$"
                guard available >= 4 else { return nil }
                let length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                // (Once started: a channel no camera uses means it's not a packet.)
                if started, buffer[start + 1] >= 8 {
                    try resync()
                    continue
                }
                guard available >= 4 + length else { return nil }
                let packet = InterleavedPacket(channel: buffer[start + 1], data: Array(buffer[start + 4 ..< start + 4 + length]))
                start += 4 + length
                started = true
                skippedSince = 0
                return .interleaved(packet)
            }
            if started, !Self.isUpper(buffer[start]) {
                try resync()
                continue
            }
            guard let headerEnd = find([13, 10, 13, 10]) else {
                if available > 16384 {
                    if started {
                        try resync()
                        continue
                    }
                    throw .malformed("no end of headers in 16 KB")
                }
                return nil
            }
            let headText = String(decoding: buffer[start ..< headerEnd], as: UTF8.self)
            var lines = headText.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst()
            let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
            var headers: [String: [String]] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[name, default: []].append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            let length = headers["content-length"]?.first.flatMap { Int($0) } ?? 0
            let bodyStart = headerEnd + 4
            // A request from the camera (some send them, unasked): passed over.
            if started, parts.count == 3, parts[2].hasPrefix("RTSP/"), parts[0].allSatisfy({ $0.isUppercase || $0 == "_" }) {
                guard buffer.count >= bodyStart + length else { return nil }
                start = bodyStart + length
                continue
            }
            guard parts.count >= 2, parts[0].hasPrefix("RTSP/"), let status = Int(parts[1]) else {
                if started {
                    try resync()
                    continue
                }
                throw .malformed("not an RTSP response: \(statusLine.prefix(60))")
            }
            guard buffer.count >= bodyStart + length else { return nil }
            let body = Array(buffer[bodyStart ..< bodyStart + length])
            start = bodyStart + length
            started = true
            skippedSince = 0
            return .response(RTSPResponse(status: status, reason: parts.count > 2 ? parts[2] : "", headers: headers, body: body))
        }
    }

    /// The framing found again: on to the next byte that starts a believable packet or reply (counting what's
    /// skipped). Nothing believable in a megabyte: given up on.
    private mutating func resync() throws(ReadError) {
        let from = start
        var i = start + 1
        while i < buffer.count {
            if buffer[i] == 0x24, plausiblePacket(at: i) { break }
            if buffer[i] == 0x52, plausibleReply(at: i) { break }   // "R"
            i += 1
        }
        if skippedSince == 0 { resyncs += 1 }
        skipped += i - from
        skippedSince += i - from
        start = i
        if skippedSince > Self.giveUpAfter { throw .malformed("the stream lost its framing, and nothing in 1 MB found it again") }
    }

    /// Bytes skipped since the framing was lost, until something's read again.
    private var skippedSince = 0

    /// A packet could start here: a channel a camera uses (0–7), and after it (if it's come) another packet or a
    /// reply or request's first letter. Unsure (not all come yet): yes.
    private func plausiblePacket(at i: Int) -> Bool {
        guard i + 1 < buffer.count else { return true }
        guard buffer[i + 1] < 8 else { return false }
        guard i + 4 <= buffer.count else { return true }
        let after = i + 4 + (Int(buffer[i + 2]) << 8 | Int(buffer[i + 3]))
        guard after < buffer.count else { return true }
        return buffer[after] == 0x24 || Self.isUpper(buffer[after])
    }

    /// A reply could start here: "RTSP/1." (as much of it as has come).
    private func plausibleReply(at i: Int) -> Bool {
        let expected = Array("RTSP/1.".utf8)
        return zip(buffer[i...], expected).allSatisfy { $0 == $1 }
    }

    static func isUpper(_ b: UInt8) -> Bool { (0x41 ... 0x5A).contains(b) }

    private func find(_ needle: [UInt8]) -> Int? {
        guard buffer.count - start >= needle.count else { return nil }
        var i = start
        while i <= buffer.count - needle.count {
            if buffer[i] == needle[0], buffer[i + 1] == needle[1], buffer[i + 2] == needle[2], buffer[i + 3] == needle[3] {
                return i
            }
            i += 1
        }
        return nil
    }
}
