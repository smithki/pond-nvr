// The service's camera streams for the app. The app's live views read a camera through the background
// service when it runs, so the camera serves one connection per stream however many views, HomeKit viewers
// and the recorder read it (see StreamHub); without the service, the app connects to the camera itself.
//
// Over a local socket next to the settings file, readable only by this user. The app asks for a stream by its
// address, as in the settings; the service answers only for its cameras' streams, with their passwords from
// its own Keychain access, so the app never sends one. Then:
//   request:  one line of JSON, {"url": "rtsp://…"}
//   reply:    a 4-byte length (big-endian), then JSON: the stream's video and audio, or why it can't be read
//   packets:  as read from the camera: the interleaved channel (1 byte; with its top bit set if replayed, from
//             before the view joined), a 4-byte length, the RTP or RTCP bytes; channel 255 ends the stream, with
//             JSON saying why.
#if canImport(Darwin)
import Darwin
import Foundation

public enum StreamRelay {
    /// The stream ended: the camera's error follows.
    static let endChannel: UInt8 = 255
    /// Set on a packet's channel when it is replayed.
    static let replayedBit: UInt8 = 0x80

    /// The socket, next to the settings file.
    public static func path(nextTo configPath: String) -> String {
        (NSString(string: configPath).deletingLastPathComponent as NSString).appendingPathComponent("streams.sock")
    }

    struct Request: Codable {
        var url: String
    }

    struct Reply: Codable {
        var video: SDP.Media?
        var audio: SDP.Media?
        /// The camera could not be read.
        var error: RTSPError?
        /// The service has no camera with this stream (its settings may be older than the app's).
        var unknown: Bool?
    }

    static func frame(_ channel: UInt8, _ data: [UInt8]) -> [UInt8] {
        let n = UInt32(data.count)
        return [channel, UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + data
    }

    static func lengthPrefixed(_ data: [UInt8]) -> [UInt8] {
        let n = UInt32(data.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + data
    }

    /// A local socket address for `path`, or nil if the path is too long for one.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, b) in bytes.enumerated() { buffer[i] = b }
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}

/// Bytes from a transport, taken a piece at a time.
struct ByteReader {
    let transport: RTSPTransport
    private var buffer: [UInt8] = []

    init(transport: RTSPTransport) { self.transport = transport }

    /// Exactly `count` bytes, waiting up to `timeout` seconds for the first of them (nil if none came);
    /// once some have come, the rest follow without a limit of their own beyond `rest` seconds.
    mutating func take(_ count: Int, timeout: Double, rest: Double = 5) throws(TransportError) -> [UInt8]? {
        var deadline = Date().addingTimeInterval(timeout)
        while buffer.count < count {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 {
                if buffer.isEmpty { return nil }
                throw .failed("the stream stopped mid-packet")
            }
            let got = try transport.receive(timeout: left)
            if !got.isEmpty, buffer.isEmpty { deadline = Date().addingTimeInterval(rest) }
            buffer += got
        }
        let out = Array(buffer[0 ..< count])
        buffer.removeFirst(count)
        return out
    }

    /// A line (without its newline), or nil if none came within `timeout`.
    mutating func line(timeout: Double, limit: Int = 4096) throws(TransportError) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[0 ..< i], as: UTF8.self)
                buffer.removeFirst(i + 1)
                return line
            }
            guard buffer.count < limit else { throw .failed("the request is too long") }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            buffer += try transport.receive(timeout: left)
        }
    }
}

/// In the service: answers the app's requests for streams from the shared camera connections.
public final class StreamRelayServer: @unchecked Sendable {
    /// A stream's login, if it is one of the service's cameras'.
    public typealias Lookup = @Sendable (_ url: String) -> (username: String, password: String)?

    let path: String
    let hub: StreamHub
    let lookup: Lookup
    let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var listener: Int32 = -1

    public init(path: String, hub: StreamHub = .shared, lookup: @escaping Lookup, log: @escaping @Sendable (String) -> Void) {
        self.path = path
        self.hub = hub
        self.lookup = lookup
        self.log = log
    }

    /// Listens, on a thread of its own; false (and logged) if the socket can't be made.
    @discardableResult
    public func start() -> Bool {
        guard var address = StreamRelay.address(path) else {
            log("! stream relay: the path is too long for a socket: \(path)")
            return false
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            log("! stream relay: can't listen at \(path): \(String(cString: strerror(errno)))")
            close(fd)
            return false
        }
        lock.withLock { listener = fd }
        let thread = Thread { [self] in accept(on: fd) }
        thread.name = "stream relay"
        thread.start()
        return true
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            defer { listener = -1 }
            return listener
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
    }

    private func accept(on fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // stopped
            }
            let thread = Thread { [self] in serve(SocketTransport(connected: client)) }
            thread.name = "stream relay client"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func serve(_ client: SocketTransport) {
        defer { client.close() }
        var reader = ByteReader(transport: client)
        guard let line = try? reader.line(timeout: 5),
              let request = try? JSONDecoder().decode(StreamRelay.Request.self, from: Data(line.utf8)) else { return }
        guard let login = lookup(request.url) else {
            send(StreamRelay.Reply(unknown: true), to: client)
            return
        }
        let source: PacketSource
        do throws(RTSPError) {
            source = try hub.open(url: request.url, username: login.username, password: login.password, replay: true)
        } catch {
            send(StreamRelay.Reply(error: error), to: client)
            return
        }
        defer { source.close() }
        guard send(StreamRelay.Reply(video: source.video, audio: source.audio), to: client) else { return }
        while true {
            // The app sends nothing after its request: the socket turns readable only when it hangs up.
            do { _ = try client.receive(timeout: 0) } catch { return }
            do throws(RTSPError) {
                guard let packet = try source.next(timeout: 0.5) else { continue }
                let channel = packet.replayed ? packet.channel | StreamRelay.replayedBit : packet.channel
                do { try client.send(StreamRelay.frame(channel, packet.data)) } catch { return }
            } catch {
                let why = (try? JSONEncoder().encode(error)).map { [UInt8]($0) } ?? []
                try? client.send(StreamRelay.frame(StreamRelay.endChannel, why))
                return
            }
        }
    }

    @discardableResult
    private func send(_ reply: StreamRelay.Reply, to client: SocketTransport) -> Bool {
        guard let json = try? JSONEncoder().encode(reply) else { return false }
        return (try? client.send(StreamRelay.lengthPrefixed([UInt8](json)))) != nil
    }
}

/// In the service: holds a stream open with nobody watching, so the next live view or snapshot starts from its
/// latest keyframe (StreamHub's replay) instead of waiting for the camera to connect and send one. Reads and
/// drops what comes; after a failure, opens it again (with a growing pause) until stopped.
public final class StreamKeeper: @unchecked Sendable {
    let url: String
    let username: String
    let password: String
    let hub: StreamHub
    private let lock = NSLock()
    private var stopped = false

    public init(url: String, username: String, password: String, hub: StreamHub = .shared) {
        self.url = url
        self.username = username
        self.password = password
        self.hub = hub
    }

    var isStopped: Bool { lock.withLock { stopped } }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "keep \(url)"
        thread.qualityOfService = .utility
        thread.start()
    }

    public func stop() { lock.withLock { stopped = true } }

    private func run() {
        var pause = 2.0
        while !isStopped {
            if let source = try? hub.open(url: url, username: username, password: password) {
                pause = 2
                while !isStopped {
                    do { _ = try source.next(timeout: 0.5) } catch { break }
                }
                source.close()
            }
            let until = Date().addingTimeInterval(pause)
            while !isStopped, Date() < until { Thread.sleep(forTimeInterval: 0.2) }
            pause = min(pause * 2, 60)
        }
    }
}

/// In the app: a stream read through the service, like a camera session of its own.
public final class RelaySession: PacketSource {
    public let video: SDP.Media
    public let audio: SDP.Media?
    private let transport: SocketTransport
    private var reader: ByteReader

    /// The stream at `url` through the service at `path`; nil if the service isn't there or has no such
    /// stream (then the app connects to the camera itself). Throws what the camera said if it can't be read.
    public static func open(path: String, url: String) throws(RTSPError) -> RelaySession? {
        if case let .opened(session) = try connect(path: path, url: url) { return session }
        return nil
    }

    /// What asking the service for a stream came to.
    public enum Opening {
        case opened(RelaySession)
        /// The service isn't running (or answered nothing).
        case noService
        /// It is, but has no camera with this stream (its settings are older than the app's).
        case unknownStream
    }

    public static func connect(path: String, url: String) throws(RTSPError) -> Opening {
        guard var address = StreamRelay.address(path) else { return .noService }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .noService }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return .noService
        }
        let transport = SocketTransport(connected: fd)
        var reader = ByteReader(transport: transport)
        // The service connects to the camera before it answers: as long as a camera may take.
        guard let request = try? JSONEncoder().encode(StreamRelay.Request(url: url)),
              (try? transport.send([UInt8](request) + [0x0A])) != nil,
              let length = try? reader.take(4, timeout: 20),
              let body = (try? reader.take(Self.length(length), timeout: 5)) ?? nil,
              let reply = try? JSONDecoder().decode(StreamRelay.Reply.self, from: Data(body)) else {
            transport.close()
            return .noService
        }
        if let error = reply.error {
            transport.close()
            throw error
        }
        guard reply.unknown != true, let video = reply.video else {
            transport.close()
            return .unknownStream
        }
        return .opened(RelaySession(video: video, audio: reply.audio, transport: transport, reader: reader))
    }

    private init(video: SDP.Media, audio: SDP.Media?, transport: SocketTransport, reader: ByteReader) {
        self.video = video
        self.audio = audio
        self.transport = transport
        self.reader = reader
    }

    static func length(_ bytes: [UInt8]?) -> Int {
        guard let b = bytes, b.count == 4 else { return 0 }
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    public func next(timeout: Double) throws(RTSPError) -> InterleavedPacket? {
        let head: [UInt8], body: [UInt8]
        do throws(TransportError) {
            guard let h = try reader.take(5, timeout: timeout) else { return nil }
            head = h
            body = try reader.take(Self.length(Array(h[1 ..< 5])), timeout: 5) ?? []
        } catch {
            throw .transport(error)
        }
        if head[0] == StreamRelay.endChannel {
            throw (try? JSONDecoder().decode(RTSPError.self, from: Data(body))) ?? .transport(.closed)
        }
        let replayed = head[0] & StreamRelay.replayedBit != 0
        return InterleavedPacket(channel: head[0] & ~StreamRelay.replayedBit, data: body, replayed: replayed)
    }

    public func close() {
        transport.close()
    }
}
#endif
