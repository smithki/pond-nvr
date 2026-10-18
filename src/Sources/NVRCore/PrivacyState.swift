// Cameras made private in Pond: not recorded, not shown live, not served to HomeKit, until made public again.
// Pond's own (it works for every camera); a camera's provider may also have the camera itself stop, where it
// can. Kept beside the settings (privacy.json) by the service, which applies it at once, without a restart;
// the app and the CLI change it through the service's control socket.
//
// Two things follow from a camera's own privacy mode (where Pond switches it, PrivacySync): made public, such a
// camera takes a while to start its video again (`waking`: its failures to connect meanwhile aren't problems);
// and while it's dark (private on the camera, or waking), what's asked of its settings can't be told to it,
// so it's kept (`pending`) and set once its video flows (`awake`).
import Foundation

public final class PrivacyState: @unchecked Sendable {
    /// The service's: loaded when it starts (`load(nextTo:)`); empty until then, so nothing is private.
    public static let shared = PrivacyState()

    public typealias Observer = @Sendable (_ camera: String, _ isPrivate: Bool) -> Void

    private let lock = NSLock()
    private var path: String?
    private var cameras: Set<String> = []
    /// Private on the camera itself (its own privacy mode, seen by the recorder: it answers but sends nothing).
    /// Apart from Pond's: the recorder keeps checking it, and it ends when the camera sends video again.
    private var onCamera: Set<String> = []
    private var observers: [UUID: Observer] = [:]
    /// Made public with its own privacy mode on: until when it may take to start its video again (ended early by
    /// `awake`).
    private var waking: [String: Date] = [:]
    /// Settings asked for while it couldn't be told, each item's latest: set once it's awake.
    private var pending: [String: [String: Config.Controls.Value]] = [:]
    private var awakeObservers: [UUID: @Sendable (String) -> Void] = [:]
    /// Writes in the order the changes were made.
    private let writing = NSLock()

    public init(path: String? = nil) {
        if let path { load(path: path) }
    }

    /// Next to the settings file.
    public static func path(nextTo configPath: String) -> String {
        (NSString(string: configPath).deletingLastPathComponent as NSString).appendingPathComponent("privacy.json")
    }

    /// Reads what was kept at `path`, and keeps changes there from now on.
    public func load(path: String) {
        let kept = Self.read(path)
        lock.withLock {
            self.path = path
            cameras = kept.private
            onCamera = kept.onCamera
            waking = kept.waking
            pending = kept.pending
        }
    }

    /// Private on the camera itself (see `onCamera`).
    public func isPrivateOnCamera(_ camera: String) -> Bool { lock.withLock { onCamera.contains(camera) } }

    public var privateOnCamera: Set<String> { lock.withLock { onCamera } }

    /// The recorder saw the camera's own privacy mode on or off; kept, and told to the observers (as private or
    /// not) if it changed. Returns whether it did.
    @discardableResult
    public func cameraReports(_ camera: String, privacyMode on: Bool) -> Bool {
        let (changed, observers) = lock.withLock { () -> (Bool, [Observer]) in
            let changed = on ? onCamera.insert(camera).inserted : onCamera.remove(camera) != nil
            return (changed, Array(self.observers.values))
        }
        guard changed else { return false }
        save()
        for observer in observers { observer(camera, on || isPrivate(camera)) }
        return true
    }

    public func isPrivate(_ camera: String) -> Bool { lock.withLock { cameras.contains(camera) } }

    public var privateCameras: Set<String> { lock.withLock { cameras } }

    /// Makes a camera private or not; kept, and told to the observers if it changed. Returns whether it did.
    /// `wakingFor`: made public, its own privacy mode was on, and it may take this long to start its video again.
    @discardableResult
    public func set(_ camera: String, private isPrivate: Bool, wakingFor wake: TimeInterval? = nil) -> Bool {
        let (changed, observers) = lock.withLock { () -> (Bool, [Observer]) in
            let changed = isPrivate ? cameras.insert(camera).inserted : cameras.remove(camera) != nil
            if isPrivate {
                waking[camera] = nil
            } else if changed, let wake, wake > 0 {
                waking[camera] = Date().addingTimeInterval(wake)
            }
            return (changed, Array(self.observers.values))
        }
        guard changed else { return false }
        save()
        // (Still private if the camera's own privacy mode is on.)
        for observer in observers { observer(camera, isPrivate || isPrivateOnCamera(camera)) }
        return true
    }

    // MARK: Waking, and what waits for it

    /// Starting its video again after its own privacy mode turned off (see `set`).
    public func isWaking(_ camera: String) -> Bool { lock.withLock { waking[camera].map { $0 > Date() } ?? false } }

    public var wakingCameras: Set<String> {
        lock.withLock { Set(waking.filter { $0.value > Date() }.keys) }
    }

    /// Its video flows (the recorder has it): no longer waking, and those observing are told (to set what waits).
    public func awake(_ camera: String) {
        let (was, observers) = lock.withLock { () -> (Bool, [@Sendable (String) -> Void]) in
            (waking.removeValue(forKey: camera) != nil, Array(awakeObservers.values))
        }
        if was { save() }
        for observer in observers { observer(camera) }
    }

    /// Told each time a camera's video flows again (`awake`), until `forget`.
    @discardableResult
    public func observeAwake(_ observer: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { awakeObservers[id] = observer }
        return id
    }

    /// A setting to make once the camera can be told (the latest for each item).
    public func queue(_ camera: String, item: String, _ value: Config.Controls.Value) {
        lock.withLock { pending[camera, default: [:]][item] = value }
        save()
    }

    /// What waits to be set on it.
    public func pendingSettings(_ camera: String) -> [String: Config.Controls.Value] { lock.withLock { pending[camera] ?? [:] } }

    public var allPending: [String: [String: Config.Controls.Value]] { lock.withLock { pending } }

    /// What waits, taken to be set (put back with `queue` what can't be yet).
    public func takePending(_ camera: String) -> [String: Config.Controls.Value] {
        let taken = lock.withLock { pending.removeValue(forKey: camera) ?? [:] }
        if !taken.isEmpty { save() }
        return taken
    }

    /// Told of every change from now on, until `forget`.
    @discardableResult
    public func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = observer }
        return id
    }

    public func forget(_ id: UUID) {
        lock.withLock {
            observers[id] = nil
            awakeObservers[id] = nil
        }
    }

    struct File: Codable {
        var `private`: [String]
        var onCamera: [String]?
        var waking: [String: Date]?
        var pending: [String: [String: Config.Controls.Value]]?
    }

    struct Kept {
        var `private`: Set<String> = []
        var onCamera: Set<String> = []
        var waking: [String: Date] = [:]
        var pending: [String: [String: Config.Controls.Value]] = [:]
    }

    static func read(_ path: String) -> Kept {
        guard let data = FileManager.default.contents(atPath: path), let file = try? decoder.decode(File.self, from: data)
        else { return Kept() }
        return Kept(private: Set(file.private), onCamera: Set(file.onCamera ?? []), waking: file.waking ?? [:], pending: file.pending ?? [:])
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// What's kept now, written (if there's a file).
    private func save() {
        writing.withLock {
            let (path, file) = lock.withLock {
                (self.path, File(private: cameras.sorted(), onCamera: onCamera.sorted(),
                                 waking: waking.isEmpty ? nil : waking, pending: pending.isEmpty ? nil : pending))
            }
            guard let path else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(file) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
