import Foundation
import Testing
@testable import PondCore

@Suite struct ConfigTests {
    static let porch = Config.Camera(
        id: "porch", name: "Front porch",
        main: "rtsp://192.168.1.31:554/h264Preview_01_main",
        sub: "rtsp://192.168.1.31:554/h264Preview_01_sub",
        username: "admin",
        zones: [.init(id: "steps", name: "Steps", points: [[0.1, 0.5], [0.9, 0.5], [0.9, 1.0]])]
    )
    static let good = Config(storage: .init(recordings: "/Volumes/Pond/recordings", database: "~/pond.sqlite"),
                             cameras: [porch])

    @Test func aTestFeatureIsOnOnlyWithTheirSwitchOnToo() throws {
        let json = #"{"storage": {"recordings": "/r", "database": "/d"}, "testFeaturesOn": ["testScenes"]}"#
        var config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(!config.has(.testScenes))
        config.testFeatures = true
        #expect(config.has(.testScenes))
        config.testFeaturesOn = nil
        #expect(!config.has(.testScenes))
    }

    @Test func goodConfigHasNoProblems() {
        #expect(Self.good.problems() == [])
    }

    @Test func theSignalingServerIsAWebSocketAddress() {
        var config = Self.good
        for good in [nil, "", "wss://signal.example.com", "ws://192.0.2.1:8080"] {
            config.remote = .init(enabled: true, signaling: good)
            #expect(config.problems() == [], "\(good ?? "nil")")
        }
        for bad in ["signal.example.com", "https://signal.example.com", "wss://"] {
            config.remote = .init(enabled: true, signaling: bad)
            #expect(config.problems() == ["remote.signaling must be a wss:// address (ws:// only for testing)."], "\(bad)")
        }
    }

    @Test func aCameraCanBeRecordedFromItsSubStream() throws {
        var camera = try #require(Self.good.cameras.first)
        #expect(camera.recordedStream == camera.main)
        camera.recordsSub = true
        #expect(camera.recordedStream == camera.sub)
        // (One without a sub-stream: its main stream still.)
        camera.sub = ""
        #expect(camera.recordedStream == camera.main)
    }

    @Test func theMeshRangesAreRanges() {
        var config = Self.good
        config.remote = .init(enabled: true, mesh: true, meshSubnets: ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "10.8.0.0/24"])
        #expect(config.problems() == [])
        for bad in ["100.64.0.0", "100.64.0.0/33", "300.1.1.1/8", "fd7a::/129", "mesh/8", "fd7a::1::2/64"] {
            config.remote = .init(enabled: true, mesh: true, meshSubnets: [bad])
            #expect(config.problems().count == 1, "\(bad)")
        }
    }

    @Test func missingSectionsGetDefaults() throws {
        let json = #"{"storage": {"recordings": "/Volumes/Pond/recordings", "database": "/tmp/pond.sqlite"}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.version == 1)
        #expect(config.retention == Config.Retention())
        #expect(config.retention.continuous.days == 7)
        #expect(config.retention.continuous.maxSizeGB == nil)
        #expect(config.retention.events.days == 30)
        #expect(config.retention.minFreeGB == 25)
        #expect(config.cameras == [])
        #expect(config.storage.eventsPath == "/Volumes/Pond/recordings")
    }

    @Test func partialRetentionKeepsTheRestDefault() throws {
        let json = #"{"storage": {"recordings": "/r", "database": "/d"}, "retention": {"continuous": {"maxSizeGB": 1500}}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.retention.continuous == .init(days: 7, maxSizeGB: 1500))
        #expect(config.retention.events.days == 30)
    }

    @Test func separateEventsFolder() {
        var config = Self.good
        config.storage.events = "~/pond-events"
        #expect(config.storage.eventsPath.hasSuffix("/pond-events"))
        #expect(config.storage.eventsPath.hasPrefix("/"))
        #expect(config.problems() == [])
    }

    @Test func eventsMayBeKeptShorterThanContinuous() {
        var config = Self.good
        config.retention = .init(continuous: .init(days: 14), events: .init(days: 3))
        #expect(config.problems() == [])
    }

    @Test func passwordsInAddressesAreRefused() {
        var config = Self.good
        config.cameras[0].main = "rtsp://admin:secret@192.168.1.31/h264Preview_01_main"
        #expect(config.problems() == ["Camera porch: main must not contain a login; the username goes in username and the password in the Keychain."])
    }

    @Test func badValuesAreAllReported() {
        var config = Self.good
        config.version = 2
        config.storage.events = "relative/path"
        config.retention = .init(continuous: .init(days: 0, maxSizeGB: 0), events: .init(days: 0), minFreeGB: -1)
        config.cameras.append(Self.porch)
        config.cameras[1].sub = "http://192.168.1.31/sub"
        config.cameras[1].zones = [.init(id: "Steps", name: "Steps", points: [[0, 0], [2, 0]])]
        #expect(config.problems() == [
            "The settings were written by a newer pond (format 2); this one reads format 1.",
            "storage.events must be a full path (starting with / or ~).",
            "retention.continuous.days must be at least 1.",
            "retention.continuous.maxSizeGB must be more than 0, or left out for no limit.",
            "retention.events.days must be at least 1.",
            "retention.minFreeGB must not be negative.",
            "Camera porch: the ID is used by more than one camera.",
            "Camera porch: sub must be an rtsp:// address with a host.",
            "Camera porch, zone Steps: the ID must be lowercase letters, digits and dashes, starting with a letter.",
            "Camera porch, zone Steps: a zone needs at least 3 points.",
            "Camera porch, zone Steps: points must be between 0 and 1 (fractions of the frame).",
        ])
    }

    @Test func reolinkAddresses() {
        let camera = Config.Camera.reolink(id: "porch", name: "Porch", host: "192.168.1.41", username: "admin")
        #expect(camera.main == "rtsp://192.168.1.41:554/h264Preview_01_main")
        #expect(camera.sub == "rtsp://192.168.1.41:554/h264Preview_01_sub")
    }

    @Test func slugs() {
        #expect(Config.isSlug("front-porch2"))
        #expect(!Config.isSlug("2porch"))
        #expect(!Config.isSlug("Porch"))
        #expect(!Config.isSlug(""))
    }

    @Test func camerasMoveInOrder() {
        var config = Self.good
        for id in ["drive", "yard"] {
            var c = Self.porch
            c.id = id
            config.cameras.append(c)
        }
        config.moveCamera("yard", to: 0)
        #expect(config.cameras.map(\.id) == ["yard", "porch", "drive"])
        config.moveCamera("yard", to: 99)
        #expect(config.cameras.map(\.id) == ["porch", "drive", "yard"])
        config.moveCamera("drive", to: -3)
        #expect(config.cameras.map(\.id) == ["drive", "porch", "yard"])
        let movedMissing = config.moveCamera("none", to: 0)
        #expect(!movedMissing)
    }
}
