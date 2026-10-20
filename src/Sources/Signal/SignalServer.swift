// The signaling service: a blind courier between Ponds and their devices. Each connects to its mailbox (proving it's
// its own: the mailbox is the SHA-256 of a secret only it can derive), and sends envelopes to others' mailboxes;
// they're passed on to whoever's connected there, and kept nowhere (nobody there: "undelivered"). Envelopes are
// sealed end to end (Pond's Remote module), so all it ever learns is which mailboxes speak, when, and how much.
//
// Its messages, one JSON object a WebSocket text frame:
//   → {"op":"hello","mailbox":HEX,"secret":BASE64}            ← {"op":"ready"} | {"op":"error","why":…} (closed)
//   → {"op":"send","to":HEX,"sealed":BASE64}                  ← {"op":"sent"} | {"op":"undelivered","to":HEX}
//                                                             ← {"op":"envelope","to":HEX,"sealed":BASE64} (to the recipient)
// It also answers STUN binding requests on UDP (STUNResponder), so devices learn their public addresses from the
// same, self-hosted service, not a third party.
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import Traversal

public final class SignalServer: @unchecked Sendable {
    public struct Message: Codable, Equatable, Sendable {
        public var op: String
        public var mailbox: String?
        public var secret: Data?
        public var to: String?
        public var sealed: Data?
        public var why: String?

        public init(op: String, mailbox: String? = nil, secret: Data? = nil, to: String? = nil, sealed: Data? = nil, why: String? = nil) {
            self.op = op
            self.mailbox = mailbox
            self.secret = secret
            self.to = to
            self.sealed = sealed
            self.why = why
        }
    }

    /// The largest envelope passed on, and how many a connection may send a second (a burst of `burst`).
    public static let maxSealed = 64 * 1024, perSecond = 20.0, burst = 60.0

    let port: UInt16
    let log: @Sendable (String) -> Void
    private var listener: Int32 = -1
    private var mailboxes: [String: WebSocketConnection] = [:]
    private let lock = NSLock()

    public init(port: UInt16, log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.port = port
        self.log = log
    }

    /// The port it listens on (the one asked for; or, asked for 0, the one it was given).
    public private(set) var boundPort: UInt16 = 0

    /// Listening, on every address (IPv6 and IPv4); connections served each on a thread of their own.
    public func start() throws {
        listener = socket(AF_INET6, Int32(SOCK_STREAM_VALUE), 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var on: Int32 = 1, off: Int32 = 0
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(listener, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0, listen(listener, 64) == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(listener, $0, &length) }
        }
        boundPort = UInt16(bigEndian: address.sin6_port)
        let listening = listener
        Thread.detachNewThread { [self] in
            while true {
                let fd = accept(listening, nil, nil)
                guard fd >= 0 else { return }
                #if canImport(Darwin)
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                #endif
                Thread.detachNewThread { [self] in serve(WebSocketConnection(fd: fd)) }
            }
        }
        log("signaling on port \(boundPort)")
    }

    public func stop() {
        if listener >= 0 { shutdown(listener, Int32(SHUT_RDWR)) }
        lock.withLock {
            for connection in mailboxes.values { connection.close() }
            mailboxes = [:]
        }
    }

    /// How many mailboxes are connected now.
    public var connected: Int { lock.withLock { mailboxes.count } }

    func serve(_ connection: WebSocketConnection) {
        defer { connection.close() }
        guard connection.handshake() else { return }
        // First, its mailbox, proved.
        guard case let .text(text)? = connection.next(), let hello = Self.decode(text), hello.op == "hello",
              let mailbox = hello.mailbox, let secret = hello.secret,
              Self.hex(Hashes.sha256(Array(secret))) == mailbox.lowercased() else {
            connection.send(text: Self.encode(Message(op: "error", why: "not your mailbox")))
            return
        }
        // (Connected again: the newer connection is the one.)
        let previous = lock.withLock { () -> WebSocketConnection? in
            defer { mailboxes[mailbox] = connection }
            return mailboxes[mailbox]
        }
        previous?.close()
        defer { lock.withLock { if mailboxes[mailbox] === connection { mailboxes[mailbox] = nil } } }
        connection.send(text: Self.encode(Message(op: "ready")))

        var tokens = Self.burst, last = Date()
        while let frame = connection.next() {
            guard case let .text(text) = frame else { if case .close = frame { return }; continue }
            let now = Date()
            tokens = min(Self.burst, tokens + now.timeIntervalSince(last) * Self.perSecond)
            last = now
            guard tokens >= 1 else {
                connection.send(text: Self.encode(Message(op: "error", why: "too fast")))
                continue
            }
            tokens -= 1
            guard let message = Self.decode(text), message.op == "send", let to = message.to, let sealed = message.sealed,
                  sealed.count <= Self.maxSealed else {
                connection.send(text: Self.encode(Message(op: "error", why: "not understood")))
                continue
            }
            let recipient = lock.withLock { mailboxes[to.lowercased()] }
            if let recipient {
                recipient.send(text: Self.encode(Message(op: "envelope", to: to, sealed: sealed)))
                connection.send(text: Self.encode(Message(op: "sent")))
            } else {
                connection.send(text: Self.encode(Message(op: "undelivered", to: to)))
            }
        }
    }

    static func decode(_ text: String) -> Message? { try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) }
    static func encode(_ message: Message) -> String { String(decoding: (try? JSONEncoder().encode(message)) ?? Data(), as: UTF8.self) }
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

#if canImport(Glibc)
let SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
let SOCK_DGRAM_VALUE = Int32(SOCK_DGRAM.rawValue)
#else
let SOCK_STREAM_VALUE = SOCK_STREAM
let SOCK_DGRAM_VALUE = SOCK_DGRAM
#endif
