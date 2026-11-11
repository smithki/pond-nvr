import Control
import Foundation
import Ingest
import PondCore
import Recorder
import Foundation
import Testing
@testable import PondCLI

@Suite struct CameraCommandTests {
    func added(_ prober: FakeProber = FakeProber()) throws -> Harness {
        let h = try Harness(prober: prober)
        h.console.input = "s3cret\n"
        #expect(h.run("camera", "add", "porch", "--host", "192.168.1.41", "--name", "Front porch", "--password-stdin") == 0)
        return h
    }

    @Test func addChecksTheCameraThenSaves() throws {
        let h = try added()
        let camera = try #require(try h.config.cameras.first)
        #expect(camera == Config.Camera.reolink(id: "porch", name: "Front porch", host: "192.168.1.41", username: "admin"))
        #expect(h.credentials.password(for: "porch") == "s3cret")
        #expect(h.prober.calls.count == 1)
        #expect(h.prober.calls[0].password == "s3cret")
        #expect(h.prober.calls[0].seconds == 6)
        #expect(h.console.lines == [
            "… checking 192.168.1.41 (logging in, then watching the video for 6 s)",
            "✓ main stream: H.264 High 5.1, 2560×1440, AAC-LC 16 kHz mono",
            "✓ sub-stream: H.264 (resolution not announced)",
            "✓ video arriving: 20.0 fps, a keyframe every 2.0 s, 2.7 Mbit/s",
            "✓ password saved in the Keychain",
            "Camera porch added.",
        ])
    }

    @Test func wrongPasswordAddsNothing() throws {
        let h = try Harness(prober: FakeProber(.failure(.unauthorized)))
        h.console.input = "wrong"
        #expect(h.run("camera", "add", "porch", "--host", "192.168.1.41", "--password-stdin") == 1)
        #expect(h.console.errors == [
            "✗ The camera refused the username admin or the password.",
            "✗ Camera porch was not added. To add it anyway, while it is offline: --no-test",
        ])
        #expect(try h.config.cameras == [])
        #expect(h.credentials.password(for: "porch") == nil)
    }

    @Test func offlineCameraCanBeAddedWithoutTheTest() throws {
        let h = try Harness(prober: FakeProber(.failure(.transport(.unreachable("192.168.1.99:554 did not answer: no answer within 5 s")))))
        h.console.input = "pw"
        #expect(h.run("camera", "add", "garage", "--host", "192.168.1.99", "--password-stdin") == 1)
        #expect(h.console.errors.first == "✗ Nothing answered at 192.168.1.99.")
        h.console.input = "pw"
        #expect(h.run("camera", "add", "garage", "--host", "192.168.1.99", "--password-stdin", "--no-test") == 0)
        #expect(h.prober.calls.count == 1)
        #expect(try h.config.cameras.map(\.id) == ["garage"])
    }

    @Test func privacyModeIsAWarningNotAFailure() throws {
        var report = FakeProber.good
        report.flow = .privacyMode
        let h = try added(FakeProber(.success(report)))
        #expect(h.console.errors == ["! No video: the camera is in privacy mode. Turn privacy mode off in the camera’s own app."])
        #expect(try h.config.cameras.count == 1)
    }

    @Test func slowKeyframesAndH265AreWarned() throws {
        var report = FakeProber.good
        report.main.videoCodec = "H.265"
        report.main.sps = nil
        report.flow = .flowing(FlowStats(videoPackets: 10, videoBytes: 10, seconds: 8, firstVideoAfter: 1, fps: 15,
                                         keyframeInterval: 8, keyframes: 2, sps: nil))
        let h = try added(FakeProber(.success(report)))
        #expect(h.console.errors.count == 2)
        #expect(h.console.errors[0].hasPrefix("! The main stream is H.265."))
        #expect(h.console.errors[1].hasPrefix("! Keyframes are 8.0 s apart."))
    }

    @Test func addRefusesBadOrDuplicateIDsAndAsksForAPassword() throws {
        let h = try added()
        h.console.input = "x"
        #expect(h.run("camera", "add", "porch", "--host", "192.168.1.42", "--password-stdin") == 1)
        #expect(h.console.errors.last == "✗ There is already a camera porch.")
        #expect(h.run("camera", "add", "Porch", "--host", "1.2.3.4") == 2)
        #expect(h.run("camera", "add", "side") == 2)
        // No terminal and no --password-stdin.
        #expect(h.run("camera", "add", "side", "--host", "192.168.1.42") == 2)
        #expect(h.console.errors.last == "✗ No terminal to ask for the password. Pass it with --password-stdin.")
        // At a terminal, it asks.
        h.console.interactive = true
        h.console.secret = "typed"
        #expect(h.run("camera", "add", "side", "--host", "192.168.1.42") == 0)
        #expect(h.credentials.password(for: "side") == "typed")
    }

    @Test func setChangesHostInBothAddresses() throws {
        let h = try added()
        #expect(h.run("camera", "set", "porch", "--host", "192.168.1.77", "--name", "Porch") == 0)
        let c = try #require(try h.config.cameras.first)
        #expect(c.main == "rtsp://192.168.1.77:554/h264Preview_01_main")
        #expect(c.sub == "rtsp://192.168.1.77:554/h264Preview_01_sub")
        #expect(c.name == "Porch")
        #expect(h.console.lines.last == "Check the new settings with: pond camera test porch")
        #expect(h.run("camera", "set", "porch") == 2)
        #expect(h.run("camera", "set", "porch", "--host", "a", "--main", "rtsp://b/x") == 2)
        // A login in an address is refused and nothing is saved.
        #expect(h.run("camera", "set", "porch", "--main", "rtsp://admin:pw@192.168.1.77/x") == 1)
        #expect(try h.config.cameras.first?.main == "rtsp://192.168.1.77:554/h264Preview_01_main")
    }

    @Test func passwordIsTestedBeforeSaving() throws {
        let h = try added()
        h.prober.result = .failure(.unauthorized)
        h.console.input = "new-but-wrong"
        #expect(h.run("camera", "password", "porch", "--password-stdin") == 1)
        #expect(h.credentials.password(for: "porch") == "s3cret")
        h.prober.result = .success(FakeProber.good)
        h.console.input = "new"
        #expect(h.run("camera", "password", "porch", "--password-stdin") == 0)
        #expect(h.credentials.password(for: "porch") == "new")
        #expect(h.prober.calls.last?.seconds == 0)   // login only, no video watching
    }

    @Test func testUsesTheKeychainPassword() throws {
        let h = try added()
        #expect(h.run("camera", "test", "porch", "--seconds", "3") == 0)
        #expect(h.prober.calls.last?.password == "s3cret")
        #expect(h.prober.calls.last?.seconds == 3)
        h.credentials.removePassword(for: "porch")
        #expect(h.run("camera", "test", "porch") == 1)
        #expect(h.console.errors.last == "✗ Camera porch has no password in the Keychain. Set it with: pond camera password porch")
        #expect(h.run("camera", "test", "nope") == 1)
        #expect(h.run("camera", "test", "porch", "--seconds", "999") == 2)
    }

    @Test func theAppsWayIn() throws {
        // The app has pond keep passwords: the Keychain item alone, moved or removed; checks as JSON.
        let h = try added()
        #expect(h.run("camera", "password", "porch", "--move-to", "yard") == 0)
        #expect(h.credentials.password(for: "yard") == "s3cret")
        #expect(h.credentials.password(for: "porch") == nil)
        #expect(h.run("camera", "password", "yard", "--move-to", "porch") == 0)
        h.prober.result = .success(FakeProber.good)
        #expect(h.run("camera", "test", "porch", "--json", "--seconds", "2", "--main", "rtsp://10.0.0.9:554/main") == 0)
        #expect(h.prober.calls.last?.main == "rtsp://10.0.0.9:554/main")
        let json = try #require(h.console.lines.last)
        let outcome = try JSONDecoder().decode(ProbeOutcome.self, from: Data(json.utf8))
        #expect(outcome.report == FakeProber.good)
        #expect(h.run("camera", "password", "porch", "--remove") == 0)
        #expect(h.credentials.password(for: "porch") == nil)
    }

    @Test func renameMovesThePassword() throws {
        let h = try added()
        #expect(h.run("camera", "rename", "porch", "front-porch") == 0)
        #expect(try h.config.cameras.map(\.id) == ["front-porch"])
        #expect(h.credentials.password(for: "front-porch") == "s3cret")
        #expect(h.credentials.password(for: "porch") == nil)
        #expect(h.run("camera", "rename", "front-porch", "Bad ID") == 2)
    }

    @Test func moveChangesTheOrder() throws {
        let h = try added()
        h.console.input = "s3cret\n"
        #expect(h.run("camera", "add", "drive", "--host", "192.168.1.42", "--password-stdin") == 0)
        #expect(h.run("camera", "move", "drive", "top") == 0)
        #expect(try h.config.cameras.map(\.id) == ["drive", "porch"])
        #expect(h.console.lines.last == "✓ order: drive, porch")
        #expect(h.run("camera", "move", "drive", "2") == 0)
        #expect(try h.config.cameras.map(\.id) == ["porch", "drive"])
        #expect(h.run("camera", "move", "drive", "0") == 2)
        #expect(h.run("camera", "move", "none", "top") == 1)
    }

    @Test func removeCanDeleteRecordings() throws {
        let h = try added()
        let root = try h.config.storage.recordingsPath
        let file = "\(root)/continuous/porch/2026-01-01/00-00-00.mp4"
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file, contents: Data([1]))
        #expect(h.run("camera", "remove", "porch", "--delete-recordings", "--yes") == 0)
        #expect(!FileManager.default.fileExists(atPath: "\(root)/continuous/porch"))
        #expect(h.console.lines.contains("✓ recordings and event clips deleted"))
    }

    @Test func removeConfirmsUnlessYes() throws {
        let h = try added()
        #expect(h.run("camera", "remove", "porch") == 2)   // no terminal, no --yes
        h.console.interactive = true
        h.console.answer = "no"
        #expect(h.run("camera", "remove", "porch") == 0)
        #expect(h.console.lines.last == "Nothing was changed.")
        #expect(try h.config.cameras.count == 1)
        h.console.answer = "remove"
        #expect(h.run("camera", "remove", "porch") == 0)
        #expect(try h.config.cameras == [])
        #expect(h.credentials.password(for: "porch") == nil)
    }

    @Test func listShowsMissingPasswords() throws {
        let h = try added()
        #expect(h.run("camera", "list") == 0)
        #expect(h.console.lines.last == "porch  Front porch  admin@192.168.1.41")
        h.credentials.removePassword(for: "porch")
        #expect(h.run("camera") == 0)
        #expect(h.console.lines.last == "porch  Front porch  admin@192.168.1.41  (no password in the Keychain)")
    }

    @Test func noKeychainOnThisSystem() throws {
        let h = try Harness()
        let cli = CLI(store: h.store, credentials: nil, prober: h.prober, console: h.console)
        #expect(cli.run(["camera", "add", "porch", "--host", "1.2.3.4"]) == 1)
        #expect(h.console.errors.last == "✗ Camera passwords are kept in the macOS Keychain, which is not available here.")
    }
}

final class FakeClips: ClipRecording {
    var calls: [(url: String, seconds: Double, path: String)] = []
    func record(url: String, username: String, password: String, seconds: Double, to path: String) throws(ClipError) -> ClipReport {
        calls.append((url, seconds, path))
        return ClipReport(seconds: seconds, bytes: 5_100_000, videoFrames: 241, audioFrames: 189, width: 2560, height: 1440,
                          lostPackets: 0, startWallTime: 0)
    }
}

@Suite struct RecordCommandTests {
    @Test func recordsTheMainStream() throws {
        let h = try Harness()
        h.console.input = "pw"
        #expect(h.run("camera", "add", "porch", "--host", "192.168.1.41", "--password-stdin", "--no-test") == 0)
        let clips = FakeClips()
        let cli = CLI(store: h.store, credentials: h.credentials, prober: h.prober, clips: clips, console: h.console)
        #expect(cli.run(["camera", "record", "porch", "/tmp/x.mp4", "--seconds", "12"]) == 0)
        #expect(clips.calls.first?.url == "rtsp://192.168.1.41:554/h264Preview_01_main")
        #expect(clips.calls.first?.seconds == 12)
        #expect(h.console.lines.suffix(2) == ["✓ 12.0 s, 2560×1440, 241 video frames, 189 audio frames, 5.1 MB", "Recorded /tmp/x.mp4."])
        #expect(cli.run(["camera", "record", "porch"]) == 2)
        #expect(cli.run(["camera", "record", "porch", "/tmp/x.mp4", "--seconds", "0"]) == 2)
    }
}

final class FakeService: ServiceRunning {
    var runs: [(cameras: [String], passwords: [String: String], seconds: Double?)] = []
    func run(config: Config, passwords: [String: String], for seconds: Double?, log: EventLog) {
        runs.append((config.cameras.map(\.id), passwords, seconds))
    }
}

@Suite struct RunCommandTests {
    @Test func runsWithTheKeychainPasswords() throws {
        let h = try Harness()
        for (id, host) in [("porch", "192.168.1.41"), ("garage", "192.168.1.42")] {
            h.console.input = "pw-\(id)"
            #expect(h.run("camera", "add", id, "--host", host, "--password-stdin", "--no-test") == 0)
        }
        h.credentials.removePassword(for: "garage")
        let service = FakeService()
        let cli = CLI(store: h.store, credentials: h.credentials, prober: h.prober, service: service, console: h.console)
        #expect(cli.run(["run", "--for", "30"]) == 0)
        #expect(service.runs.first?.passwords == ["porch": "pw-porch"])
        #expect(service.runs.first?.seconds == 30)
        #expect(h.console.errors.last?.hasPrefix("! Camera garage has no password in the Keychain and will not record.") == true)
    }

    @Test func refusesWithoutCameras() throws {
        let h = try Harness()
        let service = FakeService()
        let cli = CLI(store: h.store, credentials: h.credentials, prober: h.prober, service: service, console: h.console)
        #expect(cli.run(["run"]) == 1)
        #expect(service.runs.isEmpty)
        #expect(cli.run(["run", "--for", "soon"]) == 2)
    }
}

final class FakeLaunchd: Launchd, @unchecked Sendable {
    var loaded: String?
    var calls: [String] = []
    var description = "gui/501/camera.pond.recorder = {\n\tstate = running\n\tpid = 4242\n\tlast exit code = (never exited)\n}"

    func bootstrap(plist: String) throws { calls.append("bootstrap"); loaded = plist }
    func bootout(label: String) throws { calls.append("bootout"); loaded = nil }
    func kickstart(label: String) throws { calls.append("kickstart") }
    func describe(label: String) -> String? { loaded == nil ? nil : description }
}

@Suite struct ServiceCommandTests {
    @Test func plistRunsThisProgramWithItsLog() {
        let plist = LaunchAgent.plist(program: "/usr/local/bin/pond", configPath: "/tmp/a&b.json")
        #expect(plist.contains("<string>camera.pond.recorder</string>"))
        #expect(plist.contains("<string>/usr/local/bin/pond</string>\n\t\t<string>run</string>\n\t\t<string>--log</string>"))
        #expect(plist.contains("<string>/tmp/a&amp;b.json</string>"))
        #expect(plist.contains("<key>KeepAlive</key>\n\t<true/>"))
        #expect(plist.contains("<key>RunAtLoad</key>\n\t<true/>"))
        #expect(!LaunchAgent.plist(program: "/usr/local/bin/pond", configPath: nil).contains("--config"))
        // It is a valid property list.
        let parsed = try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        #expect((parsed?["ProgramArguments"] as? [String])?.last == "/tmp/a&b.json")
    }

    @Test func statusReadsLaunchctl() {
        let s = LaunchAgent.summary(FakeLaunchd().description)
        #expect(s.state == "running")
        #expect(s.pid == "4242")
    }

    @Test func notInstalled() throws {
        let h = try Harness()
        let launchd = FakeLaunchd()
        let cli = CLI(store: h.store, credentials: h.credentials, prober: h.prober, launchd: launchd, console: h.console)
        #expect(cli.run(["service"]) == 0)
        #expect(h.console.lines.last == "The login service is not installed. Install it with: pond service install")
        #expect(cli.run(["service", "restart"]) == 1)
        #expect(cli.run(["service", "install"]) == 1)   // no cameras yet
        #expect(launchd.calls.isEmpty)
        #expect(cli.run(["service", "sideways"]) == 2)
    }

    @Test func installNeedsLaunchd() throws {
        let h = try Harness()
        h.console.input = "pw"
        #expect(h.run("camera", "add", "porch", "--host", "192.168.1.41", "--password-stdin", "--no-test") == 0)
        // Installing for real writes to ~/Library, which tests leave alone; here only the refusal is checked.
        let cli = CLI(store: h.store, credentials: h.credentials, prober: h.prober, launchd: nil,
                      executablePath: "/repo/pond/dist/pond", console: h.console)
        #expect(cli.run(["service", "install"]) == 1)
        #expect(h.console.errors.last == "✗ The login service needs macOS.")
    }

    @Test func withoutCamerasItRunsOnlyForRemoteAccess() throws {
        let h = try Harness()
        final class Ran: ServiceRunning, @unchecked Sendable {
            var ran = false
            func run(config: Config, passwords: [String: String], for seconds: Double?, log: EventLog) { ran = true }
        }
        // No cameras and nothing else: refused, saying how to give it something to do.
        let idle = Ran()
        var cli = CLI(store: h.store, credentials: h.credentials, prober: h.prober, service: idle, console: h.console)
        #expect(cli.run(["run", "--log", h.dir + "/pond.log"]) == 1)
        #expect(!idle.ran)
        #expect(h.console.errors.last?.contains("remote.enabled") == true)
        // A Mac that only watches another Pond's cameras: remote access on, no cameras of its own.
        var config = try h.store.load()
        config.remote = Config.Remote(enabled: true, signaling: "wss://signal.example.com")
        try h.store.save(config)
        let watching = Ran()
        cli = CLI(store: h.store, credentials: h.credentials, prober: h.prober, service: watching, console: h.console)
        #expect(cli.run(["run", "--log", h.dir + "/pond.log"]) == 0, "\(h.console.errors)")
        #expect(watching.ran)
    }

    @Test func runWritesToALogFile() throws {
        let h = try Harness()
        h.console.input = "pw"
        #expect(h.run("camera", "add", "porch", "--host", "192.168.1.41", "--password-stdin", "--no-test") == 0)
        final class LoggingService: ServiceRunning {
            func run(config: Config, passwords: [String: String], for seconds: Double?, log: EventLog) {
                log.log("pond", "hello")
            }
        }
        let cli = CLI(store: h.store, credentials: h.credentials, prober: h.prober, service: LoggingService(), console: h.console)
        let logPath = h.dir + "/logs/pond.log"
        #expect(cli.run(["run", "--log", logPath]) == 0)
        let text = try String(contentsOfFile: logPath, encoding: .utf8)
        #expect(text.hasSuffix(" pond: hello\n"))
    }
}

@Suite struct FileLogTests {
    @Test func rotatesAtTheLimit() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pond-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = try FileLog(path: dir + "/pond.log", maxBytes: 200)
        for n in 0 ..< 10 { log.log("cam", "line \(n)") }   // about 35 bytes each
        let current = try String(contentsOfFile: dir + "/pond.log", encoding: .utf8)
        let old = try String(contentsOfFile: dir + "/pond.log.1", encoding: .utf8)
        #expect(current.contains("line 9"))
        #expect(old.contains("line 4") || old.contains("line 5"))
        #expect(!current.contains("line 0"))
        #expect(current.utf8.count <= 200)
    }
}

@Suite struct PlainErrorTests {
    @Test func onlyWhatTheErrorSays() {
        #expect(CameraCheck.plain(.transport(.unreachable("x")), host: "h") == ("Nothing answered at h.", .address))
        #expect(CameraCheck.plain(.unauthorized, host: "h").fix == .password)
        // No cause is known for these, so none is suggested.
        for error: RTSPError in [.timeout("DESCRIBE"), .status(500, "Internal"), .malformed("x"), .transport(.closed)] {
            let (text, fix) = CameraCheck.plain(error, host: "h")
            #expect(fix == .unexplained)
            #expect(!text.contains("DESCRIBE") && !text.contains("500") && !text.contains("rtsp"))
        }
    }
}

@Suite struct CameraAddStreamTests {
    @Test func addAsksTheCameraForItsStreams() throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(atPath: h.dir) }
        h.console.input = "s3cret\n"
        h.findStreams = { host, _, _ in ("rtsp://\(host):554/stream1", "rtsp://\(host):554/stream2", "ONVIF") }
        #expect(h.run("camera", "add", "garden", "--host", "192.168.1.30", "--password-stdin") == 0)
        let camera = try #require(try h.config.cameras.first)
        #expect(camera.main == "rtsp://192.168.1.30:554/stream1" && camera.sub == "rtsp://192.168.1.30:554/stream2")
        #expect(h.console.lines.contains("✓ stream addresses from ONVIF"))
    }

    @Test func givenAddressesAreKeptAndNothingIsAsked() throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(atPath: h.dir) }
        h.console.input = "s3cret\n"
        h.findStreams = { _, _, _ in Issue.record("asked anyway"); return nil }
        #expect(h.run("camera", "add", "garden", "--host", "192.168.1.30", "--main", "rtsp://192.168.1.30/a",
                      "--sub", "rtsp://192.168.1.30/b", "--password-stdin") == 0)
        let camera = try #require(try h.config.cameras.first)
        #expect(camera.main == "rtsp://192.168.1.30/a" && camera.sub == "rtsp://192.168.1.30/b")
    }

    @Test func aCameraThatDoesntSayGetsReolinksAddresses() throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(atPath: h.dir) }
        h.console.input = "s3cret\n"
        h.findStreams = { _, _, _ in nil }
        #expect(h.run("camera", "add", "porch", "--host", "192.168.1.20", "--password-stdin") == 0)
        #expect(try h.config.cameras.first?.main == "rtsp://192.168.1.20:554/h264Preview_01_main")
    }
}
