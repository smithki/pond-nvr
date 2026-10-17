// Cameras made private in Pond: not recorded, not shown live, not served to HomeKit, until made public again.
// Pond's own (it works for every camera); a camera's provider may also have the camera itself stop, where it
// can. Kept beside the settings (privacy.json) by the service, which applies it at once, without a restart;
// the app and the CLI change it through the service's control socket.
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
        }
    }

    /// Private on the camera itself (see `onCamera`).
    public func isPrivateOnCamera(_ camera: String) -> Bool { lock.withLock { onCamera.contains(camera) } }

    public var privateOnCamera: Set<String> { lock.withLock { onCamera } }

    /// The recorder saw the camera's own privacy mode on or off; kept, and told to the observers (as private or
    /// not) if it changed. Returns whether it did.
    @discardableResult
    public func cameraReports(_ camera: String, privacyMode on: Bool) -> Bool {
        let (changed, observers, path, all, mine) = lock.withLock { () -> (Bool, [Observer], String?, Set<String>, Set<String>) in
            let changed = on ? onCamera.insert(camera).inserted : onCamera.remove(camera) != nil
            return (changed, Array(self.observers.values), self.path, cameras, onCamera)
        }
        guard changed else { return false }
        if let path { Self.write(all, onCamera: mine, to: path) }
        for observer in observers { observer(camera, on || isPrivate(camera)) }
        return true
    }

    public func isPrivate(_ camera: String) -> Bool { lock.withLock { cameras.contains(camera) } }

    public var privateCameras: Set<String> { lock.withLock { cameras } }

    /// Makes a camera private or not; kept, and told to the observers if it changed. Returns whether it did.
    @discardableResult
    public func set(_ camera: String, private isPrivate: Bool) -> Bool {
        let (changed, observers, path, all) = lock.withLock { () -> (Bool, [Observer], String?, Set<String>) in
            let changed = isPrivate ? cameras.insert(camera).inserted : cameras.remove(camera) != nil
            return (changed, Array(self.observers.values), self.path, cameras)
        }
        guard changed else { return false }
        if let path { Self.write(all, onCamera: privateOnCamera, to: path) }
        // (Still private if the camera's own privacy mode is on.)
        for observer in observers { observer(camera, isPrivate || isPrivateOnCamera(camera)) }
        return true
    }

    /// Told of every change from now on, until `forget`.
    @discardableResult
    public func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = observer }
        return id
    }

    public func forget(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }

    struct File: Codable {
        var `private`: [String]
        var onCamera: [String]?
    }

    static func read(_ path: String) -> (private: Set<String>, onCamera: Set<String>) {
        guard let data = FileManager.default.contents(atPath: path), let file = try? JSONDecoder().decode(File.self, from: data)
        else { return ([], []) }
        return (Set(file.private), Set(file.onCamera ?? []))
    }

    static func write(_ cameras: Set<String>, onCamera: Set<String>, to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(private: cameras.sorted(), onCamera: onCamera.sorted())) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
