// `pond migrate`: carries a setup from before the rename (when the product was nvr) over to Pond's names,
// so it goes on as it was: the login service, the settings folder (with the HomeKit status), the log, and
// the Keychain items (camera passwords, and each camera's HomeKit identity and pairings, without which the
// cameras would have to be added to the Home app again). Each step acts only on what is there, so it can
// run again and does nothing.
import Foundation
import NVRCore

public struct Migration {
    public struct Paths: Sendable {
        public var oldSupport: String
        public var newSupport: String
        public var oldLogs: String
        public var newLogs: String
        public var oldPlist: String

        public init(oldSupport: String, newSupport: String, oldLogs: String, newLogs: String, oldPlist: String) {
            self.oldSupport = oldSupport
            self.newSupport = newSupport
            self.oldLogs = oldLogs
            self.newLogs = newLogs
            self.oldPlist = oldPlist
        }

        public static var live: Paths {
            func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }
            return Paths(oldSupport: expand(Brand.Legacy.supportFolder), newSupport: expand(Brand.supportFolder),
                         oldLogs: expand(Brand.Legacy.logFolder), newLogs: expand(Brand.logFolder),
                         oldPlist: expand("~/Library/LaunchAgents/\(Brand.Legacy.serviceLabel).plist"))
        }
    }

    public let paths: Paths
    public let launchd: Launchd?
    /// The Keychain, by service.
    public let keychain: (String) -> CredentialStore
    /// Installs the login service under its new name (when the old one was installed); says what it runs.
    public let installService: () throws -> String

    public init(paths: Paths = .live, launchd: Launchd?, keychain: @escaping (String) -> CredentialStore,
                installService: @escaping () throws -> String) {
        self.paths = paths
        self.launchd = launchd
        self.keychain = keychain
        self.installService = installService
    }

    /// Whether the old login service is installed: its plist, or loaded in launchd (its plist can be gone).
    var oldServiceInstalled: Bool {
        FileManager.default.fileExists(atPath: paths.oldPlist) || launchd?.describe(label: Brand.Legacy.serviceLabel) != nil
    }

    /// Whether anything from before is still there.
    public var needed: Bool {
        let fm = FileManager.default
        return oldServiceInstalled || [paths.oldSupport, paths.oldLogs].contains { fm.fileExists(atPath: $0) }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Moves everything over, saying what it did (`✓` lines) and what it left (`!` lines).
    public func run(say: (String) -> Void) throws(Failure) {
        let fm = FileManager.default
        guard needed else {
            say("Nothing to move: there is no setup from before the rename.")
            return
        }

        // The old service first, so nothing writes to the old places while they move.
        let serviceWasInstalled = oldServiceInstalled
        if serviceWasInstalled {
            do {
                try launchd?.bootout(label: Brand.Legacy.serviceLabel)
                if fm.fileExists(atPath: paths.oldPlist) { try fm.removeItem(atPath: paths.oldPlist) }
            } catch {
                throw Failure(description: "The old login service (\(Brand.Legacy.serviceLabel)) could not be stopped: \(error)")
            }
            say("✓ stopped the old login service (\(Brand.Legacy.serviceLabel))")
        }

        // The settings folder, and the database path in the settings if it pointed into it.
        if fm.fileExists(atPath: paths.oldSupport) {
            if fm.fileExists(atPath: paths.newSupport) {
                say("! \(paths.newSupport) is there already, so \(paths.oldSupport) was left as it is.")
            } else {
                do {
                    try fm.createDirectory(atPath: (paths.newSupport as NSString).deletingLastPathComponent,
                                           withIntermediateDirectories: true)
                    try fm.moveItem(atPath: paths.oldSupport, toPath: paths.newSupport)
                } catch {
                    throw Failure(description: "\(paths.oldSupport) could not be moved: \(error.localizedDescription)")
                }
                // The service makes its socket again when it starts.
                try? fm.removeItem(atPath: (paths.newSupport as NSString).appendingPathComponent("streams.sock"))
                say("✓ settings moved to \(paths.newSupport)")
            }
        }
        let store = ConfigStore(path: (paths.newSupport as NSString).appendingPathComponent("config.json"))
        if var config = try? store.load(), config.storage.database.hasPrefix(paths.oldSupport) {
            config.storage.database = paths.newSupport + config.storage.database.dropFirst(paths.oldSupport.count)
            do { try store.save(config) } catch {
                say("! The database path in the settings still points to \(paths.oldSupport): \(error)")
            }
        }

        // The log files, renamed, into the new log folder (which may be there already); then the old folder,
        // if nothing else is in it.
        if fm.fileExists(atPath: paths.oldLogs) {
            do {
                try fm.createDirectory(atPath: paths.newLogs, withIntermediateDirectories: true)
                for (old, new) in [(Brand.Legacy.logName, Brand.logName), (Brand.Legacy.logName + ".1", Brand.logName + ".1"),
                                   (Brand.Legacy.outputLogName, Brand.outputLogName)] {
                    let from = (paths.oldLogs as NSString).appendingPathComponent(old)
                    let to = (paths.newLogs as NSString).appendingPathComponent(new)
                    if fm.fileExists(atPath: from), !fm.fileExists(atPath: to) { try fm.moveItem(atPath: from, toPath: to) }
                }
                if (try? fm.contentsOfDirectory(atPath: paths.oldLogs))?.isEmpty == true { try fm.removeItem(atPath: paths.oldLogs) }
                say("✓ log moved to \(paths.newLogs)")
            } catch {
                say("! The log could not be moved: \(error.localizedDescription)")
            }
        }

        // The Keychain items, camera by camera: copied, so the old ones are there until you delete them.
        if let config = try? store.load() {
            var copied = 0
            for (old, new) in [(Brand.Legacy.keychainService, Brand.keychainService),
                               (Brand.Legacy.homeKitKeychainService, Brand.homeKitKeychainService)] {
                let from = keychain(old), to = keychain(new)
                for camera in config.cameras {
                    do {
                        guard try to.password(for: camera.id) == nil, let value = try from.password(for: camera.id) else { continue }
                        try to.setPassword(value, for: camera.id)
                        copied += 1
                    } catch {
                        say("! \(camera.id)'s Keychain item under \(old) was not copied: \(error)")
                    }
                }
            }
            if copied > 0 {
                say("✓ \(copied) Keychain item\(copied == 1 ? "" : "s") copied to \(Brand.keychainService) and \(Brand.homeKitKeychainService)")
                say("The old items (\(Brand.Legacy.keychainService), \(Brand.Legacy.homeKitKeychainService)) are still in the Keychain; delete them in Keychain Access once \(Brand.name) works.")
            }
        }

        // The service again, under its new name.
        if serviceWasInstalled {
            let program: String
            do {
                program = try installService()
            } catch {
                throw Failure(description: "The login service could not be installed again: \(error). Start it with: \(Brand.command) service install")
            }
            say("✓ login service installed as \(Brand.serviceLabel), running \(program)")
        }
    }
}
