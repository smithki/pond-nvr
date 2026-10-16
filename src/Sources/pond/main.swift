// The `pond` command: the real terminal, Keychain and network, wired to the commands in NVRCLI.
import Control
import Foundation
import Ingest
import NVRCLI
import NVRCore
import Recorder
#if canImport(NVRMac)
import Devices
import HAP
import HAPCamera
import NVRMac
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class TerminalConsole: Console {
    func out(_ line: String) { print(line) }

    func err(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    var interactive: Bool { isatty(0) == 1 && isatty(1) == 1 }

    func readSecret(_ prompt: String) -> String? {
        guard interactive else { return nil }
        FileHandle.standardOutput.write(Data(prompt.utf8))
        var old = termios()
        tcgetattr(0, &old)
        var silent = old
        silent.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(0, TCSANOW, &silent)
        defer {
            tcsetattr(0, TCSANOW, &old)
            print("")
        }
        return readLine(strippingNewline: true)
    }

    func ask(_ prompt: String) -> String? {
        guard interactive else { return nil }
        FileHandle.standardOutput.write(Data(prompt.utf8))
        return readLine(strippingNewline: true)
    }

    func readAllInput() -> String? {
        String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
var configPath = ProcessInfo.processInfo.environment[Brand.configVariable] ?? ConfigStore.defaultPath
if let i = args.firstIndex(of: "--config") {
    guard i + 1 < args.count else {
        FileHandle.standardError.write(Data("✗ --config needs a file.\n".utf8))
        exit(2)
    }
    configPath = args[i + 1]
    args.removeSubrange(i ... i + 1)
}

#if canImport(NVRMac)
let credentials: CredentialStore? = KeychainCredentialStore()
let launchd: Launchd? = RealLaunchd()
#else
let credentials: CredentialStore? = nil
let launchd: Launchd? = nil
#endif

// The full path of this program, for the login service to run.
let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
#if canImport(NVRMac)
/// `pond run` (and so the login service) records and serves the cameras to HomeKit, over one connection per
/// camera stream (`StreamHub`).
struct RecordingAndHomeKit: ServiceRunning {
    /// Where the status for the app goes: next to the settings file.
    let statusPath: String

    func run(config: Config, passwords: [String: String], for seconds: Double?, log: EventLog) {
        let host = HomeKitHost(records: CredentialHomeKitRecords(store: KeychainCredentialStore(service: Brand.homeKitKeychainService))) {
            line in log.log("homekit", line)
        }
        // For the app: what HomeKit is doing, camera by camera.
        let statusPath = self.statusPath
        host.statusChanged = { $0.write(statusPath) }
        host.start(cameras: config.cameras) { passwords[$0] }
        for r in host.running where !r.record.isPaired {
            log.log("homekit", "\(r.camera.name) is not in the Home app yet; `pond homekit code` shows its setup code")
        }
        // The app's live views read the same camera connections, through a local socket.
        let cameras = config.cameras
        let relay = StreamRelayServer(path: StreamRelay.path(nextTo: statusPath), lookup: { url in
            guard let camera = cameras.first(where: { $0.main == url || $0.sub == url }),
                  let password = passwords[camera.id] else { return nil }
            return (camera.username, password)
        }) { line in log.log("pond", line) }
        relay.start()
        // Their controls (PTZ, night mode, talking back) too, through the connections the service keeps.
        let controls = ControlServer(path: ControlSocket.path(nextTo: statusPath), lookup: { id in
            guard let camera = cameras.first(where: { $0.id == id }), let password = passwords[camera.id] else { return nil }
            return (CameraAccess(host: camera.host, username: camera.username, password: password, mainStream: camera.main), camera.device)
        }) { line in log.log("pond", line) }
        controls.start()
        // Cameras set to start live view at once: their sub-stream held open, so a viewer joins it mid-way.
        let keepers = cameras.filter(\.keepsLiveReady).compactMap { camera in
            passwords[camera.id].map { StreamKeeper(url: camera.sub, username: camera.username, password: $0) }
        }
        for keeper in keepers { keeper.start() }
        RealService().run(config: config, passwords: passwords, for: seconds, log: log)
        for keeper in keepers { keeper.stop() }
        relay.stop()
        controls.stop()
        host.stop()
        // Logged out of the cameras (Reolink's allow only a few logins at once).
        let loggedOut = DispatchSemaphore(value: 0)
        Task.detached {
            await CameraSessions.shared.forgetAll()
            loggedOut.signal()
        }
        _ = loggedOut.wait(timeout: .now() + 5)
    }
}

/// Prints a camera's setup code and QR code for the Home app.
func printSetup(_ r: (camera: Config.Camera, record: HomeKitRecord)) {
    print("")
    if r.record.isPaired {
        print("\(r.camera.name): paired with \(r.record.pairings.count) controller(s).")
    } else {
        print("\(r.camera.name): add it in the Home app (+ › Add Accessory) with this code, or scan the QR code:")
        print("")
        print("    \(r.record.setupCode)")
        if let qr = TerminalQR.render(r.record.setup.uri(category: AccessoryCategory.ipCamera.rawValue)) { print(qr) }
    }
}

/// `pond migrate`: a setup from before the rename (nvr) carried over to Pond's names (see `Migration`).
if args == ["migrate"] {
    let migration = Migration(launchd: RealLaunchd(), keychain: { KeychainCredentialStore(service: $0) }) {
        try ServiceControl(launchd: RealLaunchd()).install(program: executable, configPath: nil)
        return executable
    }
    do throws(Migration.Failure) {
        try migration.run { print($0) }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("✗ \(error.description)\n".utf8))
        exit(1)
    }
}

/// `pond homekit`: the cameras as HomeKit accessories, in the foreground (for trying pairing; not while the
/// login service runs, which serves them itself); `pond homekit code` prints the setup codes for the service's
/// accessories; `pond homekit reset ID` forgets a camera's HomeKit identity and pairings, so it can be added
/// again.
/// `pond camera discover [--seconds N]`: the ONVIF cameras on the local network (WS-Discovery), each with
/// whether it is set up already. Needs no login.
if args.count >= 2, args[0] == "camera", args[1] == "discover" {
    let seconds = args.firstIndex(of: "--seconds").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 3
    let cameras = (try? ConfigStore(path: configPath).load())?.cameras ?? []
    // --trace (or --any, every device): ONVIF discovery's answers, each as it comes, first.
    if args.contains("--trace") || args.contains("--any") {
        let semaphore = DispatchSemaphore(value: 0)
        let printTrace: @Sendable (String) -> Void = { line in print("  … " + line) }
        let anyDevice = args.contains("--any")
        Task.detached {
            _ = await ONVIFDiscovery.probe(seconds: seconds, anyDevice: anyDevice, trace: printTrace)
            semaphore.signal()
        }
        semaphore.wait()
    }
    print("… looking for cameras on the local network (ONVIF and Reolink discovery, and cameras that take video connections)")
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var found: [FoundCamera] = []
    Task.detached {
        found = await CameraFinder.find(seconds: seconds)
        semaphore.signal()
    }
    semaphore.wait()
    if found.isEmpty {
        print("No camera found. A camera on another network (or VLAN) can't be seen from here; add it by its address.")
        exit(0)
    }
    for camera in found {
        let known = cameras.first { $0.host == camera.host }
        let how = [camera.maker.map { "\($0) discovery" }, camera.answersONVIF ? "ONVIF" : nil].compactMap { $0 }
        let what = camera.hardware.flatMap { $0 == camera.name ? nil : " (\($0))" } ?? ""
        let found = how.isEmpty ? "video port open" : how.joined(separator: ", ")
        print("\(known == nil ? "+" : "✓") \(camera.title)\(what) at \(camera.host), \(found)"
              + (known.map { ": set up as \($0.id)" } ?? ": not set up; add it with pond camera add ID --host \(camera.host)"))
    }
    exit(0)
}

/// `pond camera onvif ID`: what the camera says over ONVIF (where its service is, its clock, what it is, its
/// services and media profiles, and the stream addresses Pond would choose), for setting up a camera of a
/// make Pond doesn't know, and for reports of how a camera behaves. Changes nothing.
if args.count >= 3, args[0] == "camera", args[1] == "onvif" {
    let tracing = args.contains("--trace")
    // --events [SECONDS]: the camera's events as they come, for that long (60 s).
    let eventSeconds: Double? = args.firstIndex(of: "--events").map { i in
        i + 1 < args.count ? Double(args[i + 1]) ?? 60 : 60
    }
    guard let camera = (try? ConfigStore(path: configPath).load())?.cameras.first(where: { $0.id == args[2] }) else {
        FileHandle.standardError.write(Data("✗ There is no camera \(args[2]). See: pond camera list\n".utf8))
        exit(1)
    }
    guard let password = try? KeychainCredentialStore().password(for: camera.id) else {
        FileHandle.standardError.write(Data("✗ There is no password for \(camera.id) in the Keychain. Set it with: pond camera password \(camera.id)\n".utf8))
        exit(1)
    }
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var status: Int32 = 0
    Task.detached {
        defer { semaphore.signal() }
        guard let client = await ONVIFClient.connect(host: camera.host, username: camera.username, password: password) else {
            print("✗ Nothing answered ONVIF at \(camera.host) (ports \(ONVIFClient.ports.map(String.init).joined(separator: ", "))). Is ONVIF on in the camera's settings?")
            status = 1
            return
        }
        if tracing { client.trace = { print("  … \($0)") } }
        print("✓ ONVIF at \(client.deviceService.absoluteString)")
        print(client.clockOffset == 0 ? "✓ the camera's clock agrees with this Mac's"
              : String(format: "! the camera's clock is %+.0f s from this Mac's; logins allow for it", client.clockOffset))
        do throws(ONVIFClient.Failure) {
            let device = try await client.deviceInformation()
            print("✓ \([device.manufacturer, device.model].filter { !$0.isEmpty }.joined(separator: " ")), firmware \(device.firmware ?? "?")")
            let services = try await client.services()
            // "http://www.onvif.org/ver20/media/wsdl" as "media (ver20)".
            let named = services.keys.map { key -> String in
                let parts = key.split(separator: "/").map(String.init)
                return parts.count >= 3 ? "\(parts[parts.count - 2]) (\(parts[parts.count - 3]))" : key
            }
            print("✓ services: \(named.sorted().joined(separator: ", "))")
            guard let media = services[ONVIF.mediaNamespace] else {
                print("✗ The camera has no media service, so no stream addresses from it.")
                status = 1
                return
            }
            let profiles = try await client.profiles(media: media)
            for p in profiles {
                print("  profile \(p.token) (\(p.name)): \(p.encoding) \(p.width)×\(p.height)\(p.fps.map { " at \($0) fps" } ?? "")")
            }
            let streams = try await client.streams(media: media, media2: services[ONVIF.media2Namespace], profiles: profiles)
            print("✓ main stream: \(streams.main)")
            print("✓ sub-stream:  \(streams.sub)")
            if streams.main != camera.main || streams.sub != camera.sub {
                print("These differ from the camera's settings. To use them: pond camera set \(camera.id) --main \(streams.main) --sub \(streams.sub)")
            }
            if let eventSeconds {
                guard let events = services[ONVIF.eventsNamespace] else {
                    print("✗ The camera has no events service.")
                    status = 1
                    return
                }
                let subscription = try await client.subscribe(events: events)
                print("✓ subscribed to its events; watching for \(Int(eventSeconds)) s (walk past it, press its button)")
                var tracker = ONVIFEventTracker()
                let until = Date().addingTimeInterval(eventSeconds)
                while Date() < until {
                    let asked = Date()
                    let events = try await client.pull(subscription, seconds: max(1, min(10, Int(until.timeIntervalSinceNow))))
                    let received = Date()
                    for event in events {
                        let change = tracker.take(event)
                        let data = event.data.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                        let meaning = [change.motion.map { $0 ? "→ motion" : "→ still" }, change.pressed ? "→ pressed" : nil]
                            .compactMap { $0 }.joined(separator: " ")
                        // How long after it happened (the camera's clock, corrected) it arrived, and how long the pull
                        // had been waiting: a camera that holds events until the pull's timeout shows here.
                        let late = event.time.map { String(format: " · %.1f s after it happened", received.timeIntervalSince($0.addingTimeInterval(-client.clockOffset))) } ?? ""
                        let waited = String(format: " (pull answered after %.1f s)", received.timeIntervalSince(asked))
                        print("  \(event.operation.isEmpty ? "" : event.operation + " ")\(event.topic) \(data) \(meaning)\(event.operation == "Initialized" ? "" : late + waited)")
                    }
                }
                await client.unsubscribe(subscription)
            }
        } catch {
            print("✗ \(error.description)")
            status = 1
        }
    }
    semaphore.wait()
    exit(status)
}

/// `pond camera controls ID [--save]`: which way each of the camera's controls goes (PTZ, night mode,
/// talking back), as the service would choose; `--save` keeps them in its settings for the app.
/// `pond camera ptz ID presets | goto PRESET | move PAN TILT [ZOOM] [--for SECONDS] | stop` and
/// `pond camera night-mode ID [auto|day|night]` and `pond camera talk ID [--tone SECONDS]` (a quiet tone
/// through the camera's speaker): the controls themselves. `--via reolink|onvif` uses only that
/// provider, for trying each.
if args.count >= 3, args[0] == "camera", ["controls", "ptz", "night-mode", "talk"].contains(args[1]) {
    let store = ConfigStore(path: configPath)
    guard var config = try? store.load(), let index = config.cameras.firstIndex(where: { $0.id == args[2] }) else {
        FileHandle.standardError.write(Data("✗ There is no camera \(args[2]). See: pond camera list\n".utf8))
        exit(1)
    }
    let camera = config.cameras[index]
    guard let password = try? KeychainCredentialStore().password(for: camera.id) else {
        FileHandle.standardError.write(Data("✗ There is no password for \(camera.id) in the Keychain.\n".utf8))
        exit(1)
    }
    let access = CameraAccess(host: camera.host, username: camera.username, password: password, mainStream: camera.main)
    var providers = CameraProviders.order(for: camera.device)
    if let i = args.firstIndex(of: "--via"), i + 1 < args.count {
        providers = CameraProviders.all.filter { $0.id == args[i + 1] }
    }
    let controls = CameraControls(access: access, providers: providers)
    let command = args[1]
    // Through the service when it runs (it keeps the camera's logins; Reolink's allow only a few), unless a
    // provider is chosen.
    let service = ControlClient(path: ControlSocket.path(nextTo: configPath))
    let viaService = !args.contains("--via") && service.isAvailable
    // The words after the camera, without the options and their values.
    var rest: [String] = []
    var skip = false
    for word in args.dropFirst(3) {
        if skip { skip = false; continue }
        if ["--via", "--for", "--tone", "--delay"].contains(word) { skip = true; continue }
        if !word.hasPrefix("--") { rest.append(word) }
    }
    let saving = args.contains("--save")
    let delay = args.firstIndex(of: "--delay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 0
    let tone = args.firstIndex(of: "--tone").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 1
    let seconds = args.firstIndex(of: "--for").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 0.5
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var status: Int32 = 0
    nonisolated(unsafe) var found: Config.Controls?
    Task.detached {
        defer { semaphore.signal() }
        if viaService {
            print("· through the service")
            let id = camera.id
            func ask(_ request: ControlSocket.Request) async throws(ControlFailure) -> ControlSocket.Reply {
                let reply = await service.ask(request)
                if let error = reply.error { throw error }
                return reply
            }
            do throws(ControlFailure) {
                switch (command, rest.first ?? "") {
                case ("controls", _):
                    let all = try await ask(.init(camera: id, action: "controls")).controls ?? Config.Controls()
                    found = all
                    print("PTZ: \(all.ptz.map { "\($0.provider), pan/tilt \($0.panTilt), zoom \($0.zoom), \($0.presets) presets" } ?? "none")")
                    print("night mode: \(all.nightMode.map { "\($0.provider): \($0.choices.joined(separator: ", "))" } ?? "none")")
                    print("talking back: \(all.talk?.provider ?? "none")")
                case ("ptz", "presets"), ("ptz", ""):
                    for p in try await ask(.init(camera: id, action: "ptz.presets")).presets ?? [] { print("  \(p.id)  \(p.name)") }
                case ("ptz", "goto"):
                    _ = try await ask(.init(camera: id, action: "ptz.goto", preset: rest.count > 1 ? rest[1] : nil))
                    print("✓ going to \(rest.count > 1 ? rest[1] : "?")")
                case ("ptz", "move"):
                    let v = PTZVelocity(pan: rest.count > 1 ? Double(rest[1]) ?? 0 : 0, tilt: rest.count > 2 ? Double(rest[2]) ?? 0 : 0,
                                        zoom: rest.count > 3 ? Double(rest[3]) ?? 0 : 0)
                    _ = try await ask(.init(camera: id, action: "ptz.move", velocity: v))
                    try? await Task.sleep(for: .seconds(seconds))
                    _ = try await ask(.init(camera: id, action: "ptz.stop"))
                    print("✓ moved")
                case ("ptz", "stop"):
                    _ = try await ask(.init(camera: id, action: "ptz.stop"))
                    print("✓ stopped")
                case ("night-mode", ""):
                    print("night mode: \(try await ask(.init(camera: id, action: "night.get")).mode?.rawValue ?? "?")")
                case ("night-mode", let mode):
                    guard let m = NightMode(rawValue: mode) else { throw .failed("auto, day or night") }
                    _ = try await ask(.init(camera: id, action: "night.set", mode: m))
                    print("✓ night mode: \(m.rawValue)")
                case ("talk", _):
                    let talk = try await service.talk(camera: id)
                    print("✓ talking at \(Int(talk.sampleRate)) Hz; silence for \(delay) s, then a tone for \(tone) s")
                    let rate = talk.sampleRate, piece = Int(rate / 50)
                    var n = 0
                    let started = Date()
                    while Date().timeIntervalSince(started) < delay + tone {
                        let sounding = Date().timeIntervalSince(started) >= delay
                        try talk.send((0 ..< piece).map { i in sounding ? Int16(8000 * sin(2 * Double.pi * 440 * Double(n + i) / rate)) : 0 })
                        n += piece
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    talk.close()
                    print("✓ done")
                default:
                    throw .failed("presets, goto PRESET, move PAN TILT [ZOOM] [--for SECONDS] or stop")
                }
            } catch {
                print("✗ \(error.description)")
                status = 1
            }
            return
        }
        do throws(ControlFailure) {
            switch command {
            case "controls":
                let all = await controls.controls()
                found = all
                if let p = all.ptz {
                    print("✓ PTZ through \(p.provider): \([p.panTilt ? "pan and tilt" : nil, p.zoom ? "zoom" : nil].compactMap { $0 }.joined(separator: ", ")), \(p.presets) presets")
                } else { print("· no PTZ") }
                if let n = all.nightMode { print("✓ night mode through \(n.provider): \(n.choices.joined(separator: ", "))") } else { print("· no night mode") }
                if let t = all.talk { print("✓ talking back through \(t.provider)") } else { print("· no talking back") }
            case "ptz":
                switch rest.first ?? "presets" {
                case "presets":
                    let presets = try await controls.withPTZ { c throws(ControlFailure) in try await c.presets() }
                    for p in presets { print("  \(p.id)  \(p.name)") }
                    if presets.isEmpty { print("  (none)") }
                case "goto":
                    guard rest.count >= 2 else { throw .failed("which preset? pond camera ptz ID goto PRESET") }
                    try await controls.withPTZ { c throws(ControlFailure) in try await c.goTo(rest[1]) }
                    print("✓ going to \(rest[1])")
                case "move":
                    let v = PTZVelocity(pan: rest.count > 1 ? Double(rest[1]) ?? 0 : 0, tilt: rest.count > 2 ? Double(rest[2]) ?? 0 : 0,
                                        zoom: rest.count > 3 ? Double(rest[3]) ?? 0 : 0)
                    let started = Date()
                    try await controls.withPTZ { c throws(ControlFailure) in try await c.move(v) }
                    try? await Task.sleep(for: .seconds(seconds))
                    try await controls.withPTZ { c throws(ControlFailure) in try await c.stop() }
                    print(String(format: "✓ moved for %.2f s", Date().timeIntervalSince(started)))
                case "stop":
                    try await controls.withPTZ { c throws(ControlFailure) in try await c.stop() }
                    print("✓ stopped")
                default:
                    throw .failed("presets, goto PRESET, move PAN TILT [ZOOM] [--for SECONDS] or stop")
                }
            case "talk":
                let session = try await controls.withTalk { c throws(ControlFailure) in try await c.open() }
                print("✓ talking to \(camera.name) at \(Int(session.sampleRate)) Hz; silence for \(delay) s, then a tone for \(tone) s")
                // Silence first (--delay: some cameras take a moment to start their speaker), then 440 Hz, in
                // 20 ms pieces as a microphone would give them.
                let rate = session.sampleRate, piece = Int(rate / 50)
                var n = 0
                let started = Date()
                while Date().timeIntervalSince(started) < delay + tone {
                    let sounding = Date().timeIntervalSince(started) >= delay
                    let samples = (0 ..< piece).map { i in sounding ? Int16(8000 * sin(2 * Double.pi * 440 * Double(n + i) / rate)) : 0 }
                    n += piece
                    try session.send(samples)
                    try? await Task.sleep(for: .milliseconds(20))
                }
                session.close()
                print("✓ done")
            default:
                if let mode = rest.first {
                    guard let m = NightMode(rawValue: mode) else { throw .failed("auto, day or night") }
                    try await controls.withNightMode { c throws(ControlFailure) in try await c.setNightMode(m) }
                    print("✓ night mode: \(m.rawValue)")
                } else {
                    let m = try await controls.withNightMode { c throws(ControlFailure) in try await c.nightMode() }
                    print("night mode: \(m.rawValue)")
                }
            }
        } catch {
            print("✗ \(error.description)")
            status = 1
        }
        // Logged out (a Reolink camera allows only a few logins at once).
        await CameraSessions.shared.forget(access)
    }
    semaphore.wait()
    if saving, let found {
        config.cameras[index].device?.controls = found.isEmpty ? nil : found
        do { try store.save(config) } catch {
            FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
            exit(1)
        }
        print("✓ kept in \(camera.name)\u{2019}s settings")
    }
    exit(status)
}

/// `pond camera reolink ID CMD [JSON]`: one command of Reolink's API, its reply as the camera writes it,
/// for working out what a camera wants (JSON is the command's param).
if args.count >= 4, args[0] == "camera", args[1] == "reolink" {
    guard let camera = (try? ConfigStore(path: configPath).load())?.cameras.first(where: { $0.id == args[2] }),
          let password = try? KeychainCredentialStore().password(for: camera.id) else {
        FileHandle.standardError.write(Data("✗ No such camera, or no password for it.\n".utf8))
        exit(1)
    }
    let param = args.count > 4 ? (try? JSONSerialization.jsonObject(with: Data(args[4].utf8))) as? [String: Any] ?? [:] : [:]
    nonisolated(unsafe) let sendable = param
    let (cmd, semaphore) = (args[3], DispatchSemaphore(value: 0))
    Task.detached {
        let api = ReolinkAPI(host: camera.host, username: camera.username, password: password)
        print(await api.raw(cmd, param: sendable))
        await api.logout()
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

/// `pond camera abilities ID`: what the camera says it can do, every way Pond asks (ONVIF's PTZ, audio out
/// and imaging, whether its RTSP offers ONVIF's audio backchannel, and Reolink's own API), written out in
/// full for working out what a camera supports. Read-only: nothing moves or changes.
if args.count >= 3, args[0] == "camera", args[1] == "abilities" {
    guard let camera = (try? ConfigStore(path: configPath).load())?.cameras.first(where: { $0.id == args[2] }) else {
        FileHandle.standardError.write(Data("✗ There is no camera \(args[2]). See: pond camera list\n".utf8))
        exit(1)
    }
    guard let password = try? KeychainCredentialStore().password(for: camera.id) else {
        FileHandle.standardError.write(Data("✗ There is no password for \(camera.id) in the Keychain.\n".utf8))
        exit(1)
    }
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        defer { semaphore.signal() }
        let tell: @Sendable (String) -> Void = { print($0) }
        print("== \(camera.id) at \(camera.host)")
        await CapabilityProbe.onvif(host: camera.host, username: camera.username, password: password, tell: tell)
        // The backchannel: a DESCRIBE that asks for it; a camera that offers it adds a track it receives
        // (a=sendonly from its side).
        do {
            let url = camera.main
            let parts = URLComponents(string: url)
            let transport = try SocketTransport(host: parts?.host ?? camera.host, port: parts?.port ?? 554, timeout: 6)
            let client = RTSPClient(transport: transport, username: camera.username, password: password, timeout: 6)
            let reply = try client.request("DESCRIBE", url, headers: [("Accept", "application/sdp"),
                                                                       ("Require", "www.onvif.org/ver20/backchannel")])
            print("✓ RTSP DESCRIBE with the backchannel asked for: \(reply.status) \(reply.reason)")
            print(reply.bodyText.split(whereSeparator: \.isNewline).map { "    " + $0 }.joined(separator: "\n"))
            transport.close()
        } catch {
            print("✗ RTSP DESCRIBE with the backchannel: \(error)")
        }
        await CapabilityProbe.reolink(host: camera.host, username: camera.username, password: password, tell: tell)
    }
    semaphore.wait()
    exit(0)
}

/// `pond camera identify ID`: asks the camera what it is (maker, model, serial number, firmware, doorbell or
/// not) and keeps the answer in its settings, for HomeKit and the app. `--provider reolink|onvif` asks only
/// that one.
if args.count >= 3, args[0] == "camera", args[1] == "identify" {
    var providers = CameraProviders.all
    // --provider video: talk to the camera only for its video from now on (no logins for its details or
    // events); its last-known details stay.
    if let i = args.firstIndex(of: "--provider"), i + 1 < args.count, args[i + 1] == Config.Device.videoOnly {
        let store = ConfigStore(path: configPath)
        guard var config = try? store.load(), let index = config.cameras.firstIndex(where: { $0.id == args[2] }) else {
            FileHandle.standardError.write(Data("✗ There is no camera \(args[2]). See: pond camera list\n".utf8))
            exit(1)
        }
        guard config.cameras[index].device != nil else {
            print("\(config.cameras[index].name) is video only already: it hasn't said what it is.")
            exit(0)
        }
        config.cameras[index].device?.provider = Config.Device.videoOnly
        do { try store.save(config) } catch {
            FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
            exit(1)
        }
        print("✓ \(config.cameras[index].name): video only; its motion and button aren't watched. The service picks this up when it restarts: pond service restart")
        exit(0)
    }
    if let i = args.firstIndex(of: "--provider") {
        guard i + 1 < args.count, let p = CameraProviders.provider(args[i + 1]) else {
            FileHandle.standardError.write(Data("✗ --provider takes one of: \((CameraProviders.all.map(\.id) + [Config.Device.videoOnly]).joined(separator: ", "))\n".utf8))
            exit(2)
        }
        providers = [p]
        args.removeSubrange(i ... i + 1)
    }
    let store = ConfigStore(path: configPath)
    guard var config = try? store.load(), let index = config.cameras.firstIndex(where: { $0.id == args[2] }) else {
        FileHandle.standardError.write(Data("✗ There is no camera \(args[2]). See: pond camera list\n".utf8))
        exit(1)
    }
    let camera = config.cameras[index]
    guard let password = try? KeychainCredentialStore().password(for: camera.id) else {
        FileHandle.standardError.write(Data("✗ There is no password for \(camera.id) in the Keychain. Set it with: pond camera password \(camera.id)\n".utf8))
        exit(1)
    }
    // Without --provider: the way it was chosen to be talked to is asked first, so asking again keeps it.
    if providers.count > 1, let chosen = camera.device?.provider, let first = CameraProviders.provider(chosen) {
        providers = [first] + providers.filter { $0.id != chosen }
    }
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var device: Config.Device?
    let service = ControlClient(path: ControlSocket.path(nextTo: configPath))
    Task.detached {
        device = await DeviceReader.read(host: camera.host, username: camera.username, password: password, providers: providers)
        // And what it can be controlled with, through which provider each (for the app's controls); through
        // the service when it runs (it keeps the logins), else asked here and logged out after.
        if var found = device {
            if service.isAvailable, camera.device?.provider == found.provider {
                found.controls = await service.ask(.init(camera: camera.id, action: "controls")).controls
            } else {
                let access = CameraAccess(host: camera.host, username: camera.username, password: password, mainStream: camera.main)
                let controls = await CameraControls(access: access, device: found).controls()
                found.controls = controls.isEmpty ? nil : controls
                await CameraSessions.shared.forget(access)
            }
            device = found
        }
        semaphore.signal()
    }
    semaphore.wait()
    guard let device else {
        print("\(camera.name) did not say what it is: no answer from \(providers.map(\.id).joined(separator: " or ")). It works as before, without these details.")
        exit(0)
    }
    config.cameras[index].device = device
    if device.isDoorbell { config.cameras[index].kind = .doorbell }
    do {
        try store.save(config)
    } catch {
        FileHandle.standardError.write(Data("✗ The settings could not be saved: \(error)\n".utf8))
        exit(1)
    }
    print("✓ \(camera.name): \([device.manufacturer, device.model].filter { !$0.isEmpty }.joined(separator: " "))\(device.isDoorbell ? ", a doorbell" : "")")
    if let serial = device.serial { print("  serial number \(serial)") }
    if let firmware = device.firmware { print("  firmware \(firmware)") }
    if let controls = device.controls {
        let words = [controls.ptz.map { "PTZ (\($0.provider))" }, controls.nightMode.map { "night mode (\($0.provider))" },
                     controls.talk.map { "talking back (\($0.provider))" }].compactMap { $0 }
        print("  controls: \(words.joined(separator: ", "))")
    }
    exit(0)
}

if args.first == "homekit" {
    setvbuf(stdout, nil, _IOLBF, 0)   // each line as it happens, also when logged to a file
    let records = CredentialHomeKitRecords(store: KeychainCredentialStore(service: Brand.homeKitKeychainService))
    if args.count == 4, args[1] == "snapshot" {
        // pond homekit snapshot ID FILE.jpg: what the Home app is sent.
        guard let camera = (try? ConfigStore(path: configPath).load())?.cameras.first(where: { $0.id == args[2] }),
              let password = try? KeychainCredentialStore().password(for: camera.id) else {
            FileHandle.standardError.write(Data("✗ No camera \(args[2]) with a password.\n".utf8))
            exit(1)
        }
        let started = Date()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var jpeg: [UInt8]?
        Task.detached {
            jpeg = await Snapshotter(url: camera.sub, username: camera.username, password: password).jpeg(width: 1280, height: 720)
            semaphore.signal()
        }
        semaphore.wait()
        guard let jpeg else {
            FileHandle.standardError.write(Data("✗ No snapshot from \(camera.name).\n".utf8))
            exit(1)
        }
        FileManager.default.createFile(atPath: args[3], contents: Data(jpeg))
        print(String(format: "✓ %d bytes in %.1f s: %@", jpeg.count, Date().timeIntervalSince(started), args[3]))
        exit(0)
    }
    if args.count == 2, args[1] == "code" {
        guard let config = try? ConfigStore(path: configPath).load() else {
            FileHandle.standardError.write(Data("✗ The settings cannot be read.\n".utf8))
            exit(1)
        }
        let host = HomeKitHost(records: records) { _ in }
        let cameras = config.cameras.filter(\.homekit)
        if cameras.isEmpty { print("No camera is set to be in HomeKit. Turn it on in the app, or: pond camera set ID --homekit on") }
        for camera in cameras { printSetup((camera, host.record(for: camera.id))) }
        print("")
        exit(0)
    }
    if args.count == 3, args[1] == "reset" {
        records.remove(for: args[2])
        print("HomeKit forgot \(args[2]); remove it from the Home app too if it is still there.")
        exit(0)
    }
    guard let config = try? ConfigStore(path: configPath).load(), !config.cameras.isEmpty else {
        FileHandle.standardError.write(Data("✗ No cameras in the settings. Add one first.\n".utf8))
        exit(1)
    }
    guard config.cameras.contains(where: \.homekit) else {
        FileHandle.standardError.write(Data("✗ No camera is set to be in HomeKit. Turn it on in the app, or: pond camera set ID --homekit on\n".utf8))
        exit(1)
    }
    let host = HomeKitHost(records: records) { line in print(line) }
    let keychain = KeychainCredentialStore()
    host.start(cameras: config.cameras) { id in try? keychain.password(for: id) }
    guard !host.running.isEmpty else {
        FileHandle.standardError.write(Data("✗ HomeKit could not start; see the lines above.\n".utf8))
        exit(1)
    }
    for r in host.running { printSetup((r.camera, r.record)) }
    print("")
    print("Running; Ctrl-C to stop.")
    signal(SIGINT) { _ in exit(0) }
    dispatchMain()
}
#endif

#if canImport(NVRMac)
let service: ServiceRunning = RecordingAndHomeKit(statusPath: HomeKitStatus.path(nextTo: configPath))
#else
let service: ServiceRunning = RealService()
#endif
#if canImport(NVRMac)
/// A camera's stream addresses, asked of it: its make's known ones (Reolink's API recognising it), else ONVIF's.
let findStreams: CLI.StreamFinding = { host, username, password in
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var found: (main: String, sub: String, how: String)?
    Task.detached {
        if let f = await CameraProviders.findStreams(host: host, username: username, password: password) {
            found = (f.main, f.sub, f.provider == "onvif" ? "ONVIF" : f.provider.capitalized)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return found
}
#else
let findStreams: CLI.StreamFinding? = nil
#endif
let cli = CLI(store: ConfigStore(path: configPath), credentials: credentials, prober: RTSPProber(),
              service: service, launchd: launchd, executablePath: executable, console: TerminalConsole(),
              findStreams: findStreams)
exit(cli.run(args))
