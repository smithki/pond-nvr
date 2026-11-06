// The app's state: the settings (read and saved through ConfigStore, exactly as `pond` does), the camera
// passwords (Keychain), camera checks, and the login service. Views read it and call its methods; nothing
// else touches the settings file.
import AppKit
import Control
import Devices
import Foundation
import Ingest
import PondCore
import PondMac
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
    /// The storage outlook last measured (the drive, how long it lasts), kept so the Storage and Retention
    /// tabs show it at once rather than filling in after they appear; measured again in the background.
    var lastStorageOutlook: StorageOutlook?
    /// What the service's HomeKit is doing (nil when the service is not running). See HomeKitModel.
    var homeKitStatus: HomeKitStatus?
    /// The one camera heard in live view; the others are muted.
    var audibleCamera: String?
    /// Live controls (LiveControlsModel): the camera being talked through and how loud the voice is (0–1),
    /// each camera's presets as last asked, and its night mode.
    var talking: Talker?
    var talkLevel: Double = 0
    var presets: [String: [PTZPreset]] = [:]
    /// Each camera's items' values, as last read or set (by camera, then item).
    var itemValues: [String: [String: Config.Controls.Value]] = [:]
    /// Each position's picture ("camera/position"), from the last time it was seen; the stream each camera's
    /// tile shows (to take them from); and the position a camera was last sent to, until it's moved by hand.
    var presetPictures: [String: NSImage] = [:]
    @ObservationIgnored var liveFeeds: [String: LiveStream] = [:]
    /// Tiles' live pictures taken for their stand-ins, and when (`liveStill`).
    @ObservationIgnored var liveStills: [String: (image: CGImage, at: Date)] = [:]
    @ObservationIgnored var atPreset: [String: String] = [:]
    /// The camera whose other positions are open above the dock's More card.
    var morePositionsOpen: String?
    /// The position just kept ("camera/position"), for the dock to show where it went.
    var justKept: String?
    /// A picture just taken from a camera's live view: the camera (its tile flashes) and where it was saved.
    var flash: String?
    var savedPicture: (camera: String, file: URL)?
    /// The docked camera's adjustments are open in the live view's sidebar.
    var adjustmentsInSidebar = false
    /// The cameras' rail was hidden to make room for the adjustments' sidebar (shown again when it goes).
    /// (Kept between launches with the rail's own showing, so a rail hidden for room comes back when there's
    /// room, after a relaunch too.)
    var railMadeRoom = UserDefaults.standard.bool(forKey: "liveRailMadeRoom") {
        didSet { UserDefaults.standard.set(railMadeRoom, forKey: "liveRailMadeRoom") }
    }
    /// The cameras made private in Pond (from privacy.json, which the service keeps).
    var privateCameras: Set<String> = []
    /// Private on the camera itself (its own privacy mode, as the recorder sees it): shown as private, but Pond
    /// can't turn it off.
    var privateOnCamera: Set<String> = []
    /// The show and hide button's width over the dock (measured), so what the dock says beside it stays clear of it.
    var controlsButtonWidth: CGFloat = 150
    /// Starting their video again after their own privacy mode turned off (from privacy.json).
    var wakingCameras: Set<String> = []
    /// Settings waiting for a camera to be back from its privacy mode, each item's (from privacy.json).
    var pendingSettings: [String: [String: Config.Controls.Value]] = [:]
    /// Just changed here: not read back from the file until then (the service may not have written it yet).
    @ObservationIgnored var privacyChanged = Date.distantPast
    /// The open dock's narrowest width (its narrowest arrangement, measured), for the window to decide whether
    /// the adjustments' sidebar fits beside it or floats over the stage.
    var dockNarrowest: CGFloat = LiveLayout.narrowestDock
    /// No room for the adjustments beside the stage (a narrow window): they're the dock's second frame instead.
    var sidebarFloats = false
    /// How each camera is doing (the doctor), and what its window shows (DoctorWindow).
    let doctor = CameraDoctor()
    var doctorPage: DoctorPage = .cameras
    /// Which events are new (seen once on screen in Events).
    let seenEvents = EventsSeen(demo: DemoSession.scenario?.name)
    /// Opens a window by its id (SwiftUI's, kept by the views that have it), for what opens one from outside a view:
    /// the doctor's, from a notification or the model.
    static var openWindow: ((String) -> Void)?
    /// The rail is shown or hidden by the window's size just now: at once, not slid (its showing is a stored
    /// preference, which reaches the view apart from the change's transaction).
    var railMovesAtOnce = false
    /// The live view's width (the rail, the stage and the adjustments' column), as laid out.
    var liveWidth: CGFloat = 0
    /// The rail would fit beside the open controls (else its button is off while it's hidden).
    var railFits = true
    /// The widest the rail may be dragged: what leaves the open controls dock room (nil: no limit).
    var railLimit: CGFloat?
    /// A control that failed, for a moment, by camera.
    var controlError: [String: String] = [:]
    /// Waits for macOS's local network permission before a check; tests replace it so they connect nowhere.
    var localNetworkAccess: (String, UInt16, @escaping @MainActor @Sendable () -> Void) async -> LocalNetworkAccess.Outcome = {
        await LocalNetworkAccess.wait(host: $0, port: $1, waiting: $2)
    }
    /// A camera check is waiting for permission to reach the local network (macOS is asking).
    private(set) var waitingForLocalNetwork = false
    private(set) var serviceState: ServiceControl.State = .notInstalled
    /// Remote access as the service has it (the Ponds paired, those connected), for the Pond switcher.
    var remoteStatus: ControlSocket.RemoteStatus?
    /// The other Ponds paired with this one, and their cameras (`remote.ponds`), shown beside this Mac's.
    var remotePonds: [ControlSocket.RemotePond] = []
    /// Which Ponds the window shows: all of them together, or one.
    var shownPonds = ShownPonds.all
    /// Other Ponds' cameras in the order chosen here (this Mac's own order is its settings'; another's is its own
    /// business), kept in the app's preferences.
    var remoteOrder: [String: [String]] = (UserDefaults.standard.dictionary(forKey: "remoteCameraOrder") as? [String: [String]]) ?? [:] {
        didSet { UserDefaults.standard.set(remoteOrder, forKey: "remoteCameraOrder") }
    }
    /// Counted up when another action changes which Ponds are shown (not the button's own menu): the button says so.
    var shownPondsNudge = 0
    /// Whether Pond is recording, watched while the app runs (ServiceWatch).
    @ObservationIgnored let watch = ServiceWatch()
    /// The stage has cameras of more than one Pond on it now (their tiles then say which).
    var stageMixesPonds = false
    /// Settings were saved while the service ran with the old ones.
    /// The settings the running recorder started with, as far as the app knows (at launch: what was saved),
    /// and whether a password changed since.
    private var recorderSettings: RecorderSettings?
    private var passwordChangedSinceStart = false
    /// The start, restart or removal going on, if any, whether it starts the recorder, and when the last
    /// start or restart was asked for.
    private var serviceChange: Task<Void, Never>?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    private var serviceChangeStarts = false
    private var restartedAt: Date?

    /// The recorder runs with settings other than the saved ones: changed since it started, and not changed
    /// back.
    /// Changes to the cameras and retention are taken up by a reload as they're saved, so they don't count
    /// unless a reload failed (an older service); the storage always does.
    var needsRestart: Bool {
        guard case .running = serviceState, let recorderSettings, let config else { return false }
        let now = RecorderSettings(config)
        if now.storage != recorderSettings.storage { return true }
        return reloadFailed && (passwordChangedSinceStart || now != recorderSettings)
    }

    /// The last reload didn't take (the service couldn't, or the change needed a restart).
    private var reloadFailed = false

    /// The recorder (re)started now, with the saved settings.
    func recorderStarted() {
        recorderSettings = config.map(RecorderSettings.init)
        passwordChangedSinceStart = false
        reloadFailed = false
    }
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
    /// The Events view as it was left (the event open in its panel, its filters): as it's come back to.
    var eventsState = EventsState()
    var addingCamera = false
    /// Find Cameras' card, open over the top right of the main window, and how far the button it points at
    /// is (its middle) from the window's trailing edge.
    var showingFoundCameras = false
    var findCamerasButtonFromTrailing: CGFloat = 64
    /// The overview of what needs attention (the toolbar's state, clicked), and where its button's middle is.
    var showingOverview = CommandLine.arguments.contains("--overview")   // (open from the start: for pictures of it)
    /// (Nil until the button has said.)
    var overviewButtonFromLeading: CGFloat?
    /// The camera rail showing only the cameras that need attention.
    var railNeedsAttention = false
    /// Asked (from the overview) to put the cameras that need attention on the stage, alone: Live does, when it changes.
    var stagingNeedsAttention = 0
    /// Cameras on the network (found at launch, at most daily, and when Add Camera opens), whether a look is
    /// under way, the ones not to mention again, and the one Add Camera starts from. See DiscoveryModel.
    var foundCameras: [FoundCamera] = DemoSession.scenario == nil ? AppModel.keptFoundCameras() : []
    var findingCameras = false
    var ignoredCameras: Set<String> = Set(UserDefaults.standard.stringArray(forKey: AppModel.ignoredCamerasKey) ?? [])
    var addingFrom: FoundCamera?

    init(store: ConfigStore = ConfigStore(path: DemoSession.configPath ?? ProcessInfo.processInfo.environment[Brand.configVariable]
             ?? ConfigStore.defaultPath),
         passwords: PasswordKeeper? = nil,
         prober: CameraProber = RTSPProber(),
         service: ServiceControl = DemoSession.serviceControl ?? ServiceControl(launchd: RealLaunchd()),
         helperPath: String? = Bundle.main.path(forAuxiliaryExecutable: Brand.command)) {
        self.store = store
        self.passwords = passwords ?? HelperPasswordKeeper(helper: helperPath, configPath: store.path)
        self.prober = prober
        self.service = service
        self.helperPath = helperPath
        reload()
        refreshService()
        watch.start(self)
        Self.current = self
    }

    /// What the live views decode now (each playing tile's picture, at a camera's usual 15 fps), told to the service
    /// for the media engine's budget, which counts it as live viewing (and makes room for it). Nothing when nothing's
    /// shown, and nothing is said again while it's the same.
    func reportLiveViews() async {
        let pixels = liveFeeds.values.filter { $0.state == .playing }.compactMap(\.size)
            .reduce(0.0) { $0 + MediaBudget.decode(width: Int($1.width), height: Int($1.height), fps: 15) }
        guard pixels != reportedLiveViews || Date().timeIntervalSince(reportedLiveViewsAt) > 20 else { return }
        reportedLiveViews = pixels
        reportedLiveViewsAt = Date()
        _ = await controlClient.ask(.init(camera: "", action: "media.app", value: .number(pixels)), timeout: 3)
    }
    @ObservationIgnored private var reportedLiveViews = -1.0
    @ObservationIgnored private var reportedLiveViewsAt = Date.distantPast

    /// The app's (for what isn't a view: a notification clicked).
    nonisolated(unsafe) static weak var current: AppModel?

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
    /// Whether the recorder needs a restart for it is worked out from the settings it uses
    /// (`RecorderSettings`); `affectsRecorder` says only what the caller expects.
    @discardableResult
    func update(affectsRecorder: Bool = true, _ change: (inout Config) -> Void) -> Bool {
        guard var next = config else { return false }
        change(&next)
        guard next != config else { return true }
        let previous = config
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
        // The running service takes up changes to the cameras, retention or remote access at once, only what changed
        // starting again (a reload); a change of storage still waits for Restart Recorder.
        if let previous, previous.cameras != next.cameras || previous.retention != next.retention || previous.remote != next.remote
            || previous.name != next.name {
            reloadService()
        }
        return true
    }

    /// Asks the running service to take up the saved settings (`pond service reload`): it starts, stops or starts
    /// again only the cameras that changed. Several changes together are one reload. A service that can't (an
    /// older one), or a change that needs a restart, leaves the Restart Recorder prompt.
    func reloadService() {
        guard case .running = serviceState else { return }
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let reply = await controlClient.ask(.init(camera: "", action: "reload"), timeout: 60)
            if reply.error == nil, reply.restartNeeded != true {
                // (Keeping the storage it started with: a change of that still needs the restart.)
                let storage = recorderSettings?.storage
                recorderStarted()
                if let storage { recorderSettings?.storage = storage }
            } else {
                reloadFailed = true
            }
        }
    }

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
        // (Another Pond's camera needs none here: its own Pond logs in to it.)
        AppModel.pond(of: id) != nil || passwords.has(id)
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
        // Recorded from now (the running service takes it on with the settings' reload, the others going on), and
        // the live view says it is starting rather than that it isn't recording.
        recordingStarted[camera.id] = Date()
        // What it can be controlled with, worked out now (Add Camera asked only what it is): without it, its dock
        // was empty until it was identified again.
        Task { await identify(camera.id) }
        return true
    }

    /// When a camera was added (and its recording began), for the time its first minute takes to be saved.
    var recordingStarted: [String: Date] = [:]

    /// When the running service started (its process's start): after a gap, its cameras' first minutes aren't
    /// saved yet for a minute or so, which isn't "not recording".
    var serviceStarted: Date? {
        guard case let .running(pid) = serviceState, let pid = pid_t(pid) else { return nil }
        if let known = serviceStart, known.pid == pid { return known.date }
        let date = Self.processStart(pid)
        serviceStart = date.map { (pid, $0) }
        return date
    }
    @ObservationIgnored private var serviceStart: (pid: pid_t, date: Date)?

    nonisolated static func processStart(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    func setPassword(_ password: String, for id: String) -> Bool {
        do {
            try passwords.save(password, for: id)
            if case .running = serviceState {
                passwordChangedSinceStart = true
                reloadService()
            }
            return true
        } catch {
            alert = "\(error)"
            return false
        }
    }

    /// Changes name, address (host) and username.
    /// Without `main` and `sub`, the stream addresses follow the host; with them, they are as given.
    func edit(_ id: String, name: String, host: String, username: String, main: String? = nil, sub: String? = nil) -> Bool {
        update { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].name = name
            config.cameras[i].username = username
            for keyPath in [\Config.Camera.main, \Config.Camera.sub] {
                var parts = URLComponents(string: config.cameras[i][keyPath: keyPath])
                parts?.host = host
                if let url = parts?.string { config.cameras[i][keyPath: keyPath] = url }
            }
            if let main { config.cameras[i].main = main }
            if let sub { config.cameras[i].sub = sub }
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
        reloadService()
        guard deleteRecordings else { return }
        Task {
            let failed = await Task.detached {
                // Its events too (their pictures are in its folders): kept, they'd point at what's gone.
                EventSource(config: before)?.deleteCamera(id)
                return CameraRecordings.delete(of: id, config: before)
            }.value
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

    /// What a tile without live video says while the service starts or restarts (instead of offering to
    /// start it); nil when it isn't.
    var serviceStartingWords: String? {
        if isRestartingRecorder { return "Restarting Pond\u{2019}s service\u{2026}" }
        return isServiceStarting ? "Starting Pond\u{2019}s service\u{2026}" : nil
    }

    func refreshService() {
        serviceState = service.state
        // Running, and not known since when: it started with what is saved now (the app's launch).
        if case .running = serviceState {
            if recorderSettings == nil { recorderStarted() }
        } else {
            recorderSettings = nil
        }
    }

    @discardableResult
    func installService() -> Task<Void, Never>? {
        guard let helperPath else {
            alert = "The recorder can only be installed from Pond NVR.app (make app builds it)."
            return nil
        }
        guard let config, config.problems().isEmpty, !config.cameras.isEmpty else {
            alert = "Add a camera first: the recorder has nothing to record."
            return nil
        }
        let configPath = store.path == ConfigStore.defaultPath ? nil : store.path
        return changeService(starts: true) { try $0.install(program: helperPath, configPath: configPath) }
    }

    @discardableResult
    func restartService() -> Task<Void, Never> {
        changeService(starts: true) { try $0.restart() }
    }

    @discardableResult
    func uninstallService() -> Task<Void, Never> {
        changeService(starts: false) { try $0.uninstall() }
    }

    /// Whether the recorder is being started, restarted or removed now.
    var isChangingService: Bool { serviceChange != nil }

    /// Restarting, as people see it: from the button until the recorder runs again (launchd stops it, then
    /// starts it a moment later; it is not "stopped" meanwhile). Up to 15 s, after which a stopped recorder
    /// says so.
    var isRestartingRecorder: Bool {
        if isChangingService, serviceChangeStarts { return true }
        guard let restartedAt, Date().timeIntervalSince(restartedAt) < 15 else { return false }
        if case .running = serviceState { return false }
        return true
    }

    /// Starts, restarts or removes the recorder off the main thread: launchd waits for the recorder to stop
    /// (it finishes its recordings and HomeKit first, seconds), which on the main thread froze the app. One
    /// at a time; the settings it starts with are those saved when asked.
    @discardableResult
    private func changeService(starts: Bool, _ work: @escaping @Sendable (ServiceControl) throws -> Void) -> Task<Void, Never> {
        if let serviceChange { return serviceChange }
        let service = self.service
        let settings = config.map(RecorderSettings.init)
        serviceChangeStarts = starts
        // Taken as started at once (every button answers alike: the Restart buttons go, the toolbar says
        // Restarting… until it runs), and put back if it fails.
        let before = (recorderSettings, passwordChangedSinceStart)
        if starts {
            restartedAt = Date()
            // The live views wait for it (rather than offering to start it) until their video comes back.
            serviceStarting = Date()
            recorderSettings = settings
            passwordChangedSinceStart = false
        }
        let task = Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do { try work(service); return nil } catch { return "\(error)" }
            }.value
            guard let self else { return }
            if let failure {
                alert = failure
                if starts { (recorderSettings, passwordChangedSinceStart) = before }
                restartedAt = nil
            }
            serviceChange = nil
            refreshService()
            // Until it runs again (a moment after launchd starts it), checked often, so the toolbar and
            // settings go from Restarting… to Recording as soon as it does.
            while starts, isRestartingRecorder {
                try? await Task.sleep(for: .milliseconds(500))
                refreshService()
            }
        }
        serviceChange = task
        return task
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

/// What of the settings the recorder works from: where it records, what it keeps, and each camera's streams
/// and login. Changes to anything else (the cameras' order and names, HomeKit, which restarts by itself)
/// don't need the recorder restarted.
struct RecorderSettings: Equatable {
    var storage: Config.Storage
    var retention: Config.Retention
    var cameras: [String]

    init(_ config: Config) {
        storage = config.storage
        retention = config.retention
        cameras = config.cameras.map { [$0.id, $0.main, $0.sub, $0.username].joined(separator: "\n") }.sorted()
    }
}

/// What the Events view keeps across visits.
extension AppModel {
    /// An event (from the Timeline) in the Events view: chosen there, its details open, the filters let it show.
    func showInEvents(_ event: TimelineEvent) {
        if let camera = eventsState.camera, camera != event.camera { eventsState.camera = nil }
        eventsState.hidden.remove(event.kind)
        // (The Events view opens on the one chosen, in view, when it next loads.)
        eventsState.selected = event.id
        mode = .events
    }
}

struct EventsState: Equatable {
    /// The event whose details are open.
    var selected: String?
    /// One camera's, or all.
    var camera: String?
    var hidden: Set<TimelineEvent.Kind> = []
}
