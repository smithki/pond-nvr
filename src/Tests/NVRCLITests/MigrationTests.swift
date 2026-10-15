import Control
import Foundation
import NVRCore
import Testing

/// A setup from before the rename, in a temporary home: everything moves over, and a second run does nothing.
@Suite struct MigrationTests {
    let home = NSTemporaryDirectory() + "migration-" + UUID().uuidString

    var paths: Migration.Paths {
        Migration.Paths(oldSupport: home + "/Support/nvr", newSupport: home + "/Support/Pond",
                        oldLogs: home + "/Logs/nvr", newLogs: home + "/Logs/Pond",
                        oldPlist: home + "/LaunchAgents/com.local.nvr.plist")
    }

    @Test func anOldSetupMovesOver() throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        for dir in [paths.oldSupport, paths.oldLogs, home + "/LaunchAgents"] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var config = Config(storage: .init(recordings: home + "/recordings", database: paths.oldSupport + "/nvr.sqlite"))
        config.cameras = [Config.Camera.reolink(id: "porch", name: "Porch", host: "192.168.1.20", username: "admin")]
        try ConfigStore(path: paths.oldSupport + "/config.json").save(config)
        fm.createFile(atPath: paths.oldSupport + "/streams.sock", contents: Data())
        fm.createFile(atPath: paths.oldLogs + "/nvr.log", contents: Data("a line\n".utf8))
        fm.createFile(atPath: paths.oldPlist, contents: Data())

        let stores = [
            "nvr": MemoryCredentialStore(["porch": "secret"]), "nvr-homekit": MemoryCredentialStore(["porch": "{record}"]),
            "pond": MemoryCredentialStore(), "pond-homekit": MemoryCredentialStore(),
        ]
        let launchd = FakeLaunchd()
        var installed = 0
        let migration = Migration(paths: paths, launchd: launchd, keychain: { stores[$0]! }) {
            installed += 1
            return "/Applications/Pond.app/Contents/MacOS/pond"
        }
        #expect(migration.needed)
        // The new log folder can be there already (empty); the log still moves into it.
        try fm.createDirectory(atPath: paths.newLogs, withIntermediateDirectories: true)
        var said: [String] = []
        try migration.run { said.append($0) }

        #expect(launchd.calls == ["bootout"])
        #expect(!fm.fileExists(atPath: paths.oldLogs))
        #expect(installed == 1)
        #expect(!fm.fileExists(atPath: paths.oldPlist))
        #expect(!fm.fileExists(atPath: paths.oldSupport) && !fm.fileExists(atPath: paths.newSupport + "/streams.sock"))
        let moved = try ConfigStore(path: paths.newSupport + "/config.json").load()
        #expect(moved.storage.database == paths.newSupport + "/nvr.sqlite")
        #expect(fm.contents(atPath: paths.newLogs + "/pond.log") == Data("a line\n".utf8))
        #expect(stores["pond"]!.password(for: "porch") == "secret")
        #expect(stores["pond-homekit"]!.password(for: "porch") == "{record}")
        // The old items stay until deleted by hand.
        #expect(stores["nvr"]!.password(for: "porch") == "secret")
        #expect(said.contains { $0.hasPrefix("✓ 2 Keychain items copied") })

        // Again: nothing left to do.
        #expect(!migration.needed)
        said = []
        try migration.run { said.append($0) }
        #expect(said == ["Nothing to move: there is no setup from before the rename."])
        #expect(installed == 1)
    }

    @Test func aServiceLoadedWithoutItsPlistIsMovedToo() throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let launchd = FakeLaunchd()
        launchd.loaded = "elsewhere"
        var installed = 0
        let migration = Migration(paths: paths, launchd: launchd, keychain: { _ in MemoryCredentialStore() }) {
            installed += 1
            return "pond"
        }
        #expect(migration.needed)
        try migration.run { _ in }
        #expect(launchd.calls == ["bootout"] && installed == 1)
    }

    @Test func aFolderPreparedBeforeTheRenameIsStillReady() throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: home + "/.nvr-storage", contents: Data("ID-1\n".utf8))
        #expect(StorageLocation.status(of: home) == .ready(id: "ID-1"))
        // Its marker is copied to the new name.
        #expect(FileManager.default.fileExists(atPath: home + "/.pond-storage"))
    }
}
