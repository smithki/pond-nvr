// pond camera ...: the list of cameras, their passwords in the Keychain, and checking them over the network.
import Control
import Foundation
import Ingest
import PondCore
import Recorder

extension CLI {
    func cameraCommand(_ args: inout Args) throws {
        switch args.next() {
        case nil, "list": try cameraList(&args)
        case "add": try cameraAdd(&args)
        case "set": try cameraSet(&args)
        case "password": try cameraPassword(&args)
        case "test": try cameraTest(&args)
        case "record": try cameraRecord(&args)
        case "rename": try cameraRename(&args)
        case "move": try cameraMove(&args)
        case "remove": try cameraRemove(&args)
        case let other?: throw UsageError("Unknown camera command \(other). See: pond help")
        }
    }

    func cameraList(_ args: inout Args) throws {
        try args.done()
        let config = try load()
        if config.cameras.isEmpty {
            console.out("No cameras yet. Add one with: pond camera add ID --host HOST")
            return
        }
        for c in config.cameras {
            let host = URLComponents(string: c.main)?.host ?? "?"
            var password = ""
            if let credentials {
                password = (try? credentials.password(for: c.id)) == nil ? "  (no password in the Keychain)" : ""
            }
            let zones = c.zones.isEmpty ? "" : "  \(c.zones.count) zone\(c.zones.count == 1 ? "" : "s")"
            console.out("\(c.id)  \(c.name)  \(c.username)@\(host)\(zones)\(password)")
        }
    }

    func camera(_ id: String?, in config: Config) throws -> Config.Camera {
        guard let id else { throw UsageError("Give the camera's ID. See: pond camera list") }
        guard let camera = config.cameras.first(where: { $0.id == id }) else {
            console.err("✗ There is no camera \(id). See: pond camera list")
            throw Failure()
        }
        return camera
    }

    /// The password from standard input (--password-stdin) or a prompt.
    func readPassword(_ args: inout Args, for id: String) throws -> String {
        if args.flag("--password-stdin") {
            guard let text = console.readAllInput() else { throw UsageError("No password on standard input.") }
            var password = text
            while password.hasSuffix("\n") || password.hasSuffix("\r") { password.removeLast() }
            guard !password.isEmpty else { throw UsageError("The password on standard input is empty.") }
            return password
        }
        guard console.interactive else {
            throw UsageError("No terminal to ask for the password. Pass it with --password-stdin.")
        }
        guard let password = console.readSecret("Password for camera \(id): "), !password.isEmpty else {
            throw UsageError("No password given; nothing was changed.")
        }
        return password
    }

    /// Logs in to the camera and reports what it sends. Returns false (after explaining) if the login or the
    /// connection failed; warnings alone still return true.
    @discardableResult
    func probe(_ camera: Config.Camera, password: String, watch seconds: Double) -> Bool {
        let host = URLComponents(string: camera.main)?.host ?? camera.main
        if seconds > 0 { console.out("… checking \(host) (logging in, then watching the video for \(Self.number(seconds)) s)") }
        let result: Result<ProbeReport, RTSPError>
        do {
            result = .success(try prober.probe(main: camera.main, sub: camera.sub, username: camera.username,
                                               password: password, watchSeconds: seconds))
        } catch {
            result = .failure(error)
        }
        let (lines, passed) = CameraCheck.lines(result, host: host, username: camera.username, watchedSeconds: seconds)
        for line in lines {
            if line.kind == .ok { console.out(line.console) } else { console.err(line.console) }
        }
        return passed
    }

    func cameraAdd(_ args: inout Args) throws {
        guard let id = args.next() else { throw UsageError("Give the new camera an ID, e.g. pond camera add porch --host 192.168.1.30") }
        guard let host = try args.option("--host") else { throw UsageError("Give the camera's address with --host.") }
        let name = try args.option("--name") ?? id
        let username = try args.option("--username") ?? "admin"
        let givenMain = try args.option("--main")
        let givenSub = try args.option("--sub")
        let skipTest = args.flag("--no-test")
        guard Config.isSlug(id) else {
            throw UsageError("The ID must be lowercase letters, digits and dashes, starting with a letter.")
        }
        let credentials = try requireCredentials()
        let config = try load()
        if config.cameras.contains(where: { $0.id == id }) {
            console.err("✗ There is already a camera \(id).")
            throw Failure()
        }
        var camera = Config.Camera.reolink(id: id, name: name, host: host, username: username)
        if let givenMain { camera.main = givenMain }
        if let givenSub { camera.sub = givenSub }
        var check = config
        check.cameras.append(camera)
        let problems = check.problems()
        guard problems.isEmpty else {
            for p in problems { console.err("✗ \(p)") }
            throw Failure()
        }
        let password = try readPassword(&args, for: id)
        try args.done()
        // The stream addresses, unless given: asked of the camera (its brand's, or ONVIF's), else Reolink's.
        if givenMain == nil, givenSub == nil, !skipTest, let findStreams {
            console.out("… asking \(host) for its stream addresses")
            if let found = findStreams(host, username, password) {
                camera.main = found.main
                camera.sub = found.sub
                console.out("✓ stream addresses from \(found.how)")
            } else {
                console.out("! \(host) didn't say where its streams are; trying Reolink's addresses (set others with --main and --sub)")
            }
        }
        if !skipTest {
            guard probe(camera, password: password, watch: 6) else {
                console.err("✗ Camera \(id) was not added. To add it anyway, while it is offline: --no-test")
                throw Failure()
            }
        }
        try credentials.setPassword(password, for: id)
        do {
            _ = try edit { $0.cameras.append(camera) }
        } catch {
            try? credentials.removePassword(for: id)
            throw error
        }
        console.out("✓ password saved in the Keychain")
        console.out("Camera \(id) added.")
    }

    func cameraSet(_ args: inout Args) throws {
        let id = args.next()
        let name = try args.option("--name")
        let host = try args.option("--host")
        let username = try args.option("--username")
        let main = try args.option("--main")
        let sub = try args.option("--sub")
        let kind = try args.option("--kind").map { text throws(UsageError) -> Config.Camera.Kind in
            guard let k = Config.Camera.Kind(rawValue: text) else { throw UsageError("--kind is camera or doorbell.") }
            return k
        }
        let homekit = try args.option("--homekit").map { text throws(UsageError) -> Bool in
            switch text {
            case "on": return true
            case "off": return false
            default: throw UsageError("--homekit is on or off.")
            }
        }
        let range = Config.Camera.homeKitViewerRange
        let viewers = try args.option("--homekit-viewers").map { text throws(UsageError) -> Int in
            guard let n = Int(text), range.contains(n) else {
                throw UsageError("--homekit-viewers is a number from \(range.lowerBound) to \(range.upperBound).")
            }
            return n
        }
        let video = try args.option("--homekit-video").map { text throws(UsageError) -> Config.Camera.HomeKitVideo in
            guard let v = Config.Camera.HomeKitVideo(rawValue: text) else { throw UsageError("--homekit-video is camera or reencoded.") }
            return v
        }
        let recording = try args.option("--homekit-recording").map { text throws(UsageError) -> Bool in
            switch text {
            case "on": return true
            case "off": return false
            default: throw UsageError("--homekit-recording is on or off.")
            }
        }
        let instant = try args.option("--instant-live").map { text throws(UsageError) -> Bool in
            switch text {
            case "on": return true
            case "off": return false
            default: throw UsageError("--instant-live is on or off.")
            }
        }
        try args.done()
        guard name != nil || host != nil || username != nil || main != nil || sub != nil || kind != nil || homekit != nil
            || viewers != nil || instant != nil || video != nil || recording != nil else {
            throw UsageError("Nothing to change. Give --name, --host, --username, --main, --sub, --kind, --homekit, --homekit-viewers, --homekit-video, --homekit-recording or --instant-live.")
        }
        if host != nil, main != nil || sub != nil {
            throw UsageError("Give --host, or --main and --sub, not both.")
        }
        let config = try load()
        let old = try camera(id, in: config)
        let updated = try edit { config in
            guard let i = config.cameras.firstIndex(where: { $0.id == old.id }) else { return }
            if let name { config.cameras[i].name = name }
            if let username { config.cameras[i].username = username }
            if let host {
                for keyPath in [\Config.Camera.main, \Config.Camera.sub] {
                    var parts = URLComponents(string: config.cameras[i][keyPath: keyPath])
                    parts?.host = host
                    if let url = parts?.string { config.cameras[i][keyPath: keyPath] = url }
                }
            }
            if let main { config.cameras[i].main = main }
            if let sub { config.cameras[i].sub = sub }
            if let kind { config.cameras[i].kind = kind }
            if let homekit { config.cameras[i].homekit = homekit }
            if let viewers { config.cameras[i].homekitViewers = viewers == Config.Camera.defaultHomeKitViewers ? nil : viewers }
            if let video { config.cameras[i].homekitVideo = video == .camera ? nil : video }
            if let recording { config.cameras[i].homekitRecording = recording ? true : nil }
            if let instant { config.cameras[i].instantLive = instant == config.cameras[i].homekit ? nil : instant }
        }
        let c = try camera(old.id, in: updated)
        console.out("✓ \(c.id): \(c.name), \(c.username), \(c.main)\(c.kind == .doorbell ? ", a doorbell" : "")\(c.homekit ? ", in HomeKit" : "")")
        if viewers != nil { console.out("Up to \(c.homeKitViewerSlots) at once in the Home app.") }
        if instant != nil { console.out(c.keepsLiveReady ? "Live views start at once (the sub-stream is kept open)." : "Live views connect when opened.") }
        if kind != nil || homekit != nil || viewers != nil || instant != nil || video != nil || recording != nil {
            console.out("The running service takes this up with: pond service reload")
        }
        if host != nil || username != nil || main != nil {
            console.out("Check the new settings with: pond camera test \(c.id)")
        }
    }

    func cameraPassword(_ args: inout Args) throws {
        let id = args.next()
        let skipTest = args.flag("--no-test")
        let credentials = try requireCredentials()
        // The Keychain item alone, whatever the settings say (the app changes those itself, and has pond keep
        // the passwords so that only pond reads them): --remove deletes it, --move-to gives it another ID.
        if args.flag("--remove") {
            guard let id else { throw UsageError("Give the camera's ID.") }
            try args.done()
            try credentials.removePassword(for: id)
            console.out("✓ password for \(id) removed from the Keychain")
            return
        }
        if let newID = try args.option("--move-to") {
            guard let id else { throw UsageError("Give the camera's ID.") }
            try args.done()
            guard Config.isSlug(newID) else { throw UsageError("The ID must be lowercase letters, digits and dashes, starting with a letter.") }
            try credentials.movePassword(from: id, to: newID)
            console.out("✓ password for \(id) is now \(newID)'s")
            return
        }
        let camera = try camera(id, in: try load())
        let password = try readPassword(&args, for: camera.id)
        try args.done()
        if !skipTest {
            guard probe(camera, password: password, watch: 0) else {
                console.err("✗ The password was not changed. To save it anyway: --no-test")
                throw Failure()
            }
        }
        try credentials.setPassword(password, for: camera.id)
        console.out("✓ password for \(camera.id) saved in the Keychain")
    }

    func cameraTest(_ args: inout Args) throws {
        let id = args.next()
        let seconds = try args.option("--seconds").map { text throws(UsageError) in
            guard let s = Double(text), s >= 0, s <= 120 else { throw UsageError("--seconds must be between 0 and 120.") }
            return s
        } ?? 8
        let json = args.flag("--json")
        // Settings not saved yet, tried with the saved password (the app's Check Connection while editing).
        let main = try args.option("--main"), sub = try args.option("--sub"), username = try args.option("--username")
        try args.done()
        let credentials = try requireCredentials()
        var camera = try camera(id, in: try load())
        if let main { camera.main = main }
        if let sub { camera.sub = sub }
        if let username { camera.username = username }
        guard let password = try credentials.password(for: camera.id) else {
            console.err("✗ Camera \(camera.id) has no password in the Keychain. Set it with: pond camera password \(camera.id)")
            throw Failure()
        }
        if json {
            // For the app: the report or the error, as data; the app words it.
            let result: Result<ProbeReport, RTSPError>
            do throws(RTSPError) {
                result = .success(try prober.probe(main: camera.main, sub: camera.sub, username: camera.username,
                                                   password: password, watchSeconds: seconds))
            } catch {
                result = .failure(error)
            }
            let data = (try? JSONEncoder().encode(ProbeOutcome(result))) ?? Data()
            console.out(String(decoding: data, as: UTF8.self))
            return
        }
        guard probe(camera, password: password, watch: seconds) else { throw Failure() }
    }

    func cameraRecord(_ args: inout Args) throws {
        let id = args.next()
        guard let file = args.next() else { throw UsageError("Give a file to record to: pond camera record ID FILE.mp4") }
        let seconds = try args.option("--seconds").map { text throws(UsageError) in
            guard let s = Double(text), s >= 1, s <= 600 else { throw UsageError("--seconds must be between 1 and 600.") }
            return s
        } ?? 10
        try args.done()
        let credentials = try requireCredentials()
        let camera = try camera(id, in: try load())
        guard let password = try credentials.password(for: camera.id) else {
            console.err("✗ Camera \(camera.id) has no password in the Keychain. Set it with: pond camera password \(camera.id)")
            throw Failure()
        }
        let path = NSString(string: file).expandingTildeInPath
        console.out("… recording \(Self.number(seconds)) s of \(camera.id) to \(path)")
        let report: ClipReport
        do {
            report = try clips.record(url: camera.main, username: camera.username, password: password,
                                      seconds: seconds, to: path)
        } catch {
            console.err("✗ \(camera.id): \(error.description).")
            throw Failure()
        }
        var line = String(format: "✓ %.1f s, %d×%d, %d video frames, %d audio frames, %.1f MB",
                          report.seconds, report.width, report.height, report.videoFrames, report.audioFrames,
                          Double(report.bytes) / 1e6)
        if report.lostPackets > 0 { line += ", \(report.lostPackets) packets lost" }
        console.out(line)
        console.out("Recorded \(path).")
    }

    func cameraRename(_ args: inout Args) throws {
        let id = args.next()
        guard let newID = args.next() else { throw UsageError("Give the new id: pond camera rename ID NEW-ID") }
        try args.done()
        guard Config.isSlug(newID) else {
            throw UsageError("The ID must be lowercase letters, digits and dashes, starting with a letter.")
        }
        let credentials = try requireCredentials()
        let config = try load()
        let old = try camera(id, in: config)
        guard old.id != newID else { console.out("Camera \(newID) already has that id."); return }
        if config.cameras.contains(where: { $0.id == newID }) {
            console.err("✗ There is already a camera \(newID).")
            throw Failure()
        }
        try credentials.movePassword(from: old.id, to: newID)
        do {
            _ = try edit { config in
                if let i = config.cameras.firstIndex(where: { $0.id == old.id }) { config.cameras[i].id = newID }
            }
        } catch {
            try? credentials.movePassword(from: newID, to: old.id)
            throw error
        }
        console.out("✓ password moved in the Keychain")
        console.out("Camera \(old.id) is now \(newID).")
    }

    /// Changes a camera's place in the order (its priority in the app): a position counted from 1, or top or
    /// bottom.
    func cameraMove(_ args: inout Args) throws {
        let id = args.next()
        guard let where_ = args.next() else { throw UsageError("Give the new position: pond camera move ID POSITION|top|bottom") }
        try args.done()
        let config = try load()
        let camera = try camera(id, in: config)
        let position: Int
        switch where_ {
        case "top": position = 0
        case "bottom": position = config.cameras.count - 1
        default:
            guard let n = Int(where_), n >= 1 else { throw UsageError("The position is a number from 1, or top or bottom.") }
            position = n - 1
        }
        let updated = try edit { $0.moveCamera(camera.id, to: position) }
        console.out("✓ order: " + updated.cameras.map(\.id).joined(separator: ", "))
    }

    func cameraRemove(_ args: inout Args) throws {
        let id = args.next()
        let yes = args.flag("--yes")
        let purge = args.flag("--delete-recordings")
        try args.done()
        let credentials = try requireCredentials()
        let config = try load()
        let camera = try camera(id, in: config)
        if !yes {
            guard console.interactive else {
                throw UsageError("Removing a camera needs --yes when there is no terminal to confirm.")
            }
            if purge {
                let gb = Double(CameraRecordings.size(of: camera.id, config: config)) / 1e9
                console.out("This removes camera \(camera.id) (\(camera.name)), its password, and its recordings and event clips (\(String(format: "%.1f", gb)) GB). They cannot be recovered.")
            } else {
                console.out("This removes camera \(camera.id) (\(camera.name)) and its password. Its recordings stay until retention deletes them.")
            }
            guard console.ask("Type remove to continue, anything else cancels: ") == "remove" else {
                console.out("Nothing was changed.")
                return
            }
        }
        _ = try edit { $0.cameras.removeAll { $0.id == camera.id } }
        try credentials.removePassword(for: camera.id)
        if purge {
            let failed = CameraRecordings.delete(of: camera.id, config: config)
            for folder in failed { console.err("! \(folder) could not be deleted.") }
            if failed.isEmpty { console.out("✓ recordings and event clips deleted") }
        }
        console.out("Camera \(camera.id) removed.")
    }
}
