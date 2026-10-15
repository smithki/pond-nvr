// The app's state: the settings (read and saved through ConfigStore, exactly as `pond` does), the camera
// passwords (Keychain), camera checks, and the login service. Views read it and call its methods; nothing
// else touches the settings file.
import Control
import Devices
import Foundation
import Ingest
import NVRCore
import NVRMac
import Observation
import Recorder

@MainActor
@Observable
final class AppModel {
    let store: ConfigStore
    /// Camera passwords, kept by pond (see PasswordKeeper): the app never reads them.
    let passwords: PasswordKeeper
    let prober: CameraProber
    let service: ServiceControl
    /// The `pond` program inside the app bundle, which the login service runs. Nil outside a bundle.
    let helperPath: String?

    private(set) var config: Config?
    private(set) var loadError: String?
    /// Shown as an alert, then cleared.
    var alert: String?
    /// A camera being dragged to a new order, in the live view or in Settings: one for the app, so the live
    /// view moves its tiles as a reorder whichever window it is dragged in.
    let reorderDrag = ReorderDrag()
    /// What the service's HomeKit is doing (nil when the service is not running). See HomeKitModel.
    var homeKitStatus: HomeKitStatus?
    /// The one camera heard in live view; the others are muted.
    var audibleCamera: String?
    /// Waits for macOS's local network permission before a check; tests replace it so they connect nowhere.
    var localNetworkAccess: (String, UInt16, @escaping @MainActor @Sendable () -> Void) async -> LocalNetworkAccess.Outcome = {
        await LocalNetworkAccess.wait(host: $0, port: $1, waiting: $2)
    }
    /// A camera check is waiting for permission to reach the local network (macOS is asking).
    private(set) var waitingForLocalNetwork = false
    private(set) var serviceState: ServiceControl.State = .notInstalled
    /// Settings were saved while the service ran with the old ones.
    private(set) var needsRestart = false
    /// What the main window shows; `--mode live|timeline|events` on the command line picks the first one.
    var mode: Mode = launchArgument("--mode").flatMap(Mode.init(rawValue:)) ?? .live {
        didSet {
            // Every change of view is remembered for Back, except the moves Back and Forward make.
            guard mode != oldValue, !movingInHistory else { return }
            backHistory.append(oldValue)
            forwardHistory.removeAll()
        }
    }
    /// Views to go back to (most recent last), and forward to after going back.
    private(set) var backHistory: [Mode] = []
    private(set) var forwardHistory: [Mode] = []
    private var movingInHistory = false
    /// The timeline's state, kept while other views are shown, so going back to it finds it as it was.
    let timeline = TimelineModel()

    func goBack() {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(mode)
        movingInHistory = true
        mode = previous
        movingInHistory = false
    }

    func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(mode)
        movingInHistory = true
        mode = next
        movingInHistory = false
    }
    /// The Settings window's tab; `--settings TAB` opens Settings on it at launch.
    var settingsTab: SettingsTab = launchArgument("--settings").flatMap(SettingsTab.init(rawValue:)) ?? .general
    /// A camera whose settings to open (set from the live view), taken by Settings → Cameras.
    var cameraToEdit: String?
    /// A moment to show on the timeline (set from the live view), taken by the timeline when it appears.
    var timelineJump: TimelineJump?
    var addingCamera = false

    init(store: ConfigStore = ConfigStore(path: ProcessInfo.processInfo.environment[Brand.configVariable] ?? ConfigStore.defaultPath),
         passwords: PasswordKeeper? = nil,
         prober: CameraProber = RTSPProber(),
         service: ServiceControl = ServiceControl(launchd: RealLaunchd()),
         helperPath: String? = Bundle.main.path(forAuxiliaryExecutable: Brand.command)) {
        self.store = store
        self.passwords = passwords ?? HelperPasswordKeeper(helper: helperPath, configPath: store.path)
        self.prober = prober
        self.service = service
        self.helperPath = helperPath
        reload()
        refreshService()
    }

    // MARK: - Settings

    func reload() {
        guard store.exists else {
            config = nil
            loadError = nil
            return
        }
        do {
            config = try store.load()
            loadError = nil
        } catch {
            config = nil
            loadError = error.description
        }
    }

    /// The same defaults as `pond init`.
    func createSettings() {
        let config = Config(storage: .init(recordings: "/Volumes/Pond/recordings",
                                           database: Brand.supportFolder + "/pond.sqlite"))
        do {
            try store.save(config)
            reload()
        } catch {
            alert = error.description
        }
    }

    /// Changes and saves the settings. A change that leaves a problem is not saved; the alert says why.
    /// `affectsRecorder: false` for changes the recorder doesn't use (such as the cameras' order), which
    /// then don't ask for a restart.
    @discardableResult
    func update(affectsRecorder: Bool = true, _ change: (inout Config) -> Void) -> Bool {
        guard var next = config else { return false }
        change(&next)
        guard next != config else { return true }
        do {
            try store.save(next)
        } catch let ConfigStore.Error.invalidSettings(problems) {
            alert = problems.joined(separator: "\n")
            return false
        } catch {
            alert = error.description
            return false
        }
        config = next
        if affectsRecorder, case .running = serviceState { needsRestart = true }
        return true
    }

    // MARK: - Storage

    /// Marks a folder for pond and makes it the recordings (or events) folder.
    func chooseFolder(_ url: URL, forEvents: Bool) {
        let path = url.standardizedFileURL.path
        do {
            try StorageLocation.prepare(path)
        } catch {
            alert = error.description
            return
        }
        update { config in
            if forEvents { config.storage.events = path } else { config.storage.recordings = path }
        }
    }

    func chooseDatabaseFolder(_ url: URL) {
        update { $0.storage.database = url.standardizedFileURL.appendingPathComponent("pond.sqlite").path }
    }

    // MARK: - Cameras

    func hasPassword(_ id: String) -> Bool {
        passwords.has(id)
    }

    var isRecording: Bool {
        if case .running = serviceState { return true }
        return false
    }

    /// Checks a camera without blocking the window. `seconds` of video are watched (0: login only).
    func check(_ camera: Config.Camera, password: String, seconds: Double) async -> (lines: [CheckLine], passed: Bool) {
        // First make sure macOS lets the app on the local network: while it is still asking, the camera would
        // look unreachable.
        if let url = URLComponents(string: camera.main), let host = url.host {
            let access = await localNetworkAccess(host, UInt16(url.port ?? 554)) { [weak self] in
                self?.waitingForLocalNetwork = true
            }
            waitingForLocalNetwork = false
            if access == .denied {
                return ([CheckLine(.error, "macOS does not let Pond reach devices on your network. Turn Pond on in System Settings › Privacy & Security › Local Network.", fix: .localNetwork)], false)
            }
        }
        let prober = self.prober
        let result = await Task.detached { Self.probe(prober, camera, password, seconds) }.value
        // The video's rate, for the storage estimate until the camera has recordings of its own.
        if case let .success(report) = result, case let .flowing(stats)? = report.flow, stats.megabitsPerSecond > 0 {
            UserDefaults.standard.set(stats.megabitsPerSecond, forKey: Self.checkedRateKey(camera.id))
        }
        let host = URLComponents(string: camera.main)?.host ?? camera.main
        return CameraCheck.lines(result, host: host, username: camera.username, watchedSeconds: seconds,
                                 cameraApp: camera.device?.appName ?? "the camera\u{2019}s own app")
    }

    /// The check itself, blocking; run off the main thread.
    nonisolated static func probe(_ prober: CameraProber, _ camera: Config.Camera, _ password: String,
                                  _ seconds: Double) -> Result<ProbeReport, RTSPError> {
        do throws(RTSPError) {
            return .success(try prober.probe(main: camera.main, sub: camera.sub, username: camera.username,
                                             password: password, watchSeconds: seconds))
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func checkedRateKey(_ id: String) -> String { "checkedRate.\(id)" }

    /// Checks a configured camera (with any unsaved changes to its address or username) with its saved
    /// password: pond does it, as only pond reads passwords.
    func check(_ camera: Config.Camera, seconds: Double = 6) async -> (lines: [CheckLine], passed: Bool) {
        guard passwords.has(camera.id) else {
            return ([CheckLine(.error, "There is no password for \(camera.name) in the Keychain.", fix: .password)], false)
        }
        if let url = URLComponents(string: camera.main), let host = url.host {
            let access = await localNetworkAccess(host, UInt16(url.port ?? 554)) { [weak self] in
                self?.waitingForLocalNetwork = true
            }
            waitingForLocalNetwork = false
            if access == .denied {
                return ([CheckLine(.error, "macOS does not let Pond reach devices on your network. Turn Pond on in System Settings › Privacy & Security › Local Network.", fix: .localNetwork)], false)
            }
        }
        let passwords = self.passwords
        guard let result = await Task.detached(operation: { passwords.check(camera, seconds: seconds) }).value else {
            return ([CheckLine(.error, "Pond couldn\u{2019}t run its check of \(camera.name).")], false)
        }
        if case let .success(report) = result, case let .flowing(stats)? = report.flow, stats.megabitsPerSecond > 0 {
            UserDefaults.standard.set(stats.megabitsPerSecond, forKey: Self.checkedRateKey(camera.id))
        }
        let host = URLComponents(string: camera.main)?.host ?? camera.main
        return CameraCheck.lines(result, host: host, username: camera.username, watchedSeconds: seconds,
                                 cameraApp: camera.device?.appName ?? "the camera\u{2019}s own app")
    }

    /// Saves a new camera and its password. Returns false (with an alert) if either could not be saved.
    func add(_ camera: Config.Camera, password: String) -> Bool {
        guard let config else { return false }
        if config.cameras.contains(where: { $0.id == camera.id }) {
            alert = "There is already a camera with the ID \(camera.id)."
            return false
        }
        // The camera first: pond saves a password only for a camera in the settings.
        guard update({ $0.cameras.append(camera) }) else { return false }
        do {
            try passwords.save(password, for: camera.id)
        } catch {
            update { $0.cameras.removeAll { $0.id == camera.id } }
            alert = "The password couldn\u{2019}t be saved: \(error)"
            return false
        }
        // Recorded from now: the running recorder starts again to take it on (the others pause for a few
        // seconds), and the live view says it is starting rather than that it isn't recording.
        if case .running = serviceState { restartService() }
        recordingStarted[camera.id] = Date()
        return true
    }

    /// When a camera was added (and its recording began), for the time its first minute takes to be saved.
    var recordingStarted: [String: Date] = [:]

    func setPassword(_ password: String, for id: String) -> Bool {
        do {
            try passwords.save(password, for: id)
            if case .running = serviceState { needsRestart = true }
            return true
        } catch {
            alert = "\(error)"
            return false
        }
    }

    /// Changes name, address (host) and username.
    func edit(_ id: String, name: String, host: String, username: String) -> Bool {
        update { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].name = name
            config.cameras[i].username = username
            for keyPath in [\Config.Camera.main, \Config.Camera.sub] {
                var parts = URLComponents(string: config.cameras[i][keyPath: keyPath])
                parts?.host = host
                if let url = parts?.string { config.cameras[i][keyPath: keyPath] = url }
            }
        }
    }

    func rename(_ id: String, to newID: String) -> Bool {
        guard Config.isSlug(newID) else {
            alert = "The ID must be lowercase letters, digits and dashes, starting with a letter."
            return false
        }
        guard config?.cameras.contains(where: { $0.id == newID }) == false else {
            alert = "There is already a camera with the ID \(newID)."
            return false
        }
        do {
            try passwords.move(from: id, to: newID)
        } catch {
            alert = "\(error)"
            return false
        }
        guard update({ config in
            if let i = config.cameras.firstIndex(where: { $0.id == id }) { config.cameras[i].id = newID }
        }) else {
            try? passwords.move(from: newID, to: id)
            return false
        }
        return true
    }

    /// Puts a camera at `position` in the order cameras are shown (0 is first).
    func moveCamera(_ id: String, to position: Int) {
        update(affectsRecorder: false) { $0.moveCamera(id, to: position) }
    }

    /// Puts a camera where another one is, as when dropped onto it: moving down, it lands after it; moving
    /// up, before it.
    func moveCamera(_ id: String, onto target: String) {
        guard id != target, let cameras = config?.cameras, let to = cameras.firstIndex(where: { $0.id == target }) else { return }
        moveCamera(id, to: to)
    }

    /// Removes a camera and its password; with `deleteRecordings`, also its recordings and event clips
    /// (otherwise retention deletes them in time).
    func remove(_ id: String, deleteRecordings: Bool = false) {
        guard let before = config, update({ $0.cameras.removeAll { $0.id == id } }) else { return }
        try? passwords.remove(for: id)
        guard deleteRecordings else { return }
        Task {
            let failed = await Task.detached { CameraRecordings.delete(of: id, config: before) }.value
            if !failed.isEmpty { alert = "Some recordings could not be deleted:\n" + failed.joined(separator: "\n") }
        }
    }

    /// The size of a camera's recordings and event clips, in bytes.
    func recordingsSize(of id: String) async -> Int64 {
        guard let config else { return 0 }
        return await Task.detached { CameraRecordings.size(of: id, config: config) }.value
    }

    // MARK: - Login service

    /// When Start Service was last pressed: the service takes a few seconds to be ready for live view (and
    /// macOS may ask about the Keychain first), so the button waits meanwhile.
    var serviceStarting: Date?

    /// Start Service was pressed lately, and live view isn't there yet.
    var isServiceStarting: Bool { serviceStarting.map { Date().timeIntervalSince($0) < 45 } ?? false }

    func refreshService() {
        serviceState = service.state
        if case .running = serviceState {} else { needsRestart = false }
    }

    func installService() {
        guard let helperPath else {
            alert = "The recorder can only be installed from Pond.app (make app builds it)."
            return
        }
        guard let config, config.problems().isEmpty, !config.cameras.isEmpty else {
            alert = "Add a camera first: the recorder has nothing to record."
            return
        }
        do {
            try service.install(program: helperPath, configPath: store.path == ConfigStore.defaultPath ? nil : store.path)
            needsRestart = false
        } catch {
            alert = "\(error)"
        }
        refreshService()
    }

    func restartService() {
        do {
            try service.restart()
            needsRestart = false
        } catch {
            alert = "\(error)"
        }
        refreshService()
    }

    func uninstallService() {
        do {
            try service.uninstall()
        } catch {
            alert = "\(error)"
        }
        refreshService()
    }
}

/// Show this camera's event at this time on the timeline.
struct TimelineJump: Equatable {
    var camera: String
    var time: Date
    var id = UUID()
}

/// The value after `name` among the launch arguments.
func launchArgument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// A camera id made from a name: "Front porch" → "front-porch".
func slug(_ name: String) -> String {
    var out = ""
    for ch in name.lowercased() {
        if ch.isASCII, ch.isLetter || ch.isNumber {
            out.append(ch)
        } else if !out.isEmpty, out.last != "-" {
            out.append("-")
        }
    }
    while out.hasSuffix("-") { out.removeLast() }
    if let first = out.first, !first.isLetter { out = "cam-" + out }
    return out
}
