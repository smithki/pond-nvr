// HAP's transport: HTTP/1.1 over TCP, encrypted after pair verify.
//
// Encrypted, the byte stream is cut into frames of at most 1024 bytes: a 2-byte little-endian length (also
// the authenticated data), the ChaCha20-Poly1305 ciphertext, and its 16-byte tag. Each direction counts its
// frames from zero; the nonce is four zero bytes and the count as 8 little-endian bytes.
import CryptoKit
import Foundation

/// One direction of an encrypted session.
public struct FrameCipher: Sendable {
    let key: SymmetricKey
    private(set) var counter: UInt64 = 0
    /// Bytes received but not yet a whole frame.
    private var pending: [UInt8] = []

    public static let maxFrame = 1024

    public init(key: SymmetricKey) { self.key = key }

    func nonce() -> ChaChaPoly.Nonce {
        var bytes: [UInt8] = [0, 0, 0, 0]
        for i in 0 ..< 8 { bytes.append(UInt8(truncatingIfNeeded: counter >> (8 * UInt64(i)))) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Encrypts plain bytes into frames.
    public mutating func seal(_ plain: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var offset = 0
        repeat {
            let chunk = Array(plain[offset ..< min(offset + Self.maxFrame, plain.count)])
            let length: [UInt8] = [UInt8(chunk.count & 0xFF), UInt8(chunk.count >> 8)]
            let box = try! ChaChaPoly.seal(chunk, using: key, nonce: nonce(), authenticating: length)
            out += length + Array(box.ciphertext) + Array(box.tag)
            counter += 1
            offset += chunk.count
        } while offset < plain.count
        return out
    }

    public enum OpenError: Error { case badFrame }

    /// Decrypts whatever whole frames have arrived; keeps the rest for next time.
    public mutating func open(_ received: [UInt8]) throws(OpenError) -> [UInt8] {
        pending += received
        var out: [UInt8] = []
        while pending.count >= 2 {
            let length = Int(pending[0]) | Int(pending[1]) << 8
            guard length <= Self.maxFrame else { throw .badFrame }
            guard pending.count >= 2 + length + 16 else { break }
            let aad = Array(pending[0 ..< 2])
            let cipher = pending[2 ..< 2 + length], tag = pending[2 + length ..< 2 + length + 16]
            guard let box = try? ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: cipher, tag: tag),
                  let plain = try? ChaChaPoly.open(box, using: key, authenticating: aad) else { throw .badFrame }
            out += plain
            counter += 1
            pending.removeFirst(2 + length + 16)
        }
        return out
    }
}

/// An HTTP request as HAP sends them.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: [UInt8]
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String?
    public var body: [UInt8]

    public init(status: Int, contentType: String? = nil, body: [UInt8] = []) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 207: "Multi-Status"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 422: "Unprocessable Entity"
        case 470: "Connection Authorization Required"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    /// The bytes on the wire; `event` makes it an EVENT/1.0 notification.
    public func serialized(event: Bool = false) -> [UInt8] {
        var head = event ? "EVENT/1.0 200 OK\r\n" : "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Array(head.utf8) + body
    }
}

/// Collects bytes into whole requests.
public struct HTTPRequestReader: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public enum ReadError: Error { case malformed }

    public mutating func add(_ bytes: [UInt8]) throws(ReadError) -> [HTTPRequest] {
        buffer += bytes
        var out: [HTTPRequest] = []
        while let end = Self.headerEnd(buffer) {
            guard let head = String(bytes: buffer[0 ..< end], encoding: .utf8) else { throw .malformed }
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            guard first.count >= 2 else { throw .malformed }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard buffer.count >= end + 4 + length else { break }
            let body = Array(buffer[end + 4 ..< end + 4 + length])
            buffer.removeFirst(end + 4 + length)
            let target = String(first[1])
            var query: [String: String] = [:]
            let parts = target.split(separator: "?", maxSplits: 1)
            if parts.count == 2 {
                for pair in parts[1].split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    query[String(kv[0])] = kv.count == 2 ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : ""
                }
            }
            out.append(HTTPRequest(method: String(first[0]), path: String(parts[0]), query: query, headers: headers, body: body))
        }
        return out
    }

    static func headerEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0 ... b.count - 4 where b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 { return i }
        return nil
    }
}
