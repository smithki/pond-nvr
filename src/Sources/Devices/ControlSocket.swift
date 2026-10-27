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
import Understanding

public enum ControlSocket {
    public static func path(nextTo configPath: String) -> String {
        (NSString(string: configPath).deletingLastPathComponent as NSString).appendingPathComponent("controls.sock")
    }

    public struct Request: Codable, Sendable {
        public var camera: String
        /// "controls", "ptz.move", "ptz.stop", "ptz.presets", "ptz.goto", "ptz.save", "ptz.remove",
        /// "items.values" (every item's), "item.get", "item.set", "item.do" (the item named), "talk";
        /// "privacy.list" (the private cameras; `camera` unused) and "privacy.set" (`value` on or off);
        /// "search" (events that answer `question`; `camera` unused);
        /// "remote.status" (whether it's on and reachable, who's paired and connected), "remote.relay-secret" (`code`),
        /// "remote.pair" (a new pairing code), "remote.devices", "remote.unpair" (`device`), "remote.join" (`code`),
        /// "remote.connect" (`device`: a path found to it, and how), "remote.watch" (`device`'s `camera` for `seconds`,
        /// its main stream if `main`, kept at `file`); asked of `device` over a session: "remote.cameras",
        /// "remote.events" (the last `seconds`' events, `camera`'s or all), "remote.search" (`question`),
        /// "remote.picture" and "remote.clip" (`event`'s, kept at `file`).
        public var action: String
        public var velocity: PTZVelocity?
        public var preset: String?
        public var name: String?
        public var item: String?
        public var value: Config.Controls.Value?
        /// "search": the question; how it was read already (a part taken off it: not read again) and whether by the
        /// Mac's model; or read by the plain rules only (`plain`).
        public var question: String?
        public var reading: EventQuery?
        public var byModel: Bool?
        public var plain: Bool?
        /// "remote.unpair": the device's id; "remote.join": another Pond's pairing code; "remote.relay-secret": the
        /// relay's secret (empty: removed).
        public var device: String?
        public var code: String?
        public var seconds: Double?
        public var main: Bool?
        public var file: String?
        /// "remote.watch": re-encoded to this bitrate (kbit/s), at most this size ("WxH"); nil: as the camera sends it.
        public var kbps: Int?
        public var size: String?
        /// "remote.picture", "remote.clip": the event's id.
        public var event: String?

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
        /// The cameras made private in Pond.
        public var privateCameras: [String]?
        /// Those starting their video again after their own privacy mode (with "privacy.set").
        public var wakingCameras: [String]?
        /// The setting ("item.set") waits until the camera can be told: it's dark (its own privacy mode) or waking.
        public var queued: Bool?
        /// Turned down because the camera is private or waking (`error` says which): its state, not a failure.
        public var asleep: Bool?
        /// "reload": what changed, in words; and whether the service must be restarted for it instead.
        public var reloaded: String?
        public var restartNeeded: Bool?
        /// "search": the question answered.
        public var search: SearchResult?
        /// "remote.pair": the code (as text), and until when it's good; "remote.devices": those paired;
        /// "remote.join": the Pond paired with.
        public var pairing: String?
        public var pairingExpires: Date?
        public var devices: [RemoteDevice]?
        public var paired: RemoteDevice?
        /// "remote.connect": how it went, in words (no addresses).
        public var connection: String?
        /// "remote.cameras", "remote.events", "remote.search": the other Pond's answer, as JSON (Remote's RemoteAPI).
        public var body: Data?
        /// "remote.status": remote access as it is now.
        public var remote: RemoteStatus?
        /// "remote.ponds": the other Ponds paired with this one, and their cameras, for the app to show beside its own.
        public var ponds: [RemotePond]?

        public init(error: ControlFailure? = nil, controls: Config.Controls? = nil, presets: [PTZPreset]? = nil,
                    preset: PTZPreset? = nil, value: Config.Controls.Value? = nil,
                    values: [String: Config.Controls.Value]? = nil, sampleRate: Double? = nil, privateCameras: [String]? = nil,
                    wakingCameras: [String]? = nil, queued: Bool? = nil, asleep: Bool? = nil) {
            self.privateCameras = privateCameras
            self.asleep = asleep
            self.wakingCameras = wakingCameras
            self.queued = queued
            self.error = error
            self.controls = controls
            self.presets = presets
            self.preset = preset
            self.value = value
            self.values = values
            self.sampleRate = sampleRate
        }
    }

    /// Another Pond, for the app: its cameras (nil, with why, if it couldn't be reached), each with its live streams'
    /// addresses (through this Mac's service) and its id here (`camera@pond`: its controls asked of it through here).
    public struct RemotePond: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var cameras: [Camera]?
        public var problem: String?

        public struct Camera: Codable, Equatable, Sendable {
            public var id: String
            public var name: String
            public var doorbell: Bool
            public var isPrivate: Bool
            public var waking: Bool
            public var model: String?
            public var main: String
            public var sub: String
            public var controls: Config.Controls?

            public init(id: String, name: String, doorbell: Bool, isPrivate: Bool, waking: Bool, model: String?, main: String, sub: String,
                        controls: Config.Controls? = nil) {
                self.controls = controls
                self.id = id
                self.name = name
                self.doorbell = doorbell
                self.isPrivate = isPrivate
                self.waking = waking
                self.model = model
                self.main = main
                self.sub = sub
            }
        }

        public init(id: String, name: String, cameras: [Camera]?, problem: String?) {
            self.id = id
            self.name = name
            self.cameras = cameras
            self.problem = problem
        }

        /// A camera's id here, and back.
        public static func cameraID(_ camera: String, pond: String) -> String { "\(camera)@\(pond)" }
        public static func split(_ id: String) -> (camera: String, pond: String)? {
            guard let at = id.lastIndex(of: "@") else { return nil }
            return (String(id[..<at]), String(id[id.index(after: at)...]))
        }
    }

    /// Remote access in the service, for Settings: whether it's on and reachable, those paired, those connected.
    public struct RemoteStatus: Codable, Equatable, Sendable {
        public var on: Bool
        /// Connected to the signaling service (so devices can reach this Mac), and its host.
        public var reachable: Bool
        public var signaling: String?
        public var devices: [RemoteDevice]
        /// Those connected now, and how ("IPv6, directly").
        public var connected: [Connection]
        /// Whether a relay's secret is kept (the relay isn't used without one).
        public var relaySecret: Bool
        /// Why it's off or not working, if it's something the settings can fix.
        public var problem: String?

        public struct Connection: Codable, Equatable, Sendable {
            public var device: String
            public var how: String

            public init(device: String, how: String) {
                self.device = device
                self.how = how
            }
        }

        public init(on: Bool, reachable: Bool = false, signaling: String? = nil, devices: [RemoteDevice] = [],
                    connected: [Connection] = [], relaySecret: Bool = false, problem: String? = nil) {
            self.on = on
            self.reachable = reachable
            self.signaling = signaling
            self.devices = devices
            self.connected = connected
            self.relaySecret = relaySecret
            self.problem = problem
        }
    }

    /// A device (or another Pond) paired for remote access.
    public struct RemoteDevice: Codable, Equatable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
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

    /// Which cameras are private (Pond's own privacy, which "privacy.set" changes).
    let privacy: PrivacyState
    /// Whose own privacy mode is on (they're dark), and how long they take to wake.
    let sync: CameraPrivacySync?
    /// Settings that waited, being set now (one taken off as it's set, or as it's set anew directly).
    private var setting: [String: [String: Config.Controls.Value]] = [:]
    /// Tries at setting what waited, for each camera, since it last all went.
    private var settingTries: [String: Int] = [:]
    private var awakeObserver: UUID?
    /// Each camera's items as last known (read, or set), so a setting that's already so doesn't wait to be set,
    /// and a camera that can't be asked shows them still. Kept beside the socket (camera-values.json), so a
    /// restart while a camera is private doesn't forget them.
    private var known: [String: [String: Config.Controls.Value]] = [:]
    var knownPath: String { (NSString(string: path).deletingLastPathComponent as NSString).appendingPathComponent("camera-values.json") }

    /// After its video is back, how long a camera is left to settle before what waited is set; and between each.
    static let settleTime: Duration = .seconds(3)
    static let spacing: Duration = .milliseconds(600)
    /// What it couldn't take yet is tried again this much later, this many times, until its video next returns.
    static let retryTime: Duration = .seconds(30)
    static let tries = 3

    public init(path: String, privacy: PrivacyState = .shared, sync: CameraPrivacySync? = nil, lookup: @escaping Lookup,
                log: @escaping @Sendable (String) -> Void) {
        self.path = path
        self.privacy = privacy
        self.sync = sync
        self.lookup = lookup
        self.log = log
        if let data = FileManager.default.contents(atPath: knownPath),
           let kept = try? JSONDecoder().decode([String: [String: Config.Controls.Value]].self, from: data) {
            known = kept
        }
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
        // A camera's video back (the recorder has it): what waited for it is set.
        awakeObserver = privacy.observeAwake { [weak self] camera in self?.setWhatWaited(camera, fresh: true) }
        let thread = Thread { [self] in accept(on: fd) }
        thread.name = "controls"
        thread.start()
        return true
    }

    public func stop() {
        if let awakeObserver { privacy.forget(awakeObserver) }
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

    /// The settings read again (set by the service): what changed, whether it needs a restart instead, or why
    /// it failed.
    public var reload: (@Sendable () -> (summary: String, restart: Bool, failed: Bool))?

    /// Search (set by the service): a question answered, as the request asks.
    public var search: (@Sendable (ControlSocket.Request) async -> SearchResult)?

    /// Remote access (set by the service, when it's on): the "remote." actions.
    public var remote: (@Sendable (ControlSocket.Request) async -> ControlSocket.Reply)?
    /// Another Pond's camera's request (its id `camera@pond`), asked of that Pond (set by the service).
    public var otherPond: (@Sendable (ControlSocket.Request) async -> ControlSocket.Reply)?

    /// The camera restarted, whichever way it can be: over its make's own protocol (a Reolink's, which answers
    /// when its video and web servers don't), else its Restart control (ONVIF's, every ONVIF camera has it). How it
    /// was done, or nil if it couldn't be.
    public func restart(_ id: String) async -> String? {
        if let done = sync?.restart(id) {
            if done { return "over Reolink\u{2019}s own protocol" }
        }
        guard let controls = cameraControls(id) else { return nil }
        do throws(ControlFailure) {
            try await controls.withItem("restart") { item throws(ControlFailure) in try await item.perform() }
            return "with its Restart control"
        } catch {
            return nil
        }
    }

    /// A camera's controls worked out again when next asked (it changed, or was removed).
    public func forget(_ id: String) { _ = lock.withLock { controls.removeValue(forKey: id) } }

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
            // Talking back takes the connection over (a camera that can't now is answered as any request is).
            if request.action == "talk", let controls = cameraControls(request.camera), whileAsleep(request) == nil {
                talk(controls, camera: request.camera, client: client, reader: &reader)
                return
            }
            let reply = blocking { await self.answer(request) }
            guard (try? client.send(ControlSocket.line(reply))) != nil else { return }
        }
    }

    /// A request answered: any but talking back, which needs a connection of its own (from the app's socket, or
    /// a remote device's session).
    public func answer(_ request: ControlSocket.Request) async -> ControlSocket.Reply {
        switch request.action {
        case "reload":
            var reply = ControlSocket.Reply()
            if let (summary, restart, failed) = reload?() {
                if failed { reply.error = .failed(summary) } else { reply.reloaded = summary; reply.restartNeeded = restart }
            } else {
                reply.error = .notSupported
            }
            return reply
        case "search":
            var reply = ControlSocket.Reply()
            if let search { reply.search = await search(request) } else { reply.error = .notSupported }
            return reply
        case let action where action.hasPrefix("remote."):
            guard let remote else {
                return ControlSocket.Reply(error: .failed("remote access is off (remote.enabled and remote.signaling in the settings)"))
            }
            return await remote(request)
        case "privacy.list":
            return ControlSocket.Reply(privateCameras: privacy.privateCameras.sorted())
        case _ where ControlSocket.RemotePond.split(request.camera) != nil:
            // Another Pond's camera: asked of it.
            guard let forward = otherPond else { return ControlSocket.Reply(error: .failed("remote access is off")) }
            return await forward(request)
        case "talk" where cameraControls(request.camera) != nil && whileAsleep(request) == nil:
            return ControlSocket.Reply(error: .notSupported)
        default:
            break
        }
        guard let controls = cameraControls(request.camera) else { return ControlSocket.Reply(error: .failed("no camera \(request.camera)")) }
        // Private, dark or waking: what it can't do now is turned down, and its settings wait.
        if let reply = whileAsleep(request) { return reply }
        if request.action == "item.set", let item = request.item {
            // Set anew: not to what it waited to be set to.
            _ = lock.withLock { setting[request.camera]?.removeValue(forKey: item) }
        }
        let reply = request.action == "privacy.set" ? setPrivacy(request, on: controls) : await Self.perform(request, on: controls)
        remember(request, reply)
        if let error = reply.error, error != .notSupported { log("! controls: \(request.camera) \(request.action): \(error)") }
        // For the doctor: what it asked worked or not (a camera that can't, isn't failing).
        if request.action != "controls", request.action != "items.values", reply.error != .notSupported {
            HealthLog.shared.control(request.camera, ok: reply.error == nil, action: request.action, detail: reply.error?.description)
        }
        return reply
    }

    /// What can't be done to a camera now: while private, using it (moving it, talking through it, its actions;
    /// what it shows can't be seen); while dark (its own privacy mode on) or waking, reaching it at all, so its
    /// settings wait to be set (PrivacyState's pending) and are read as they'll be. Nil: ask it.
    func whileAsleep(_ request: ControlSocket.Request) -> ControlSocket.Reply? {
        let camera = request.camera
        let waking = privacy.isWaking(camera)
        let unreachable = waking || (privacy.isPrivate(camera) && sync?.isDark(camera) == true)
        let why = ControlFailure.failed(waking ? "it\u{2019}s still waking up from privacy mode" : "it\u{2019}s private")
        let refused = ControlSocket.Reply(error: why, asleep: true)
        switch request.action {
        case "ptz.move", "ptz.goto", "ptz.save", "ptz.remove", "item.do", "talk":
            return privacy.isPrivate(camera) || waking ? refused : nil
        case "ptz.stop":
            return unreachable ? ControlSocket.Reply() : nil
        case "ptz.presets", "controls":
            return unreachable ? refused : nil
        case "item.set":
            guard unreachable, let item = request.item, let value = request.value else { return nil }
            // Already so: nothing to set (and what waited for it, set back, no longer waits).
            if lock.withLock({ known[camera]?[item] }) == value {
                privacy.unqueue(camera, item: item)
                return ControlSocket.Reply()
            }
            privacy.queue(camera, item: item, value)
            log("· \(camera): \(item) to be set once it\u{2019}s back from privacy mode")
            return ControlSocket.Reply(queued: true)
        case "items.values":
            // As last known, with what waits to be set over it.
            let values = lock.withLock { known[camera] ?? [:] }.merging(privacy.pendingSettings(camera)) { $1 }
            return unreachable ? ControlSocket.Reply(values: values) : nil
        case "item.get":
            guard unreachable else { return nil }
            guard let value = request.item.flatMap({ privacy.pendingSettings(camera)[$0] }) else { return refused }
            return ControlSocket.Reply(value: value)
        default:
            return nil
        }
    }

    /// Its items' values, as the camera answered or took them.
    func remember(_ request: ControlSocket.Request, _ reply: ControlSocket.Reply) {
        guard reply.error == nil else { return }
        var values: [String: Config.Controls.Value] = [:]
        switch request.action {
        case "items.values": values = reply.values ?? [:]
        case "item.get": if let item = request.item, let value = reply.value { values[item] = value }
        case "item.set": if let item = request.item, let value = request.value { values[item] = value }
        default: return
        }
        remember(request.camera, values)
    }

    private func remember(_ camera: String, _ values: [String: Config.Controls.Value]) {
        let changed = lock.withLock { () -> [String: [String: Config.Controls.Value]]? in
            let before = known[camera]
            known[camera, default: [:]].merge(values) { $1 }
            return known[camera] == before ? nil : known
        }
        guard let changed else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(changed).write(to: URL(fileURLWithPath: knownPath), options: .atomic)
    }

    /// What waited for the camera, set now it can be told: after it has settled, one at a time and spaced, so a
    /// camera that has just started its video isn't flooded. What it can't take yet (no answer, too many logins)
    /// waits, and is tried again a little later, a few times; what it refuses is let go.
    func setWhatWaited(_ camera: String, fresh: Bool) {
        let begin = lock.withLock { () -> Bool in
            if fresh { settingTries[camera] = 0 }
            // Already under way (it takes up what's queued meanwhile too).
            guard setting[camera] == nil else { return false }
            setting[camera] = [:]
            return true
        }
        guard begin else { return }
        Task.detached { [self] in
            try? await Task.sleep(for: Self.settleTime)
            await setWaiting(camera)
            let again = lock.withLock { () -> Bool in
                setting[camera] = nil
                settingTries[camera, default: 0] += 1
                return settingTries[camera, default: 0] < Self.tries
            }
            if again, !privacy.pendingSettings(camera).isEmpty {
                try? await Task.sleep(for: Self.retryTime)
                setWhatWaited(camera, fresh: false)
            }
        }
    }

    private func setWaiting(_ camera: String) async {
        let asleep = { [self] in privacy.isWaking(camera) || (privacy.isPrivate(camera) && sync?.isDark(camera) == true) }
        guard !asleep(), let controls = cameraControls(camera) else { return }
        let waiting = privacy.takePending(camera)
        guard !waiting.isEmpty else { return }
        lock.withLock { setting[camera] = waiting }
        var first = true
        while let (item, value) = lock.withLock({ () -> (String, Config.Controls.Value)? in
            guard let next = setting[camera]?.keys.sorted().first, let value = setting[camera]?.removeValue(forKey: next) else { return nil }
            return (next, value)
        }) {
            if !first { try? await Task.sleep(for: Self.spacing) }
            first = false
            // Dark again: the rest wait for the next time.
            if asleep() {
                privacy.queue(camera, item: item, value)
                continue
            }
            do throws(ControlFailure) {
                try await controls.withItem(item) { c throws(ControlFailure) in try await c.set(value) }
                remember(camera, [item: value])
                log("· \(camera): \(item) set (it waited for privacy mode to end)")
                HealthLog.shared.control(camera, ok: true, action: "item.set", detail: nil)
            } catch .unreachable, .busy {
                // Unless set anew meanwhile.
                if privacy.pendingSettings(camera)[item] == nil { privacy.queue(camera, item: item, value) }
            } catch {
                log("! \(camera): \(item), which waited for privacy mode to end: \(error)")
                HealthLog.shared.control(camera, ok: false, action: "item.set", detail: error.description)
            }
        }
    }

    /// Pond's privacy for the camera, at once (the service stops recording and showing it); then the camera's
    /// own privacy mode where its provider can switch it, without waiting for it. Made public while dark, the
    /// camera is waking for a while (its make's time).
    private func setPrivacy(_ request: ControlSocket.Request, on controls: CameraControls) -> ControlSocket.Reply {
        guard case let .on(on)? = request.value else { return ControlSocket.Reply(error: .failed("on or off?")) }
        if privacy.set(request.camera, private: on, wakingFor: on ? nil : sync?.wakeTime(request.camera)) {
            log("· \(request.camera): \(on ? "private" : "no longer private")")
            HealthLog.shared.record(request.camera, on ? .madePrivate : .madePublic)
        }
        let camera = request.camera, log = self.log
        Task {
            do throws(ControlFailure) {
                try await controls.withPrivacy { c throws(ControlFailure) in try await c.set(on) }
                log("· \(camera): the camera's own privacy mode \(on ? "on" : "off")")
                // It has Pond's change (unless changed again meanwhile).
                if privacy.isPrivate(camera) == on { privacy.told(camera) }
            } catch .notSupported {
            } catch {
                log("! \(camera): the camera's own privacy mode: \(error)")
            }
        }
        return ControlSocket.Reply(privateCameras: privacy.privateCameras.sorted(), wakingCameras: privacy.wakingCameras.sorted())
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
