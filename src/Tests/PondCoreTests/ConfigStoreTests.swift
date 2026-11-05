import Foundation
import Testing
@testable import PondCore

@Suite struct ConfigStoreTests {
    @Test func saveThenLoadRoundTrips() throws {
        let dir = try TempDir()
        let store = ConfigStore(path: dir.file("sub/config.json"))
        #expect(!store.exists)
        var config = ConfigTests.good
        config.retention.continuous.maxSizeGB = 1500
        try store.save(config)
        #expect(try store.load() == config)
        let mode = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let text = try String(contentsOfFile: store.path, encoding: .utf8)
        #expect(text.contains(#""recordings" : "/Volumes/Pond/recordings""#))   // slashes not escaped
    }

    @Test func settingsWithProblemsAreNotSaved() throws {
        let dir = try TempDir()
        let store = ConfigStore(path: dir.file("config.json"))
        try store.save(ConfigTests.good)
        var bad = ConfigTests.good
        bad.retention.continuous.days = 0
        #expect(throws: ConfigStore.Error.invalidSettings(["retention.continuous.days must be at least 1."])) {
            try store.save(bad)
        }
        #expect(try store.load() == ConfigTests.good)   // the old file is untouched
    }

    @Test func loadNamesTheMissingField() throws {
        let dir = try TempDir()
        let path = dir.file("config.json")
        try Data(#"{"storage": {"recordings": "/r", "database": "/d"}, "cameras": [{"id": "a"}]}"#.utf8).write(to: URL(fileURLWithPath: path))
        #expect {
            try ConfigStore(path: path).load()
        } throws: { error in
            "\(error)".contains("cameras[0].name is missing")
        }
    }

    @Test func missingFileIsUnreadable() {
        #expect {
            try ConfigStore(path: "/nonexistent/config.json").load()
        } throws: { error in
            if case .unreadable = error as? ConfigStore.Error { true } else { false }
        }
    }
}
