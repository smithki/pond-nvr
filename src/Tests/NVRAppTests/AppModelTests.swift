import Control
import CoreMedia
import Foundation
import Ingest
import NVRCore
import Testing
@testable import NVRApp

final class StubProber: CameraProber, @unchecked Sendable {
    var result: Result<ProbeReport, RTSPError>
    init(_ result: Result<ProbeReport, RTSPError>) { self.result = result }
    func probe(main: String, sub: String?, username: String, password: String, watchSeconds: Double) throws(RTSPError) -> ProbeReport {
        try result.get()
    }
}

final class StubLaunchd: Launchd, @unchecked Sendable {
    var running = false
    func bootstrap(plist: String) throws { running = true }
    func bootout(label: String) throws { running = false }
    func kickstart(label: String) throws {}
    func describe(label: String) -> String? { running ? "state = running\npid = 7" : nil }
}

@MainActor
@Suite struct AppModelTests {
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pond-app-\(UUID().uuidString)")
    let credentials = MemoryCredentialStore()
    let launchd = StubLaunchd()

    func model(_ probe: Result<ProbeReport, RTSPError> = .failure(.unauthorized)) -> AppModel {
        let m = AppModel(store: ConfigStore(path: dir + "/config.json"), passwords: StorePasswordKeeper(store: credentials, probe: { _ in probe }), prober: StubProber(probe),
                         service: ServiceControl(launchd: launchd), helperPath: "/Applications/Pond.app/Contents/MacOS/pond")
        m.localNetworkAccess = { _, _, _ in .allowed }
        return m
    }

    @Test func slugsFromNames() {
        #expect(slug("Front porch") == "front-porch")
        #expect(slug("  Garage (side) ") == "garage-side")
        #expect(slug("2nd floor") == "cam-2nd-floor")
        #expect(slug("Café") == "caf")
        #expect(Config.isSlug(slug("Back yard #2")))
    }

    @Test func startsWithoutSettingsThenCreatesThem() {
        let m = model()
        #expect(m.config == nil)
        #expect(m.loadError == nil)
        m.createSettings()
        #expect(m.config?.retention == Config.Retention())
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func invalidChangesAreNotSaved() throws {
        let m = model()
        m.createSettings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(m.update { $0.retention.continuous.days = 14 })
        #expect(try ConfigStore(path: dir + "/config.json").load().retention.continuous.days == 14)
        #expect(!m.update { $0.retention.continuous.days = 0 })
        #expect(m.alert == "retention.continuous.days must be at least 1.")
        #expect(m.config?.retention.continuous.days == 14)
    }

    @Test func addRenameRemoveKeepPasswordsInStep() {
        let m = model()
        m.createSettings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let camera = Config.Camera.reolink(id: "porch", name: "Porch", host: "192.168.1.41", username: "admin")
        #expect(m.add(camera, password: "pw"))
        #expect(credentials.password(for: "porch") == "pw")
        #expect(!m.add(camera, password: "other"))   // duplicate id
        #expect(credentials.password(for: "porch") == "pw")
        #expect(m.edit("porch", name: "Front porch", host: "192.168.1.77", username: "admin"))
        #expect(m.config?.cameras.first?.sub == "rtsp://192.168.1.77:554/h264Preview_01_sub")
        #expect(m.rename("porch", to: "front-porch"))
        #expect(credentials.password(for: "front-porch") == "pw")
        #expect(!m.rename("front-porch", to: "Bad Id"))
        m.remove("front-porch")
        #expect(m.config?.cameras == [])
        #expect(credentials.password(for: "front-porch") == nil)
    }

    @Test func listMovesKeepTheOrder() {
        let m = model()
        m.createSettings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for id in ["a", "b", "c", "d"] {
            #expect(m.add(Config.Camera.reolink(id: id, name: id, host: "192.168.1.1", username: "admin"), password: "pw"))
        }
        m.moveCamera("a", onto: "c")   // down: after it
        #expect(m.config?.cameras.map(\.id) == ["b", "c", "a", "d"])
        m.moveCamera("d", onto: "b")   // up: before it
        #expect(m.config?.cameras.map(\.id) == ["d", "b", "c", "a"])
    }

    @Test func backAndForwardBetweenViews() {
        let m = model()
        m.mode = .live
        m.mode = .timeline        // e.g. Latest, from a live tile
        m.mode = .events
        m.goBack()
        #expect(m.mode == .timeline)
        m.goBack()
        #expect(m.mode == .live)
        #expect(m.backHistory.isEmpty == false || m.backHistory == [])
        m.goForward()
        #expect(m.mode == .timeline)
        m.mode = .live            // a new move drops what was ahead
        #expect(m.forwardHistory.isEmpty)
        m.goBack()
        #expect(m.mode == .timeline)
    }

    @Test func checkReportsInPlainWords() async {
        let m = model(.failure(.unauthorized))
        let camera = Config.Camera.reolink(id: "porch", name: "Porch", host: "192.168.1.41", username: "admin")
        let r = await m.check(camera, password: "wrong", seconds: 0)
        #expect(!r.passed)
        #expect(r.lines == [CheckLine(.error, "The camera refused the username admin or the password.", fix: .password)])
    }

    @Test func savingWhileRecordingAsksForARestartOnlyForStorage() async {
        let m = model()
        m.createSettings()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(m.add(Config.Camera.reolink(id: "porch", name: "Porch", host: "192.168.1.41", username: "admin"), password: "pw"))
        await m.installService()?.value
        #expect(m.serviceState == .running(pid: "7"))
        #expect(!m.needsRestart)
        // The cameras and retention: taken up by a reload as they're saved, no restart asked.
        m.update { $0.retention.events.days = 60 }
        #expect(!m.needsRestart)
        m.update { $0.cameras[0].name = "Front" }
        #expect(!m.needsRestart)
        // The storage: only a restart takes it up.
        let database = m.config?.storage.database ?? ""
        m.update { $0.storage.database = dir + "/elsewhere/pond.sqlite" }
        #expect(m.needsRestart)
        // Changed back: the recorder has it already.
        m.update { $0.storage.database = database }
        #expect(!m.needsRestart)
        m.update { $0.storage.database = dir + "/elsewhere/pond.sqlite" }
        await m.restartService().value
        #expect(!m.needsRestart)
        await m.uninstallService().value
        #expect(m.serviceState == .notInstalled)
    }
}

@Suite struct LiveAudioTests {
    @Test func aacFormatFromTheCameraConfig() throws {
        // "1408": AAC-LC, 16 kHz, mono, as a Reolink describes its microphone.
        let format = try #require(AudioOutput.format(config: "1408"))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC)
        #expect(asbd.mSampleRate == 16000)
        #expect(asbd.mChannelsPerFrame == 1)
        #expect(asbd.mFramesPerPacket == 1024)
        var cookieSize = 0
        let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &cookieSize)
        #expect(cookie != nil && cookieSize == 2)
    }

    @Test func oneFrameIsOneSample() throws {
        let format = try #require(AudioOutput.format(config: "1408"))
        let sample = try #require(AudioOutput.sample([0x21, 0x10, 0x05], format: format, at: CMTime(value: 3, timescale: 2)))
        #expect(CMSampleBufferGetNumSamples(sample) == 1)
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 3, timescale: 2))
        #expect(CMSampleBufferGetTotalSampleSize(sample) == 3)
    }

    @Test func noFormatWithoutAConfig() {
        #expect(AudioOutput.format(config: nil) == nil)
        #expect(AudioOutput.format(config: "zz") == nil)
    }
}
