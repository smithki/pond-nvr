// The service's cameras, each run by its own parts: its recorder (RecordingService's worker), its HomeKit
// accessory, its sub-stream held open for instant live view (StreamKeeper), its Baichuan connection (a
// Reolink's privacy mode), its watcher (detection, making events), and, for a doorbell not in HomeKit, its button
// (in HomeKit, the accessory watches it; a press is kept as an event either way). Started together; then, asked to reload (the app's "reload" on the control socket,
// or `pond service reload`), it reads the settings and the passwords again and starts, stops or starts again
// only the parts whose settings changed, the other cameras going on. A change of storage can't be made so: the
// service is restarted for it.
#if canImport(PondMac)
import Devices
import Foundation
import HAPCamera
import Ingest
import PondCore
import PondMac
import Recorder
import Watch

final class CameraSupervisor: @unchecked Sendable {
    let configPath: String
    let log: EventLog
    let recording: RecordingService
    let host: HomeKitHost
    let privacySync: CameraPrivacySync
    /// Its cache of each camera's controls, forgotten for a camera that changed.
    var controls: ControlServer?
    /// The detection model, shared by the cameras' watchers; nil if none could be loaded (nothing is watched).
    var detector: SharedDetector?
    /// Where events are kept.
    var events: EventStore?

    private let lock = NSLock()
    private var config: Config
    private var passwords: [String: String]
    private var keepers: [String: StreamKeeper] = [:]
    private var watchers: [String: CameraWatcher] = [:]
    /// The buttons of doorbells not in HomeKit.
    private var buttons: [String: CameraEvents] = [:]
    /// The login each Baichuan connection was opened with, to close it with.
    private var baichuanAccess: [String: CameraAccess] = [:]
    /// What each part was started with, by camera: changed, the part starts again.
    private var started: [String: Parts] = [:]

    struct Parts: Equatable {
        var recording: String?
        var homekit: String?
        var keeper: String?
        var baichuan: String?
        var watch: String?
        var doorbell: String?
    }

    init(config: Config, passwords: [String: String], configPath: String, log: EventLog, recording: RecordingService,
         host: HomeKitHost, privacySync: CameraPrivacySync) {
        self.config = config
        self.passwords = passwords
        self.configPath = configPath
        self.log = log
        self.recording = recording
        self.host = host
        self.privacySync = privacySync
    }

    /// The cameras as they are now (for the live-view relay and the controls, which look them up as asked).
    var cameras: [Config.Camera] { lock.withLock { config.cameras } }
    func password(_ id: String) -> String? { lock.withLock { passwords[id] } }

    /// Every camera's parts, as the service starts. (The recorder starts its own workers as it runs.)
    func startAll() {
        host.pressed = { [weak self] id in self?.pressed(id) }
        // A camera's motion in the Home app is Pond's detection when it's watched (and a model is loaded).
        host.motionFromDetection = { [weak self] camera in camera.homeKitMotionFromDetection && self?.detector != nil }
        host.start(cameras: config.cameras) { [self] in password($0) }
        for camera in config.cameras {
            let parts = Self.parts(camera, password: passwords[camera.id])
            lock.withLock { started[camera.id] = parts }
            startKeeper(camera, parts)
            startBaichuan(camera, parts)
            startWatcher(camera, parts)
            startButton(camera, parts)
        }
    }

    func stopAll() {
        let (all, watching, pressing) = lock.withLock { () -> ([StreamKeeper], [CameraWatcher], [CameraEvents]) in
            defer { keepers = [:]; watchers = [:]; buttons = [:] }
            return (Array(keepers.values), Array(watchers.values), Array(buttons.values))
        }
        for keeper in all { keeper.stop() }
        for watcher in watching { watcher.stop() }
        for button in pressing { button.stop() }
    }

    // MARK: Reloading

    enum Reload {
        /// What changed, in words ("office-camera added; doorbell's HomeKit restarted"), or that nothing did.
        case applied(String)
        /// A change it can't make while running (the storage): the service is to be restarted.
        case needsRestart(String)
        case failed(String)
    }

    /// The settings and passwords read again, and each camera's changed parts started again.
    func reload() -> Reload {
        let next: Config
        do {
            next = try ConfigStore(path: configPath).load()
        } catch {
            return .failed("the settings can\u{2019}t be read: \(error)")
        }
        let previous = lock.withLock { config }
        if next.storage != previous.storage {
            return .needsRestart("the storage changed")
        }
        var nextPasswords: [String: String] = [:]
        let keychain = KeychainCredentialStore()
        for camera in next.cameras {
            if let password = try? keychain.password(for: camera.id) { nextPasswords[camera.id] = password }
        }
        let before = Dictionary(uniqueKeysWithValues: previous.cameras.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: next.cameras.map { ($0.id, $0) })
        lock.withLock {
            config = next
            passwords = nextPasswords
        }
        recording.setConfig(next)

        var said: [String] = []
        for (id, camera) in before where after[id] == nil {
            stop(camera, all: true)
            said.append("\(id) removed")
        }
        for camera in next.cameras {
            let parts = Self.parts(camera, password: nextPasswords[camera.id])
            guard let old = before[camera.id] else {
                start(camera, parts: parts, changed: Parts(recording: "", homekit: "", keeper: "", baichuan: "", watch: "", doorbell: ""))
                said.append("\(camera.id) added")
                continue
            }
            let was = lock.withLock { started[camera.id] } ?? Self.parts(old, password: nil)
            guard parts != was else { continue }
            var changed = Parts()
            if parts.recording != was.recording { changed.recording = "" }
            if parts.homekit != was.homekit { changed.homekit = "" }
            if parts.keeper != was.keeper { changed.keeper = "" }
            if parts.baichuan != was.baichuan { changed.baichuan = "" }
            if parts.watch != was.watch { changed.watch = "" }
            if parts.doorbell != was.doorbell { changed.doorbell = "" }
            stop(old, parts: changed)
            start(camera, parts: parts, changed: changed)
            let names = [changed.recording.map { _ in "recording" }, changed.homekit.map { _ in "HomeKit" },
                         changed.keeper.map { _ in "live view held open" }, changed.baichuan.map { _ in "Baichuan" }, changed.watch.map { _ in "detection" },
                         changed.doorbell.map { _ in "doorbell button" }]
                .compactMap { $0 }
            said.append("\(camera.id): \(names.joined(separator: ", ")) started again")
        }
        let summary = said.isEmpty ? "nothing changed" : said.joined(separator: "; ")
        log.log("pond", "settings reloaded: \(summary)")
        return .applied(summary)
    }

    // MARK: A camera's parts

    /// What each part is started with: when it changes, that part starts again. Nil: the part doesn't run.
    static func parts(_ camera: Config.Camera, password: String?) -> Parts {
        let login = "\(camera.username)\n\(password ?? "")"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // (HomeKit takes the camera's every setting but detection's, which its watcher has.)
        var served = camera
        served.zones = []
        served.detection = camera.homeKitMotionFromDetection ? nil : false
        let whole = (try? encoder.encode(served)).map { String(decoding: $0, as: UTF8.self) } ?? camera.id
        let zones = (try? encoder.encode(camera.zones)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let reolink = !camera.isVideoOnly && CameraProviders.choices(for: camera.device).contains { $0.id == "reolink" }
        return Parts(recording: "\(camera.recordedStream)\n\(login)",
                     homekit: camera.homekit ? "\(whole)\n\(login)" : nil,
                     keeper: camera.keepsLiveReady ? "\(camera.sub)\n\(login)" : nil,
                     baichuan: reolink && password != nil ? "\(camera.host)\n\(login)" : nil,
                     watch: camera.watches ? "\(camera.sub)\n\(camera.main)\n\(login)\n\(zones)" : nil,
                     doorbell: camera.kind == .doorbell && !camera.homekit && !camera.isVideoOnly
                         ? "\(camera.host)\n\(camera.device?.provider ?? "")\n\(login)" : nil)
    }

    /// Starts the parts marked in `changed` (a value there means "this one").
    private func start(_ camera: Config.Camera, parts: Parts, changed: Parts) {
        let password = password(camera.id)
        lock.withLock { started[camera.id] = parts }
        if changed.recording != nil { recording.add(camera, password: password) }
        if changed.homekit != nil { host.add(camera, password: password) }
        if changed.keeper != nil { startKeeper(camera, parts) }
        if changed.baichuan != nil { startBaichuan(camera, parts) }
        if changed.watch != nil { startWatcher(camera, parts) }
        if changed.doorbell != nil { startButton(camera, parts) }
        controls?.forget(camera.id)
    }

    private func stop(_ camera: Config.Camera, all: Bool = false, parts changed: Parts = Parts()) {
        let was = lock.withLock { all ? started.removeValue(forKey: camera.id) : started[camera.id] }
        if all || changed.recording != nil { recording.remove(camera.id) }
        if all || changed.homekit != nil { host.remove(camera.id) }
        if all || changed.keeper != nil {
            lock.withLock { keepers.removeValue(forKey: camera.id) }?.stop()
        }
        if all || changed.watch != nil {
            lock.withLock { watchers.removeValue(forKey: camera.id) }?.stop()
        }
        if all || changed.doorbell != nil {
            lock.withLock { buttons.removeValue(forKey: camera.id) }?.stop()
        }
        if all || changed.baichuan != nil, was?.baichuan != nil {
            privacySync.unwatch(camera.id)
            if let access = lock.withLock({ baichuanAccess.removeValue(forKey: camera.id) }) {
                Task { await CameraSessions.shared.forget(access) }
            }
        }
        controls?.forget(camera.id)
    }

    private func startKeeper(_ camera: Config.Camera, _ parts: Parts) {
        guard parts.keeper != nil, let password = password(camera.id) else { return }
        let id = camera.id
        let keeper = StreamKeeper(url: camera.sub, username: camera.username, password: password,
                                  paused: { PrivacyState.shared.isPrivate(id) })
        lock.withLock { keepers[id] = keeper }
        keeper.start()
    }

    private func startWatcher(_ camera: Config.Camera, _ parts: Parts) {
        guard parts.watch != nil, let detector, let password = password(camera.id) else { return }
        let log = log, id = camera.id
        let host = self.host
        let watcher = CameraWatcher(camera: id, url: camera.sub, username: camera.username, password: password, detector: detector,
                                    store: events, eventsFolder: lock.withLock { config.storage.eventsPath },
                                    zones: camera.zones, main: camera.main) { line in log.log(id, line) }
        // Its events set the camera's motion sensor in the Home app (where that follows Pond's detection).
        watcher.changed = { change in
            switch change {
            case .began, .resumed: host.detected(id, true)
            case .ended: host.detected(id, false)
            case .better: break
            }
        }
        lock.withLock { watchers[id] = watcher }
        watcher.start()
    }

    /// A doorbell not in HomeKit: its button watched only to keep its presses.
    private func startButton(_ camera: Config.Camera, _ parts: Parts) {
        guard parts.doorbell != nil, let password = password(camera.id),
              let button = CameraProviders.provider(camera.device?.provider)?
                  .events(host: camera.host, username: camera.username, password: password) else { return }
        let id = camera.id
        button.start(motion: { _ in }, pressed: { [weak self] in self?.pressed(id) }, state: { _ in })
        lock.withLock { buttons[id] = button }
    }

    /// A doorbell was pressed: kept as an event, with the picture at that moment when the camera is watched.
    func pressed(_ id: String) {
        if let watcher = lock.withLock({ watchers[id] }) {
            watcher.rang()
        } else {
            let log = log
            CameraWatcher.ring(camera: id, at: Date(), store: events) { line in log.log(id, line) }
        }
    }

    private func startBaichuan(_ camera: Config.Camera, _ parts: Parts) {
        guard parts.baichuan != nil, let password = password(camera.id) else { return }
        let access = CameraAccess(host: camera.host, username: camera.username, password: password, mainStream: camera.main)
        lock.withLock { baichuanAccess[camera.id] = access }
        let sync = privacySync
        Task { sync.watch(camera.id, await CameraSessions.shared.baichuan(access)) }
    }
}
#endif
