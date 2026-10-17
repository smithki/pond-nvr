// The service's camera controls for the app (and `pond`): PTZ, night mode and talking back go through the
// service, which has the passwords and keeps each camera's connections (CameraSessions), so a camera that
// allows only a few logins isn't logged into again by each window.
//
// Over a local socket next to the settings file, readable only by this user:
//   request:  one line of JSON, a Request
//   reply:    one line of JSON, a Reply
// Requests follow one another on a connection. "talk" turns it into sound for the camera's speaker: after its
// reply, frames of a 4-byte length (big-endian) and that many bytes of 16-bit little-endian mono samples at
// the reply's sample rate; a frame of length 0, or hanging up, ends it.
#if canImport(Darwin)
import Darwin
import Foundation
import Ingest
import NVRCore

public enum ControlSocket {
    public static func path(nextTo configPath: String) -> String {
        (NSString(string: configPath).deletingLastPathComponent as NSString).appendingPathComponent("controls.sock")
    }

    public struct Request: Codable, Sendable {
        public var camera: String
        /// "controls", "ptz.move", "ptz.stop", "ptz.presets", "ptz.goto", "ptz.save", "ptz.remove",
        /// "items.values" (every item's), "item.get", "item.set", "item.do" (the item named), "talk".
        public var action: String
        public var velocity: PTZVelocity?
        public var preset: String?
        public var name: String?
        public var item: String?
        public var value: Config.Controls.Value?

        public init(camera: String, action: String, velocity: PTZVelocity? = nil, preset: String? = nil,
                    name: String? = nil, item: String? = nil, value: Config.Controls.Value? = nil) {
            self.camera = camera
            self.action = action
            self.velocity = velocity
            self.preset = preset
            self.name = name
            self.item = item
            self.value = value
        }
    }

    public struct Reply: Codable, Sendable {
        public var error: ControlFailure?
        public var controls: Config.Controls?
        public var presets: [PTZPreset]?
        public var preset: PTZPreset?
        public var value: Config.Controls.Value?
        public var values: [String: Config.Controls.Value]?
        public var sampleRate: Double?

        public init(error: ControlFailure? = nil, controls: Config.Controls? = nil, presets: [PTZPreset]? = nil,
                    preset: PTZPreset? = nil, value: Config.Controls.Value? = nil,
                    values: [String: Config.Controls.Value]? = nil, sampleRate: Double? = nil) {
            self.error = error
            self.controls = controls
            self.presets = presets
            self.preset = preset
            self.value = value
            self.values = values
            self.sampleRate = sampleRate
        }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return address
    }

    /// A line of JSON.
    static func line<T: Encodable>(_ value: T) -> [UInt8] {
        ((try? JSONEncoder().encode(value)).map { [UInt8]($0) } ?? [UInt8]("{}".utf8)) + [0x0A]
    }
}

extension ControlFailure: Codable {
    enum Kind: String, Codable { case notSupported, unreachable, loginRefused, busy, failed }
    struct Coded: Codable {
        var kind: Kind
        var detail: String?
    }

    public init(from decoder: Decoder) throws {
        let coded = try Coded(from: decoder)
        switch coded.kind {
        case .notSupported: self = .notSupported
        case .unreachable: self = .unreachable
        case .loginRefused: self = .loginRefused
        case .busy: self = .busy
        case .failed: self = .failed(coded.detail ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .notSupported: try Coded(kind: .notSupported).encode(to: encoder)
        case .unreachable: try Coded(kind: .unreachable).encode(to: encoder)
        case .loginRefused: try Coded(kind: .loginRefused).encode(to: encoder)
        case .busy: try Coded(kind: .busy).encode(to: encoder)
        case let .failed(why): try Coded(kind: .failed, detail: why).encode(to: encoder)
        }
    }
}

/// A connection's bytes, read a line or a frame at a time.
struct SocketReader {
    let transport: SocketTransport
    var buffer: [UInt8] = []

    mutating func line(timeout: Double) throws(TransportError) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeFirst(end + 1)
                return line
            }
            guard buffer.count < 1 << 20 else { throw .closed }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            buffer += try transport.receive(timeout: left)
        }
    }

    mutating func frame(timeout: Double) throws(TransportError) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if buffer.count >= 4 {
                let length = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
                guard length < 1 << 20 else { throw .closed }
                if buffer.count >= 4 + length {
                    let frame = Array(buffer[4 ..< 4 + length])
                    buffer.removeFirst(4 + length)
                    return frame
                }
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            buffer += try transport.receive(timeout: left)
        }
    }
}

/// In the service: does what the app asks of its cameras.
public final class ControlServer: @unchecked Sendable {
    /// A camera's way in, if it's one of the service's.
    public typealias Lookup = @Sendable (_ camera: String) -> (access: CameraAccess, device: Config.Device?)?

    let path: String
    let lookup: Lookup
    let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var listener: Int32 = -1
    /// Each camera's controls, worked out once and kept.
    private var controls: [String: CameraControls] = [:]

    public init(path: String, lookup: @escaping Lookup, log: @escaping @Sendable (String) -> Void) {
        self.path = path
        self.lookup = lookup
        self.log = log
    }

    @discardableResult
    public func start() -> Bool {
        guard var address = ControlSocket.address(path) else {
            log("! controls: the path is too long for a socket: \(path)")
            return false
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            log("! controls: can't listen at \(path): \(String(cString: strerror(errno)))")
            close(fd)
            return false
        }
        lock.withLock { listener = fd }
        let thread = Thread { [self] in accept(on: fd) }
        thread.name = "controls"
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
                return
            }
            let thread = Thread { [self] in serve(SocketTransport(connected: client)) }
            thread.name = "controls client"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    func cameraControls(_ id: String) -> CameraControls? {
        lock.withLock {
            if let known = controls[id] { return known }
            guard let (access, device) = lookup(id) else { return nil }
            let made = CameraControls(access: access, device: device)
            controls[id] = made
            return made
        }
    }

    private func serve(_ client: SocketTransport) {
        defer { client.close() }
        var reader = SocketReader(transport: client)
        // Requests until the app hangs up (or it's quiet for a long while).
        while let text = try? reader.line(timeout: 300) {
            guard let request = try? JSONDecoder().decode(ControlSocket.Request.self, from: Data(text.utf8)) else { return }
            guard let controls = cameraControls(request.camera) else {
                _ = try? client.send(ControlSocket.line(ControlSocket.Reply(error: .failed("no camera \(request.camera)"))))
                continue
            }
            if request.action == "talk" {
                talk(controls, camera: request.camera, client: client, reader: &reader)
                return
            }
            let reply = blocking { await Self.perform(request, on: controls) }
            if let error = reply.error, error != .notSupported { log("! controls: \(request.camera) \(request.action): \(error)") }
            guard (try? client.send(ControlSocket.line(reply))) != nil else { return }
        }
    }

    static func perform(_ request: ControlSocket.Request, on controls: CameraControls) async -> ControlSocket.Reply {
        do throws(ControlFailure) {
            switch request.action {
            case "controls":
                return ControlSocket.Reply(controls: await controls.controls())
            case "ptz.move":
                let velocity = request.velocity ?? PTZVelocity()
                try await controls.withPTZ { c throws(ControlFailure) in try await c.move(velocity) }
            case "ptz.stop":
                try await controls.withPTZ { c throws(ControlFailure) in try await c.stop() }
            case "ptz.presets":
                return ControlSocket.Reply(presets: try await controls.withPTZ { c throws(ControlFailure) in try await c.presets() })
            case "ptz.goto":
                guard let preset = request.preset else { throw .failed("which preset?") }
                try await controls.withPTZ { c throws(ControlFailure) in try await c.goTo(preset) }
            case "ptz.save":
                let (name, replacing) = (request.name ?? "Position", request.preset)
                return ControlSocket.Reply(preset: try await controls.withPTZ { c throws(ControlFailure) in
                    try await c.savePreset(name, replacing: replacing)
                })
            case "ptz.remove":
                guard let preset = request.preset else { throw .failed("which preset?") }
                try await controls.withPTZ { c throws(ControlFailure) in try await c.removePreset(preset) }
            case "items.values":
                // Each that can be read; one that fails is left out (it shows as unknown).
                var values: [String: Config.Controls.Value] = [:]
                for control in await controls.items() {
                    if let value = try? await control.value() { values[control.item.id] = value }
                }
                return ControlSocket.Reply(values: values)
            case "item.get":
                guard let id = request.item else { throw .failed("which item?") }
                return ControlSocket.Reply(value: try await controls.withItem(id) { c throws(ControlFailure) in try await c.value() })
            case "item.set":
                guard let id = request.item, let value = request.value else { throw .failed("which item, and what value?") }
                try await controls.withItem(id) { c throws(ControlFailure) in try await c.set(value) }
            case "item.do":
                guard let id = request.item else { throw .failed("which item?") }
                try await controls.withItem(id) { c throws(ControlFailure) in try await c.perform() }
            default:
                throw .failed("no such action: \(request.action)")
            }
            return ControlSocket.Reply()
        } catch {
            return ControlSocket.Reply(error: error)
        }
    }

    /// Sound from the app to the camera's speaker, until a frame of length 0 or the app hangs up.
    private func talk(_ controls: CameraControls, camera: String, client: SocketTransport, reader: inout SocketReader) {
        let opened: Result<TalkSession, ControlFailure> = blocking {
            do throws(ControlFailure) {
                return .success(try await controls.withTalk { c throws(ControlFailure) in try await c.open() })
            } catch {
                return .failure(error)
            }
        }
        let session: TalkSession
        switch opened {
        case let .success(s): session = s
        case let .failure(error):
            log("! controls: \(camera) talk: \(error)")
            _ = try? client.send(ControlSocket.line(ControlSocket.Reply(error: error)))
            return
        }
        defer { session.close() }
        log("· \(camera): talking to its speaker")
        guard (try? client.send(ControlSocket.line(ControlSocket.Reply(sampleRate: session.sampleRate)))) != nil else { return }
        while true {
            guard let frame = try? reader.frame(timeout: 30), !frame.isEmpty else { return }
            let samples = stride(from: 0, to: frame.count - 1, by: 2).map { Int16(bitPattern: UInt16(frame[$0]) | UInt16(frame[$0 + 1]) << 8) }
            do throws(ControlFailure) { try session.send(samples) } catch {
                log("! controls: \(camera) talk: \(error)")
                return
            }
        }
    }
}

/// Runs async work from a plain thread and waits for it.
func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    Task.detached {
        result = await work()
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

/// In the app (and `pond`): asks the service.
public struct ControlClient: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    /// Whether the service is there to ask.
    public var isAvailable: Bool {
        guard let transport = Self.connect(path) else { return false }
        transport.close()
        return true
    }

    /// One request, its reply; `.unreachable` if the service isn't running.
    public func ask(_ request: ControlSocket.Request, timeout: Double = 15) async -> ControlSocket.Reply {
        let path = self.path
        return await Task.detached {
            guard let transport = Self.connect(path) else { return ControlSocket.Reply(error: .unreachable) }
            defer { transport.close() }
            guard (try? transport.send(ControlSocket.line(request))) != nil else { return ControlSocket.Reply(error: .unreachable) }
            var reader = SocketReader(transport: transport)
            guard let line = try? reader.line(timeout: timeout),
                  let reply = try? JSONDecoder().decode(ControlSocket.Reply.self, from: Data(line.utf8)) else {
                return ControlSocket.Reply(error: .unreachable)
            }
            return reply
        }.value
    }

    /// A connection to a camera's speaker through the service.
    public func talk(camera: String) async throws(ControlFailure) -> ControlTalk {
        let path = self.path
        let result: Result<ControlTalk, ControlFailure> = await Task.detached {
            guard let transport = Self.connect(path) else { return .failure(.unreachable) }
            guard (try? transport.send(ControlSocket.line(ControlSocket.Request(camera: camera, action: "talk")))) != nil else {
                transport.close()
                return .failure(.unreachable)
            }
            var reader = SocketReader(transport: transport)
            guard let line = try? reader.line(timeout: 15),
                  let reply = try? JSONDecoder().decode(ControlSocket.Reply.self, from: Data(line.utf8)) else {
                transport.close()
                return .failure(.unreachable)
            }
            if let error = reply.error {
                transport.close()
                return .failure(error)
            }
            return .success(ControlTalk(transport: transport, sampleRate: reply.sampleRate ?? 8000))
        }.value
        return try result.get()
    }

    static func connect(_ path: String) -> SocketTransport? {
        guard var address = ControlSocket.address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return SocketTransport(connected: fd)
    }
}

/// Sound on its way to a camera's speaker through the service.
public final class ControlTalk: @unchecked Sendable {
    let transport: SocketTransport
    public let sampleRate: Double
    private let lock = NSLock()
    private var closed = false

    init(transport: SocketTransport, sampleRate: Double) {
        self.transport = transport
        self.sampleRate = sampleRate
    }

    /// Samples at `sampleRate`.
    public func send(_ samples: [Int16]) throws(ControlFailure) {
        var frame = [UInt8]()
        frame.reserveCapacity(4 + samples.count * 2)
        let length = UInt32(samples.count * 2)
        frame += [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        for s in samples {
            let u = UInt16(bitPattern: s)
            frame += [UInt8(u & 0xFF), UInt8(u >> 8)]
        }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw .unreachable }
        do { try transport.send(frame) } catch { throw .unreachable }
    }

    public func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            _ = try? transport.send([0, 0, 0, 0])
            transport.close()
        }
    }

    deinit { close() }
}
#endif
