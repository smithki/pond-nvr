// The `pond` command's logic. Everything outside (the settings file, the Keychain, the camera, the terminal)
// comes in through the initializer, so the commands are tested with fakes.
import Control
import Foundation
import Ingest
import NVRCore
import Recorder

public struct CLI {
    let store: ConfigStore
    let credentials: CredentialStore?
    let prober: CameraProber
    let clips: ClipRecording
    let service: ServiceRunning
    let launchd: Launchd?
    let executablePath: String
    let console: Console

    /// `credentials` and `launchd` are nil where there is no Keychain or launchd (Linux).
    public init(store: ConfigStore, credentials: CredentialStore?, prober: CameraProber,
                clips: ClipRecording = RTSPClipRecorder(), service: ServiceRunning = RealService(),
                launchd: Launchd? = nil, executablePath: String = CommandLine.arguments.first ?? "pond",
                console: Console) {
        self.store = store
        self.credentials = credentials
        self.prober = prober
        self.clips = clips
        self.service = service
        self.launchd = launchd
        self.executablePath = executablePath
        self.console = console
    }

    /// Runs one command line (without the program name) and returns the exit code.
    public func run(_ arguments: [String]) -> Int32 {
        var args = Args(arguments)
        do {
            switch args.next() {
            case "init": try initCommand(&args)
            case "check": try checkCommand(&args)
            case "run": try runCommand(&args)
            case "service": try serviceCommand(&args)
            case "storage": try storageCommand(&args)
            case "retention": try retentionCommand(&args)
            case "camera", "cameras": try cameraCommand(&args)
            case "version":
                try args.done()
                console.out("\(Brand.command) \(Brand.version)")
            case nil, "help":
                console.out(Self.help)
            case let other?:
                throw UsageError("Unknown command \(other). See: pond help")
            }
            return 0
        } catch let error as UsageError {
            console.err("✗ \(error.message)")
            return 2
        } catch let failure as Failure {
            return failure.code
        } catch {
            console.err("✗ \(error)")
            return 1
        }
    }

    static let help = """
    Usage: pond <command> [options]

    Settings
      init [--recordings PATH] [--database PATH]   create the settings file with defaults
      check                                        check the settings, storage folders and camera passwords

    Recording
      run [--for SECONDS] [--log FILE]             record every camera and apply retention, until Ctrl-C

    Login service
      service install                              record whenever you are logged in, restarting if it stops
      service status                               whether it is running, and the end of its log
      service restart                              after changing settings or installing a new pond
      service uninstall                            stop it and remove it

    Storage
      storage                                      show the folders, whether they are ready, and free space
      storage recordings PATH                      folder for continuous recording (prepared for pond)
      storage events PATH|same                     folder for event clips; same = inside recordings
      storage database PATH                        the index database (keep it on the internal disk)

    Retention
      retention                                    show the retention settings
      retention continuous DAYS                    days of continuous recording to keep
      retention max-size GB|none                   cap on continuous recording's space
      retention events DAYS                        days to keep event clips and snapshots
      retention reserve GB                         free space to keep; below it the oldest recording is overwritten

    Cameras
      camera list
      camera add ID --host HOST [--name NAME] [--username USER] [--password-stdin] [--no-test]
      camera set ID [--name NAME] [--host HOST] [--username USER] [--main URL] [--sub URL]
                    [--kind camera|doorbell] [--homekit on|off] [--homekit-viewers 1-4] [--instant-live on|off]
                    [--homekit-video camera|reencoded] [--homekit-recording on|off]
      camera password ID [--password-stdin] [--no-test]
      camera password ID --remove | --move-to NEW-ID   the Keychain item alone (the settings unchanged)
      camera test ID [--seconds N] [--json]        log in, describe both streams, watch the video
                     [--main URL] [--sub URL] [--username USER]   (unsaved settings, the saved password)
      camera record ID FILE.mp4 [--seconds N]      record the main stream to one MP4 file (a check)
      camera rename ID NEW-ID
      camera move ID POSITION|top|bottom           the camera's place in the order the app shows them
      camera remove ID [--delete-recordings] [--yes]
      camera identify ID [--provider reolink|onvif]   ask the camera what it is (model, serial, doorbell)

    HomeKit
      homekit code                                 setup codes and QR codes for the cameras not yet in a home
      homekit reset ID                             forget a camera's HomeKit identity and pairings
      homekit snapshot ID FILE.jpg                 the snapshot the Home app would be sent
      homekit                                      serve the cameras in the foreground (not while the service runs)

    Moving from nvr
      migrate                                      carry a setup from before the rename (nvr) over to Pond

    The settings file is ~/Library/Application Support/Pond/config.json unless POND_CONFIG or --config names another.
    Camera passwords are kept in the login Keychain (service pond, account = camera ID).
    """

    // MARK: - Shared

    func load() throws -> Config {
        guard store.exists else {
            console.err("✗ There is no settings file at \(store.path). Create one with: pond init")
            throw Failure()
        }
        do {
            return try store.load()
        } catch {
            console.err("✗ \(error.description)")
            throw Failure()
        }
    }

    /// Loads, changes and saves the settings. Nothing is saved if the change leaves a problem.
    func edit(_ change: (inout Config) throws -> Void) throws -> Config {
        var config = try load()
        try change(&config)
        do {
            try store.save(config)
        } catch let ConfigStore.Error.invalidSettings(problems) {
            for p in problems { console.err("✗ \(p)") }
            console.err("✗ Nothing was saved.")
            throw Failure()
        } catch {
            console.err("✗ \(error.description)")
            throw Failure()
        }
        return config
    }

    func requireCredentials() throws -> CredentialStore {
        guard let credentials else {
            console.err("✗ Camera passwords are kept in the macOS Keychain, which is not available here.")
            throw Failure()
        }
        return credentials
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.0f GB", Double(bytes) / 1e9) }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%g", value)
    }

    static func positiveInt(_ text: String?, _ what: String) throws(UsageError) -> Int {
        guard let text else { throw UsageError("Give the number of \(what).") }
        guard let n = Int(text), n >= 1 else { throw UsageError("\(text) is not a whole number of \(what), 1 or more.") }
        return n
    }

    static func nonNegative(_ text: String?, _ what: String) throws(UsageError) -> Double {
        guard let text else { throw UsageError("Give \(what).") }
        guard let n = Double(text), n >= 0, n.isFinite else { throw UsageError("\(text) is not a number of GB.") }
        return n
    }

    // MARK: - init, check

    func initCommand(_ args: inout Args) throws {
        let recordings = try args.option("--recordings")
        let database = try args.option("--database")
        try args.done()
        if store.exists {
            console.err("✗ \(store.path) already exists; nothing was changed. Change it with pond storage, pond retention and pond camera.")
            throw Failure()
        }
        var storage = Config.Storage(recordings: "/Volumes/Pond/recordings",
                                     database: Brand.supportFolder + "/pond.sqlite")
        if let database { storage.database = database }
        if let recordings {
            storage.recordings = try prepare(recordings)
        }
        let config = Config(storage: storage)
        do {
            try store.save(config)
        } catch {
            console.err("✗ \(error.description)")
            throw Failure()
        }
        console.out("✓ settings written to \(store.path)")
        if recordings == nil {
            console.out("Next: choose the recording folder with pond storage recordings PATH, then add a camera with pond camera add.")
        } else {
            console.out("Next: add a camera with pond camera add ID --host HOST.")
        }
    }

    func checkCommand(_ args: inout Args) throws {
        try args.done()
        let config = try load()
        var ok = true
        for problem in config.problems() {
            console.err("✗ \(problem)")
            ok = false
        }
        console.out("✓ \(store.path): \(config.cameras.count) camera\(config.cameras.count == 1 ? "" : "s")")
        console.out("✓ " + retentionSummary(config.retention))
        for (name, path) in folders(config) {
            ok = showFolder(name, path) && ok
        }
        if let credentials {
            for camera in config.cameras where Config.isSlug(camera.id) {
                do {
                    if try credentials.password(for: camera.id) == nil {
                        console.err("✗ Camera \(camera.id) has no password in the Keychain. Set it with: pond camera password \(camera.id)")
                        ok = false
                    } else {
                        console.out("✓ camera \(camera.id): password in the Keychain")
                    }
                } catch {
                    console.err("✗ Camera \(camera.id): \(error)")
                    ok = false
                }
            }
        }
        guard ok else { throw Failure() }
        console.out("The settings are usable.")
    }

    // MARK: - run

    func runCommand(_ args: inout Args) throws {
        let seconds = try args.option("--for").map { text throws(UsageError) in
            guard let s = Double(text), s > 0 else { throw UsageError("--for needs a number of seconds.") }
            return s
        }
        let logPath = try args.option("--log").map { NSString(string: $0).expandingTildeInPath }
        try args.done()
        let log: EventLog
        if let logPath {
            do {
                log = try FileLog(path: logPath)
            } catch {
                console.err("✗ The log \(logPath) cannot be written: \(error.localizedDescription)")
                throw Failure()
            }
        } else {
            log = PrintLog()
        }
        let config = try load()
        let problems = config.problems()
        guard problems.isEmpty else {
            for p in problems { console.err("✗ \(p)") }
            throw Failure()
        }
        guard !config.cameras.isEmpty else {
            console.err("✗ There are no cameras. Add one with: pond camera add ID --host HOST")
            throw Failure()
        }
        let credentials = try requireCredentials()
        var passwords: [String: String] = [:]
        for camera in config.cameras {
            if let password = try credentials.password(for: camera.id) {
                passwords[camera.id] = password
            } else {
                console.err("! Camera \(camera.id) has no password in the Keychain and will not record. Set it with: pond camera password \(camera.id)")
            }
        }
        guard !passwords.isEmpty else {
            console.err("✗ No camera has a password.")
            throw Failure()
        }
        let status = StorageLocation.status(of: config.storage.recordingsPath)
        if !status.isReady {
            console.err("! The recordings folder \(config.storage.recordingsPath) is \(status.description). Recording starts when it is back.")
        }
        service.run(config: config, passwords: passwords, for: seconds, log: log)
    }

    // MARK: - storage

    func folders(_ config: Config) -> [(String, String)] {
        var list = [("recordings", config.storage.recordingsPath)]
        if config.storage.events != nil { list.append(("events", config.storage.eventsPath)) }
        return list
    }

    /// Prints one folder's state; returns whether it is ready.
    @discardableResult
    func showFolder(_ name: String, _ path: String) -> Bool {
        let status = StorageLocation.status(of: path)
        guard status.isReady else {
            console.err("✗ The \(name) folder \(path) is \(status.description).")
            return false
        }
        if let space = StorageLocation.space(of: path) {
            console.out("✓ \(name) folder \(path): ready, \(Self.gb(space.free)) free of \(Self.gb(space.total))")
        } else {
            console.out("✓ \(name) folder \(path): ready")
        }
        return true
    }

    /// Prepares a folder for pond and returns its full path.
    func prepare(_ path: String) throws -> String {
        let full = (NSString(string: path).expandingTildeInPath as NSString).standardizingPath
        do {
            try StorageLocation.prepare(full)
        } catch {
            console.err("✗ \(error.description)")
            throw Failure()
        }
        return full
    }

    func storageCommand(_ args: inout Args) throws {
        let which = args.next()
        let value = args.next()
        try args.done()
        switch (which, value) {
        case (nil, nil):
            let config = try load()
            for (name, path) in folders(config) { showFolder(name, path) }
            if config.storage.events == nil { console.out("  event clips are kept inside the recordings folder") }
            console.out("  database: \(config.storage.databasePath)")
        case let ("recordings", path?):
            let before = try load().storage.recordingsPath
            let full = try prepare(path)
            _ = try edit { $0.storage.recordings = full }
            console.out("✓ recordings folder: \(full)")
            showFolder("recordings", full)
            if before != full, StorageLocation.status(of: before).isReady {
                console.out("Recording already made in \(before) stays there until retention removes it.")
            }
        case ("events", "same"?):
            _ = try edit { $0.storage.events = nil }
            console.out("✓ event clips will be kept inside the recordings folder")
        case let ("events", path?):
            let full = try prepare(path)
            _ = try edit { $0.storage.events = full }
            console.out("✓ events folder: \(full)")
            showFolder("events", full)
        case let ("database", path?):
            let full = NSString(string: path).expandingTildeInPath
            if full.hasPrefix("/Volumes/") {
                console.err("! \(full) is on another drive. SQLite on a NAS share is unreliable; the internal disk is safer.")
            }
            _ = try edit { $0.storage.database = full }
            console.out("✓ database: \(full)")
        case (let w?, nil) where ["recordings", "events", "database"].contains(w):
            throw UsageError("Give a folder: pond storage \(w) PATH")
        default:
            throw UsageError("Unknown storage setting \(which ?? ""). See: pond help")
        }
    }

    // MARK: - retention

    func retentionSummary(_ r: Config.Retention) -> String {
        let cap = r.continuous.maxSizeGB.map { ", at most \(Self.number($0)) GB" } ?? ""
        return "continuous recording: \(r.continuous.days) day\(r.continuous.days == 1 ? "" : "s")\(cap); "
            + "event clips: \(r.events.days) day\(r.events.days == 1 ? "" : "s"); \(Self.number(r.minFreeGB)) GB kept free"
    }

    func retentionCommand(_ args: inout Args) throws {
        let which = args.next()
        let value = args.next()
        try args.done()
        let config: Config
        switch which {
        case nil:
            config = try load()
            let r = config.retention
            console.out("continuous recording   \(r.continuous.days) days")
            console.out("  size cap             \(r.continuous.maxSizeGB.map { "\(Self.number($0)) GB" } ?? "none")")
            console.out("event clips            \(r.events.days) days")
            console.out("free space kept        \(Self.number(r.minFreeGB)) GB (below it, the oldest continuous recording is overwritten)")
            return
        case "continuous":
            let days = try Self.positiveInt(value, "days")
            config = try edit { $0.retention.continuous.days = days }
        case "max-size":
            guard let value else { throw UsageError("Give a size in GB, or none.") }
            if value == "none" {
                config = try edit { $0.retention.continuous.maxSizeGB = nil }
            } else {
                let gb = try Self.nonNegative(value, "a size in GB, or none")
                guard gb > 0 else { throw UsageError("The size cap must be more than 0 GB, or none.") }
                config = try edit { $0.retention.continuous.maxSizeGB = gb }
            }
        case "events":
            let days = try Self.positiveInt(value, "days")
            config = try edit { $0.retention.events.days = days }
        case "reserve":
            let gb = try Self.nonNegative(value, "the free space to keep, in GB")
            config = try edit { $0.retention.minFreeGB = gb }
        case let other?:
            throw UsageError("Unknown retention setting \(other). See: pond help")
        }
        console.out("✓ " + retentionSummary(config.retention))
    }
}
