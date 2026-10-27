// WebSocket (RFC 6455), as much as the signaling service needs, over a plain socket: the handshake (an HTTP upgrade,
// answered with SHA-1 of the client's key), and frames (text, close, ping and pong; a client's frames masked, the
// server's not). Plain Swift and POSIX, so it builds on Linux with nothing added.
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import Traversal

/// A connection to one client: read frames, write frames, closed once.
final class WebSocketConnection: @unchecked Sendable {
    let fd: Int32
    private var buffer: [UInt8] = []
    private let writeLock = NSLock()
    private var closed = false
    /// The largest message taken.
    static let maxMessage = 128 * 1024

    init(fd: Int32) { self.fd = fd }

    enum Frame {
        case text(String)
        case binary([UInt8])
        case close
    }

    /// The HTTP upgrade read and answered; false if it isn't one. Anything else is answered too, plainly, and the
    /// connection closed: `/health` with 200 (for checking the server is up), the rest with 426 (a WebSocket is
    /// what's served), so a proxy in front shows that rather than a connection dropped unanswered.
    func handshake() -> Bool {
        guard let request = readUntil("\r\n\r\n") else { return false }
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard first.first == "GET", headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] else {
            let health = first.count > 1 && first[1] == "/health"
            let body = health ? "ok\n" : "Pond's signaling service: Pond connects here with a WebSocket.\n"
            let head = (health ? "HTTP/1.1 200 OK" : "HTTP/1.1 426 Upgrade Required\r\nUpgrade: websocket")
                + "\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            writeRaw(Array((head + (first.first == "HEAD" ? "" : body)).utf8))
            return false
        }
        let accept = Data(Hashes.sha1(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        writeRaw(Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
        return true
    }

    /// The next message (pings answered on the way); nil when the connection ends.
    func next() -> Frame? {
        var message: [UInt8] = []
        var messageOpcode: UInt8 = 0
        while true {
            guard let head = read(2) else { return nil }
            let fin = head[0] & 0x80 != 0, opcode = head[0] & 0x0F, masked = head[1] & 0x80 != 0
            var length = Int(head[1] & 0x7F)
            if length == 126 {
                guard let ext = read(2) else { return nil }
                length = Int(ext[0]) << 8 | Int(ext[1])
            } else if length == 127 {
                guard let ext = read(8) else { return nil }
                length = ext.reduce(0) { $0 << 8 | Int($1) }
            }
            guard length <= Self.maxMessage, message.count + length <= Self.maxMessage else { return nil }
            let mask = masked ? read(4) : nil
            guard var payload = read(length) else { return nil }
            if let mask { for i in payload.indices { payload[i] ^= mask[i % 4] } }
            switch opcode {
            case 0x8: return .close
            case 0x9: send(opcode: 0xA, payload)
            case 0xA: break
            default:
                if opcode != 0 { messageOpcode = opcode }
                message += payload
                if fin {
                    return messageOpcode == 0x1 ? .text(String(decoding: message, as: UTF8.self)) : .binary(message)
                }
            }
        }
    }

    func send(text: String) { send(opcode: 0x1, Array(text.utf8)) }

    func send(opcode: UInt8, _ payload: [UInt8]) {
        var frame: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            frame.append(127)
            frame += (0 ..< 8).map { UInt8(truncatingIfNeeded: payload.count >> (56 - 8 * $0)) }
        }
        writeRaw(frame + payload)
    }

    func close() {
        writeLock.withLock {
            guard !closed else { return }
            closed = true
            shutdown(fd, Int32(SHUT_RDWR))
            #if canImport(Glibc)
            Glibc.close(fd)
            #else
            Darwin.close(fd)
            #endif
        }
    }

    // MARK: Bytes

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 16384)
        let n = recv(fd, &chunk, chunk.count, 0)
        guard n > 0 else { return false }
        buffer += chunk[0 ..< n]
        return true
    }

    private func read(_ count: Int) -> [UInt8]? {
        while buffer.count < count { guard fill() else { return nil } }
        defer { buffer.removeFirst(count) }
        return Array(buffer[0 ..< count])
    }

    private func readUntil(_ end: String) -> [UInt8]? {
        let marker = Array(end.utf8)
        while true {
            if let range = find(marker) {
                defer { buffer.removeFirst(range) }
                return Array(buffer[0 ..< range])
            }
            guard buffer.count < 16384, fill() else { return nil }
        }
    }

    private func find(_ marker: [UInt8]) -> Int? {
        guard buffer.count >= marker.count else { return nil }
        for i in 0 ... buffer.count - marker.count where Array(buffer[i ..< i + marker.count]) == marker { return i + marker.count }
        return nil
    }

    private func writeRaw(_ bytes: [UInt8]) {
        writeLock.withLock {
            guard !closed else { return }
            var sent = 0
            while sent < bytes.count {
                let n = bytes[sent...].withUnsafeBytes { Foundation.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL_OR_ZERO)) }
                guard n > 0 else { return }
                sent += n
            }
        }
    }
}

#if canImport(Glibc)
let MSG_NOSIGNAL_OR_ZERO = Int32(MSG_NOSIGNAL)
#else
let MSG_NOSIGNAL_OR_ZERO: Int32 = 0
#endif
