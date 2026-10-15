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

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) {
        if start > 65536 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer += bytes
    }

    /// The next complete item, or nil if more bytes are needed.
    public mutating func next() throws(ReadError) -> RTSPItem? {
        let available = buffer.count - start
        guard available > 0 else { return nil }
        if buffer[start] == 0x24 {   // "$"
            guard available >= 4 else { return nil }
            let length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard available >= 4 + length else { return nil }
            let packet = InterleavedPacket(channel: buffer[start + 1], data: Array(buffer[start + 4 ..< start + 4 + length]))
            start += 4 + length
            return .interleaved(packet)
        }
        guard let headerEnd = find([13, 10, 13, 10]) else {
            if available > 16384 { throw .malformed("no end of headers in 16 KB") }
            return nil
        }
        let headText = String(decoding: buffer[start ..< headerEnd], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("RTSP/"), let status = Int(parts[1]) else {
            throw .malformed("not an RTSP response: \(statusLine.prefix(60))")
        }
        var headers: [String: [String]] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name, default: []].append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let length = headers["content-length"]?.first.flatMap { Int($0) } ?? 0
        let bodyStart = headerEnd + 4
        guard buffer.count >= bodyStart + length else { return nil }
        let body = Array(buffer[bodyStart ..< bodyStart + length])
        start = bodyStart + length
        return .response(RTSPResponse(status: status, reason: parts.count > 2 ? parts[2] : "", headers: headers, body: body))
    }

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
