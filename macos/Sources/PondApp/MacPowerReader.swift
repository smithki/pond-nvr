// This Mac's power and login settings, read for the doctor's "This Mac" (MacReadiness): pmset's settings and power
// source, whether it logs in by itself (the login window's preferences, readable by anyone), and FileVault
// (fdesetup). No administrator rights, and nothing changed.
import Foundation
import PondCore

enum MacPowerReader {
    /// Read now (a few short programs: off the main thread).
    static func read() -> MacPower {
        var power = MacPower()
        power.read(pmset: run("/usr/bin/pmset", ["-g"]), battery: run("/usr/bin/pmset", ["-g", "batt"]))
        power.lowPowerMode = power.lowPowerMode || ProcessInfo.processInfo.isLowPowerModeEnabled
        let login = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.loginwindow.plist")
        power.logsInAutomatically = (login?["autoLoginUser"] as? String) == NSUserName()
        let vault = run("/usr/bin/fdesetup", ["status"])
        power.fileVault = vault.contains("FileVault is On") ? true : vault.contains("FileVault is Off") ? false : nil
        return power
    }

    /// A program's output (empty if it can't be run).
    static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
