// The HomeKit Data Stream (HDS): a TCP connection a controller (the home hub, for HomeKit Secure Video)
// opens to the accessory beside the HAP session, for messages too big or too many for characteristics.
//
// Set up through the Data Stream Transport Management service: the controller writes Setup Data Stream
// Transport with a 32-byte salt; the accessory adds its own salt, derives two keys from the HAP session's
// shared secret (HKDF-SHA512, salt = controller's then accessory's, info "HDS-Read-Encryption-Key" for
// accessory to controller and "HDS-Write-Encryption-Key" the other way), opens a port, and answers with
// it and its salt. The controller connects within a few seconds; the connection is matched to its setup
// by which keys open its first frame, which must be a `control`/`hello` request (answered at once).
//
// Frames: type 1 (one byte), the payload's length (3 bytes, big-endian), the payload encrypted with
// ChaCha20-Poly1305 (the 4 header bytes authenticated; the nonce four zero bytes and a count from zero, 8
// bytes little-endian, one count per direction), then the 16-byte tag. A payload is a header's length
// (one byte), the header, then the message, both opack: the header {protocol, request | response | event,
// id, status}. HAP-NodeJS's DataStreamServer and DataStreamManagement are the reference.
import CryptoKit
import Foundation
import Network

public enum DataStream {
    /// Data Stream Transport Management's characteristics.
    public static let supportedTransportConfiguration = "130"
    public static let setupTransport = "131"
    /// HDS over TCP is transport type 0, the only one.
    public static let supportedConfiguration: [UInt8] = TLV8.encode([TLV8Item(0x01, TLV8.encode([TLV8Item(0x01, [0])]))])
    public static let version = "1.0"
    /// The largest payload a frame may carry.
    public static let maxPayload = 0xFFFFF

    /// The two keys for a connection: `read` encrypts what the accessory sends, `write` opens what it gets.
    public struct Keys: Sendable, Equatable {
        public let read: [UInt8]
        public let write: [UInt8]

        public init(sharedSecret: [UInt8], controllerSalt: [UInt8], accessorySalt: [UInt8]) {
            let salt = controllerSalt + accessorySalt
            read = HAPCrypto.hkdfBytes(sharedSecret, salt: salt, info: "HDS-Read-Encryption-Key")
            write = HAPCrypto.hkdfBytes(sharedSecret, salt: salt, info: "HDS-Write-Encryption-Key")
        }
    }

    /// One direction's frames: sealed with its key and a count.
    public struct Cipher: Sendable {
        let key: SymmetricKey
        private(set) var count: UInt64 = 0

        public init(key: [UInt8]) { self.key = SymmetricKey(data: key) }

        func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
            try! ChaChaPoly.Nonce(data: [0, 0, 0, 0] + (0 ..< 8).map { UInt8(truncatingIfNeeded: n >> (8 * UInt64($0))) })
        }

        public mutating func seal(_ payload: [UInt8]) -> [UInt8] {
            let n = payload.count
            let header: [UInt8] = [1, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            let box = try! ChaChaPoly.seal(payload, using: key, nonce: nonce(count), authenticating: header)
            count += 1
            return header + box.ciphertext + box.tag
        }

        /// A frame's payload, or nil if it doesn't open with this key at this count (the count moves on only
        /// when it does).
        public mutating func open(header: [UInt8], sealed: [UInt8], tag: [UInt8]) -> [UInt8]? {
            guard let box = try? ChaChaPoly.SealedBox(nonce: nonce(count), ciphertext: sealed, tag: tag),
                  let plain = try? ChaChaPoly.open(box, using: key, authenticating: header) else { return nil }
            count += 1
            return [UInt8](plain)
        }
    }

    /// A sealed frame, split from the bytes that came.
    public struct Frame: Sendable, Equatable {
        public var header: [UInt8]
        public var sealed: [UInt8]
        public var tag: [UInt8]
    }

    /// Frames from a byte stream, as they complete.
    public struct FrameReader: Sendable {
        private var buffer: [UInt8] = []

        public init() {}

        public enum Failure: Error, Equatable { case tooLong, unknownType(UInt8) }

        public mutating func push(_ bytes: [UInt8]) throws(Failure) -> [Frame] {
            buffer += bytes
            var frames: [Frame] = []
            while buffer.count >= 4 {
                let length = Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
                guard length <= DataStream.maxPayload else { throw .tooLong }
                guard buffer.count >= 4 + length + 16 else { break }
                let type = buffer[0]
                let frame = Frame(header: Array(buffer[0 ..< 4]), sealed: Array(buffer[4 ..< 4 + length]),
                                  tag: Array(buffer[4 + length ..< 4 + length + 16]))
                buffer.removeFirst(4 + length + 16)
                guard type == 1 else { throw .unknownType(type) }
                frames.append(frame)
            }
            return frames
        }
    }

    /// A message: an event, a request (with an id), or a response (to an id, with a status).
    public struct Message: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case event, request, response }

        public var kind: Kind
        public var `protocol`: String
        public var topic: String
        public var id: Int64?
        /// For responses: 0 is success.
        public var status: Int64?
        public var body: Opack

        public init(kind: Kind, protocol: String, topic: String, id: Int64? = nil, status: Int64? = nil,
                    body: Opack = .dictionary([])) {
            self.kind = kind
            self.protocol = `protocol`
            self.topic = topic
            self.id = id
            self.status = status
            self.body = body
        }

        public var payload: [UInt8] {
            var header: [(String, Opack)] = [("protocol", .string(self.protocol))]
            switch kind {
            case .event: header.append(("event", .string(topic)))
            case .request: header.append(("request", .string(topic)))
            case .response: header.append(("response", .string(topic)))
            }
            if let id { header.append(("id", .int(id))) }
            if let status { header.append(("status", .int(status))) }
            let encodedHeader = Opack.dictionary(header).encoded
            return [UInt8(encodedHeader.count)] + encodedHeader + body.encoded
        }

        public init(payload: [UInt8]) throws(Opack.DecodeError) {
            guard let length = payload.first.map(Int.init), payload.count >= 1 + length else {
                throw Opack.DecodeError(description: "a payload shorter than its header")
            }
            let header = try Opack.decode(Array(payload[1 ..< 1 + length]))
            let rest = Array(payload[(1 + length)...])
            body = rest.isEmpty ? .dictionary([]) : try Opack.decode(rest)
            guard let proto = header["protocol"]?.string else { throw Opack.DecodeError(description: "a header without a protocol") }
            self.protocol = proto
            id = header["id"]?.int
            status = header["status"]?.int
            if let t = header["event"]?.string {
                kind = .event
                topic = t
            } else if let t = header["request"]?.string {
                kind = .request
                topic = t
            } else if let t = header["response"]?.string {
                kind = .response
                topic = t
            } else {
                throw Opack.DecodeError(description: "a header that is neither event, request nor response")
            }
        }

        /// The response to this request.
        public func response(status: Int64 = 0, body: Opack = .dictionary([])) -> Message {
            Message(kind: .response, protocol: self.protocol, topic: topic, id: id ?? 0, status: status, body: body)
        }
    }
}

/// The accessory's side: prepares sessions when a controller asks (Setup Data Stream Transport), listens for
/// their connections, answers `hello`, and hands everything else to `handler`.
public final class DataStreamServer: @unchecked Sendable {
    /// A message on a connection, and the connection to answer on.
    public var handler: (@Sendable (DataStream.Message, DataStreamConnection) -> Void)?
    public var log: @Sendable (String) -> Void = { _ in }

    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var prepared: [(keys: DataStream.Keys, until: Date)] = []
    private var connections: [ObjectIdentifier: DataStreamConnection] = [:]
    private let queue = DispatchQueue(label: "hds")
    /// Seconds a controller has to connect after setting up.
    static let connectWithin = 10.0

    public init() {}

    /// A controller's Setup Data Stream Transport write, on the session with `sharedSecret`: the TLV
    /// answer (status, port, the accessory's salt), or a status alone if it can't be done.
    public func setup(_ request: [UInt8], sharedSecret: [UInt8]?) -> [UInt8] {
        guard let items = try? TLV8.decode(request), items.value(0x01)?.first == 0,   // start session
              items.value(0x02)?.first == 0,                                         // HDS over TCP
              let controllerSalt = items.value(0x03), controllerSalt.count == 32, let sharedSecret else {
            return TLV8.encode([TLV8Item(0x01, [1])])                                // generic error
        }
        guard let port = startListening() else { return TLV8.encode([TLV8Item(0x01, [1])]) }
        let accessorySalt = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
        let keys = DataStream.Keys(sharedSecret: sharedSecret, controllerSalt: controllerSalt, accessorySalt: accessorySalt)
        lock.withLock {
            prepared.removeAll { $0.until < Date() }
            prepared.append((keys, Date().addingTimeInterval(Self.connectWithin)))
        }
        log("… HomeKit data stream: set up; waiting on port \(port)")
        return TLV8.encode([TLV8Item(0x01, [0]),
                            TLV8Item(0x02, TLV8.encode([TLV8Item(0x01, [UInt8(port & 0xFF), UInt8(port >> 8)])])),
                            TLV8Item(0x03, accessorySalt)])
    }

    /// The port, listening from the first setup on.
    private func startListening() -> UInt16? {
        if let port = lock.withLock({ port }) { return port }
        guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            return nil
        }
        lock.withLock {
            self.listener = listener
            self.port = port
        }
        return port
    }

    public func stop() {
        let (listener, open) = lock.withLock { () -> (NWListener?, [DataStreamConnection]) in
            defer { self.listener = nil; port = nil; connections = [:] }
            return (self.listener, Array(connections.values))
        }
        listener?.cancel()
        for c in open { c.close() }
    }

    private func accept(_ connection: NWConnection) {
        let stream = DataStreamConnection(connection: connection, server: self)
        lock.withLock { connections[ObjectIdentifier(stream)] = stream }
        connection.start(queue: queue)
        stream.receive()
    }

    /// The prepared session whose keys open `frame`, taken from those waiting.
    func identify(_ frame: DataStream.Frame) -> (keys: DataStream.Keys, payload: [UInt8])? {
        lock.withLock {
            prepared.removeAll { $0.until < Date() }
            for (i, p) in prepared.enumerated() {
                var cipher = DataStream.Cipher(key: p.keys.write)
                if let payload = cipher.open(header: frame.header, sealed: frame.sealed, tag: frame.tag) {
                    prepared.remove(at: i)
                    return (p.keys, payload)
                }
            }
            return nil
        }
    }

    func closed(_ connection: DataStreamConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    func received(_ message: DataStream.Message, on connection: DataStreamConnection) {
        if message.kind == .request, message.protocol == "control", message.topic == "hello" {
            connection.send(message.response())
            log("✓ HomeKit data stream: the controller said hello")
            return
        }
        handler?(message, connection)
    }
}

/// One controller's data stream: its frames in and out.
public final class DataStreamConnection: @unchecked Sendable {
    let connection: NWConnection
    weak var server: DataStreamServer?
    private let lock = NSLock()
    private var reader = DataStream.FrameReader()
    private var outgoing: DataStream.Cipher?
    private var incoming: DataStream.Cipher?
    private var isClosed = false
    /// Told once, when the connection closes (either side).
    public var onClose: (@Sendable () -> Void)? {
        get { lock.withLock { closeHandlers.last } }
        set { if let newValue { lock.withLock { closeHandlers.append(newValue) } } }
    }
    private var closeHandlers: [@Sendable () -> Void] = []

    init(connection: NWConnection, server: DataStreamServer) {
        self.connection = connection
        self.server = server
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.received([UInt8](data)) }
            if done || error != nil { self.close() } else if !self.lock.withLock({ self.isClosed }) { self.receive() }
        }
    }

    private func received(_ bytes: [UInt8]) {
        let frames: [DataStream.Frame]
        lock.lock()
        let pushed = Result { () throws(DataStream.FrameReader.Failure) -> [DataStream.Frame] in try reader.push(bytes) }
        lock.unlock()
        switch pushed {
        case let .success(f): frames = f
        case let .failure(error):
            server?.log("! HomeKit data stream: a frame it can't read (\(error)); closed")
            close()
            return
        }
        for frame in frames {
            let payload: [UInt8]?
            if lock.withLock({ incoming == nil }) {
                // The first frame says which setup this is: the keys that open it.
                guard let (keys, opened) = server?.identify(frame) else {
                    server?.log("! HomeKit data stream: a connection that matches no setup; closed")
                    close()
                    return
                }
                lock.withLock {
                    var cipher = DataStream.Cipher(key: keys.write)
                    _ = cipher.open(header: frame.header, sealed: frame.sealed, tag: frame.tag)   // counts frame 0
                    incoming = cipher
                    outgoing = DataStream.Cipher(key: keys.read)
                }
                payload = opened
            } else {
                payload = lock.withLock { incoming?.open(header: frame.header, sealed: frame.sealed, tag: frame.tag) }
            }
            guard let payload, let message = try? DataStream.Message(payload: payload) else {
                server?.log("! HomeKit data stream: a frame that doesn't open or read; closed")
                close()
                return
            }
            server?.received(message, on: self)
        }
    }

    public func send(_ message: DataStream.Message) {
        let frame = lock.withLock { outgoing?.seal(message.payload) }
        guard let frame else { return }
        connection.send(content: Data(frame), completion: .contentProcessed { _ in })
    }

    public func close() {
        let first = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        connection.cancel()
        server?.closed(self)
        for handler in lock.withLock({ closeHandlers }) { handler() }
    }
}
