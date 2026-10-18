// Cameras made private in Pond: not recorded, not shown live, not served to HomeKit, until made public again.
// Pond's own (it works for every camera); a camera's provider may also have the camera itself stop, where it
// can. Kept beside the settings (privacy.json) by the service, which applies it at once, without a restart;
// the app and the CLI change it through the service's control socket.
//
// Two things follow from a camera's own privacy mode (where Pond switches it, PrivacySync): made public, such a
// camera takes a while to start its video again (`waking`: its failures to connect meanwhile aren't problems);
// and while it's dark (private on the camera, or waking), what's asked of its settings can't be told to it,
// so it's kept (`pending`) and set once its video flows (`awake`).
//
// A change made in Pond is `untold` until the camera says it's in that state (where it follows Pond's privacy),
// so on connecting again, a camera that disagrees is put right only if Pond's change never reached it;
// otherwise the camera was changed itself meanwhile (the Reolink app), and that stands.
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
    /// Changed in Pond, and not yet known to have reached the camera.
    private var untold: Set<String> = []
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
            untold = kept.untold
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
    /// `byCamera`: the camera's own change, followed (so it has nothing to be told); else Pond's, untold till then.
    @discardableResult
    public func set(_ camera: String, private isPrivate: Bool, wakingFor wake: TimeInterval? = nil, byCamera: Bool = false) -> Bool {
        let (changed, observers) = lock.withLock { () -> (Bool, [Observer]) in
            let changed = isPrivate ? cameras.insert(camera).inserted : cameras.remove(camera) != nil
            if byCamera {
                untold.remove(camera)
            } else if changed {
                untold.insert(camera)
            }
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

    // MARK: Told

    /// Pond's last change to it hasn't been seen to reach the camera.
    public func isUntold(_ camera: String) -> Bool { lock.withLock { untold.contains(camera) } }

    /// The camera is in Pond's state (it said so, or took the change).
    public func told(_ camera: String) {
        guard lock.withLock({ untold.remove(camera) != nil }) else { return }
        save()
    }

    // MARK: Waking, and what waits for it

    /// Waking from now (its privacy mode turned off for it while Pond was already public), for up to `wake`.
    public func wake(_ camera: String, for wake: TimeInterval) {
        lock.withLock { waking[camera] = Date().addingTimeInterval(wake) }
        save()
    }

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

    /// No longer to be set (set back to what it is).
    public func unqueue(_ camera: String, item: String) {
        let removed = lock.withLock { () -> Bool in
            guard pending[camera]?.removeValue(forKey: item) != nil else { return false }
            if pending[camera]?.isEmpty == true { pending[camera] = nil }
            return true
        }
        if removed { save() }
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
        var untold: [String]?
    }

    struct Kept {
        var `private`: Set<String> = []
        var onCamera: Set<String> = []
        var waking: [String: Date] = [:]
        var pending: [String: [String: Config.Controls.Value]] = [:]
        var untold: Set<String> = []
    }

    static func read(_ path: String) -> Kept {
        guard let data = FileManager.default.contents(atPath: path), let file = try? decoder.decode(File.self, from: data)
        else { return Kept() }
        return Kept(private: Set(file.private), onCamera: Set(file.onCamera ?? []), waking: file.waking ?? [:], pending: file.pending ?? [:],
                    untold: Set(file.untold ?? []))
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
                                 waking: waking.isEmpty ? nil : waking, pending: pending.isEmpty ? nil : pending,
                                 untold: untold.isEmpty ? nil : untold.sorted()))
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
