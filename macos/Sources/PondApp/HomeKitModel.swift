// HomeKit as the app sees it: which cameras are to be in the Home app (the settings), what the service's
// HomeKit is doing with them (the status file it writes next to the settings), and each camera's setup
// code (its HomeKit record in the Keychain). The service runs the accessories; the app turns cameras on and
// off and restarts it so the change takes.
import Devices
import Foundation
import HAP
import HAPCamera
import PondCore
import PondMac

/// One camera's HomeKit state, as shown on its tile and in its settings. Nil (no badge) when the camera is
/// not to be in the Home app.
enum HomeKitState: Equatable {
    /// The service is not running, so the Home app cannot reach the camera.
    case serviceStopped
    /// The service has not picked up the camera yet (it was turned on since the service started).
    case waitingForService
    /// Running, not yet added in the Home app.
    case notAdded
    case problem(HomeKitStatus.Problem)
    /// A doorbell whose button presses cannot be seen.
    case doorbellButton(HomeKitStatus.DoorbellState)
    /// In the Home app, being watched now.
    case live
    /// In the Home app, all well.
    case ready

    var needsAttention: Bool {
        switch self {
        case .live, .ready: false
        default: true
        }
    }
}

extension AppModel {
    var homeKitStatusPath: String { HomeKitStatus.path(nextTo: store.path) }

    /// The status file, if the service that wrote it is still running.
    func readHomeKitStatus() -> HomeKitStatus? {
        if let demoHomeKitStatus { return demoHomeKitStatus }
        guard let status = HomeKitStatus.read(homeKitStatusPath), kill(status.pid, 0) == 0 else { return nil }
        return status
    }

    func homeKitState(for camera: Config.Camera) -> HomeKitState? {
        guard camera.homekit else { return nil }
        guard case .running = serviceState, let status = homeKitStatus else { return .serviceStopped }
        guard let c = status.cameras[camera.id] else { return .waitingForService }
        if let problem = c.problem { return .problem(problem) }
        if !c.running { return .waitingForService }
        if !c.paired { return .notAdded }
        if let bell = c.doorbell, bell != .watching { return .doorbellButton(bell) }
        return c.viewers > 0 ? .live : .ready
    }

    /// The setup code and QR payload, from the service's status while the camera is not yet added. The app
    /// never reads the HomeKit Keychain item itself: only the service does, so macOS asks only once.
    /// HomeKit Secure Video's state for a camera Pond offers to it (nil otherwise, or with no service).
    func homeKitRecording(for camera: Config.Camera) -> HomeKitStatus.Recording? {
        guard camera.homekit, camera.homekitRecording == true else { return nil }
        return homeKitStatus?.cameras[camera.id]?.recording
    }

    /// Whether Pond offers the camera to HomeKit Secure Video; the service starts again to apply it.
    func setHomeKitRecording(_ id: String, _ on: Bool) {
        let wasInHomeKit = config?.cameras.first { $0.id == id }?.homekit == true
        guard update(affectsRecorder: false, { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].homekitRecording = on ? true : nil
        }) else { return }
        if wasInHomeKit { applyHomeKitChange() }
    }

    func homeKitSetup(for camera: Config.Camera) -> HomeKitStatus.Camera.Setup? {
        homeKitStatus?.cameras[camera.id]?.setup
    }

    /// Puts the camera in HomeKit or takes it out, then starts or restarts the service so it takes effect.
    /// `recording`: whether it's offered to HomeKit Secure Video too (unchanged if nil), in the same change.
    func setHomeKit(_ id: String, _ on: Bool, recording: Bool? = nil) {
        // Taken out before it was ever added: its identity forgotten below, so adding it again starts afresh.
        let unpaired = !on && config?.cameras.first { $0.id == id }?.homekit == true && homeKitStatus?.cameras[id]?.paired == false
        guard update(affectsRecorder: false, { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].homekit = on
            if let recording { config.cameras[i].homekitRecording = recording ? true : nil }
        }) else { return }
        applyHomeKitChange()
        if unpaired { resetHomeKitIdentity(id) }
    }

    /// Pond's own sensor in HomeKit (open while recording isn't going as it should): on or off, the service told.
    func setHomeKitSensor(_ on: Bool) {
        let unpaired = !on && homeKitStatus?.sensor?.paired != true
        guard update(affectsRecorder: false, { $0.homekitSensor = on ? true : nil }) else { return }
        applyHomeKitChange()
        // Turned off before it was added: its identity forgotten, so adding it again starts afresh (an attempt the
        // Home app gave up on can leave it ignoring that identity for good).
        if unpaired { resetHomeKitIdentity(HomeKitHost.sensorID) }
    }

    /// The sensor's state, as the service says it (nil: off, or the service isn't running it yet).
    var homeKitSensor: HomeKitStatus.Sensor? { homeKitStatus?.sensor }

    /// The camera's HomeKit identity and pairings are forgotten: it leaves the Home app for good (it has to
    /// be removed there too) and gets a new setup code if it is added again.
    func forgetHomeKit(_ id: String) {
        resetHomeKitIdentity(id)
        setHomeKit(id, false)
    }

    /// A HomeKit identity and its pairings forgotten, through the service's own program (which owns the Keychain
    /// item): a camera's id, or the sensor's.
    func resetHomeKitIdentity(_ id: String) {
        guard let helperPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["homekit", "reset", id]
        try? process.run()
        process.waitUntilExit()
    }

    func setKind(_ id: String, _ kind: Config.Camera.Kind) {
        let wasInHomeKit = config?.cameras.first { $0.id == id }?.homekit == true
        guard update(affectsRecorder: false, { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].kind = kind
        }) else { return }
        if wasInHomeKit { applyHomeKitChange() }
    }

    /// How many can watch the camera in the Home app at once; the service starts again to offer them.
    func setHomeKitViewers(_ id: String, _ viewers: Int) {
        let wasInHomeKit = config?.cameras.first { $0.id == id }?.homekit == true
        guard update(affectsRecorder: false, { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].homekitViewers = viewers == Config.Camera.defaultHomeKitViewers ? nil : viewers
        }) else { return }
        if wasInHomeKit { applyHomeKitChange() }
    }

    /// The picture the Home app gets: the camera's stream, or re-encoded by Pond; the service starts again to
    /// apply it.
    func setHomeKitVideo(_ id: String, _ video: Config.Camera.HomeKitVideo) {
        let wasInHomeKit = config?.cameras.first { $0.id == id }?.homekit == true
        guard update(affectsRecorder: false, { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].homekitVideo = video == .camera ? nil : video
        }) else { return }
        if wasInHomeKit { applyHomeKitChange() }
    }

    /// Whether the service keeps the camera's sub-stream open for live views that start at once; it starts
    /// again to apply it.
    /// Whether the camera is watched for detection, and its zones. (The running service takes them up with the
    /// settings' reload: only the camera's watcher starts again.)
    /// Recorded from its sub-stream (or its main stream again).
    func setRecordsSub(_ id: String, _ sub: Bool) {
        update(affectsRecorder: false) { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].recordsSub = sub ? true : nil
        }
    }

    func setDetection(_ id: String, _ on: Bool, zones: [Config.Zone]) {
        update(affectsRecorder: false) { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].detection = on ? nil : false
            config.cameras[i].zones = zones
        }
    }

    /// What sets the camera's motion in the Home app. (The running service takes it up with the settings' reload:
    /// only the camera's accessory starts again.)
    func setHomeKitMotion(_ id: String, _ motion: Config.Camera.HomeKitMotion) {
        update(affectsRecorder: false) { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].homekitMotion = motion == .detection ? nil : motion
        }
    }

    func setInstantLive(_ id: String, _ on: Bool) {
        guard update(affectsRecorder: false, { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }) else { return }
            config.cameras[i].instantLive = on == config.cameras[i].homekit ? nil : on
        }) else { return }
        // (The running service takes it up with the settings' reload.)
    }

    func refreshHomeKit() {
        let status = readHomeKitStatus()
        if status != homeKitStatus { homeKitStatus = status }
    }

    /// A camera's HomeKit changed: a running service takes it up with the settings' reload (only that camera's
    /// accessory starts again); otherwise the service is started (installed the first time) to serve it.
    func applyHomeKitChange() {
        if case .running = serviceState {
            reloadService()
        } else {
            startService()
        }
        homeKitStatus = readHomeKitStatus()
    }

    /// Starts the background service, installing it the first time; restarts it if it runs.
    func startService() {
        serviceStarting = Date()
        switch serviceState {
        case .running, .stopped: restartService()
        case .notInstalled: installService()
        }
    }

    /// What a camera (not yet saved) says it is.
    func identify(host: String, username: String, password: String) async -> Config.Device? {
        await DeviceReader.read(host: host, username: username, password: password)
    }

    /// A new camera's stream addresses, asked of it with the password just typed: its make's known ones, else
    /// ONVIF's. The words say where they came from ("Reolink", "ONVIF").
    func findStreams(host: String, username: String, password: String) async -> (main: String, sub: String, from: String)? {
        guard let found = await CameraProviders.findStreams(host: host, username: username, password: password) else { return nil }
        return (found.main, found.sub, found.provider == "onvif" ? "ONVIF" : found.provider.capitalized)
    }

    /// Asks the camera what it is and keeps the answer; a doorbell is marked as one. pond does it (it reads
    /// the password), and writes the settings; they are read again after.
    func identify(_ id: String) async {
        let passwords = self.passwords
        await Task.detached { passwords.identify(id, provider: nil) }.value
        reload()
    }

    /// Talks to the camera only for its video from now on: no logins for its details or events (those it
    /// gave stay). Its recording in HomeKit pauses (the setting is kept) until another way is chosen.
    func setVideoOnly(_ id: String) {
        guard update(affectsRecorder: false, { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == id }), config.cameras[i].device != nil else { return }
            config.cameras[i].device?.provider = Config.Device.videoOnly
        }) else { return }
        if config?.cameras.first(where: { $0.id == id })?.homekit == true { applyHomeKitChange() }
    }

    /// Talks to the camera through `provider` from now on: asks it that way first, and keeps the answer only
    /// if it comes (else the camera stays as it was, and false). The service starts again to watch its
    /// events the new way.
    func setProvider(_ id: String, _ provider: String) async -> Bool {
        let passwords = self.passwords
        await Task.detached { passwords.identify(id, provider: provider) }.value
        reload()
        let camera = config?.cameras.first { $0.id == id }
        guard camera?.device?.provider == provider else { return false }
        if camera?.homekit == true { applyHomeKitChange() }
        return true
    }
}
