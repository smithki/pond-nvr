import Foundation
import NVRCore
import Testing
@testable import NVRCLI

@Suite struct SettingsCommandTests {
    @Test func initWritesDefaultsAndRefusesToOverwrite() throws {
        let h = try Harness(initialise: false)
        #expect(h.run("init") == 0)
        let config = try h.config
        #expect(config.storage.recordings == "/Volumes/Pond/recordings")
        #expect(config.retention == Config.Retention())
        #expect(h.console.lines.last?.hasPrefix("Next: choose the recording folder") == true)
        #expect(h.run("init") == 1)
        #expect(h.console.errors.last?.contains("already exists; nothing was changed") == true)
    }

    @Test func initPreparesTheRecordingsFolder() throws {
        let h = try Harness()
        #expect(StorageLocation.status(of: h.dir + "/rec").isReady)
        #expect(try h.config.storage.recordings == h.dir + "/rec")
    }

    @Test func commandsWithoutSettingsSayHowToStart() throws {
        let h = try Harness(initialise: false)
        #expect(h.run("retention") == 1)
        #expect(h.console.errors == ["✗ There is no settings file at \(h.store.path). Create one with: pond init"])
    }

    @Test func storageFolders() throws {
        let h = try Harness()
        #expect(h.run("storage", "events", h.dir + "/events") == 0)
        #expect(try h.config.storage.events == h.dir + "/events")
        #expect(StorageLocation.status(of: h.dir + "/events").isReady)
        #expect(h.run("storage", "events", "same") == 0)
        #expect(try h.config.storage.events == nil)

        // Moving recordings to another folder mentions the old one.
        #expect(h.run("storage", "recordings", h.dir + "/rec2") == 0)
        #expect(h.console.lines.last == "Recording already made in \(h.dir)/rec stays there until retention removes it.")

        // An unmounted drive: the folder's parent is missing. Nothing changes.
        #expect(h.run("storage", "recordings", h.dir + "/unplugged/rec") == 1)
        #expect(h.console.errors.last == "✗ \(h.dir)/unplugged does not exist. Is the drive plugged in or the share mounted?")
        #expect(try h.config.storage.recordings == h.dir + "/rec2")

        #expect(h.run("storage", "recordings") == 2)
        #expect(h.run("storage", "nonsense", "x") == 2)
    }

    @Test func storageShowsMissingFolders() throws {
        let h = try Harness()
        try FileManager.default.removeItem(atPath: h.dir + "/rec")
        #expect(h.run("storage") == 0)
        #expect(h.console.errors == ["✗ The recordings folder \(h.dir)/rec is not found: plug in the drive or mount the share."])
        #expect(h.run("check") == 1)
    }

    @Test func retention() throws {
        let h = try Harness()
        #expect(h.run("retention", "continuous", "14") == 0)
        #expect(h.run("retention", "max-size", "1500") == 0)
        #expect(h.run("retention", "events", "60") == 0)
        #expect(h.run("retention", "reserve", "50") == 0)
        #expect(h.console.lines.last == "✓ continuous recording: 14 days, at most 1500 GB; event clips: 60 days; 50 GB kept free")
        #expect(try h.config.retention == .init(continuous: .init(days: 14, maxSizeGB: 1500), events: .init(days: 60), minFreeGB: 50))
        #expect(h.run("retention", "max-size", "none") == 0)
        #expect(try h.config.retention.continuous.maxSizeGB == nil)
        #expect(h.run("retention") == 0)
        #expect(h.console.lines.suffix(4).first == "continuous recording   14 days")
    }

    @Test func badRetentionValuesChangeNothing() throws {
        let h = try Harness()
        for args in [["continuous", "0"], ["continuous", "seven"], ["events", "-1"], ["max-size", "0"],
                     ["reserve", "-5"], ["continuous"], ["sideways", "1"]] {
            #expect(h.cli.run(["retention"] + args) == 2, "retention \(args)")
        }
        #expect(try h.config.retention == Config.Retention())
    }

    @Test func checkReportsEverything() throws {
        let h = try Harness()
        #expect(h.run("check") == 0)
        #expect(h.console.lines.last == "The settings are usable.")
        #expect(h.console.lines.contains { $0.hasPrefix("✓ recordings folder \(h.dir)/rec: ready, ") })
    }

    @Test func usageErrors() throws {
        let h = try Harness()
        #expect(h.run("frobnicate") == 2)
        #expect(h.console.errors.last == "✗ Unknown command frobnicate. See: pond help")
        #expect(h.run("check", "--verbose") == 2)
        #expect(h.console.errors.last == "✗ Unknown option --verbose.")
        #expect(h.run("help") == 0)
        #expect(h.console.lines.last?.hasPrefix("Usage: pond") == true)
    }
}
