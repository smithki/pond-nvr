// Whether this Mac is set up to record unattended: what its power and login settings mean for Pond, said by the
// doctor under "This Mac". A Mac that doesn't start again after a power cut, or waits at the login screen after a
// restart, or sleeps, records nothing, and nothing else would say so. The settings are read by the app (pmset,
// the login window's preferences, fdesetup), with no administrator rights; the rules are here.
import Foundation

/// This Mac's power and login settings, as far as Pond cares.
public struct MacPower: Equatable, Sendable {
    /// Has a battery of its own (a laptop).
    public var isLaptop = false
    /// Running on a battery: its own, or a UPS's (the power's out).
    public var onBattery = false
    /// On a UPS (not a laptop's own battery).
    public var onUPS = false
    /// Starts up again by itself after a power cut (nil: the setting isn't there, as on laptops).
    public var restartsAfterPowerLoss: Bool?
    /// Minutes idle before the Mac sleeps (0: never; nil: not read).
    public var sleepMinutes: Int?
    /// Pond's recorder is holding off idle sleep now.
    public var sleepHeldByPond = false
    /// Logs in by itself after a restart (as this user).
    public var logsInAutomatically = false
    /// FileVault is on (so it can't log in by itself; nil: not known).
    public var fileVault: Bool?
    public var lowPowerMode = false

    public init() {}

    /// From `pmset -g` and `pmset -g batt`.
    public mutating func read(pmset: String, battery: String) {
        for line in pmset.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 2 else { continue }
            switch words[0] {
            case "autorestart": restartsAfterPowerLoss = words[1] != "0"
            case "sleep":
                sleepMinutes = Int(words[1])
                sleepHeldByPond = line.contains("prevented by") && line.range(of: #"\bpond\b"#, options: .regularExpression) != nil
            case "lowpowermode": lowPowerMode = words[1] != "0"
            default: break
            }
        }
        isLaptop = battery.contains("InternalBattery")
        onUPS = battery.contains("'UPS Power'")
        onBattery = battery.contains("'Battery Power'") || onUPS
    }
}

public struct MacFinding: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case mayIdleSleep, onUPS, onBattery, laptop, noRestartAfterPowerLoss, waitsForLogin, lowPowerMode
    }

    /// Where in System Settings it's changed.
    public enum Place: String, Sendable {
        case energy = "com.apple.Energy-Settings.extension"
        case battery = "com.apple.Battery-Settings.extension"
        case users = "com.apple.Users-Groups-Settings.extension"
        case privacy = "com.apple.settings.PrivacySecurity.extension"
    }

    public var kind: Kind
    public var severity: HealthFinding.Severity
    public var headline: String
    public var evidence: String
    public var fix: String?
    public var place: Place?

    public var id: String { kind.rawValue }
}

public enum MacReadiness {
    /// What this Mac's settings mean for recording unattended, worst first. `recording`: the recorder is running
    /// (whether it should be holding off sleep).
    public static func findings(_ p: MacPower, recording: Bool) -> [MacFinding] {
        var out: [MacFinding] = []
        if recording, let minutes = p.sleepMinutes, minutes > 0, !p.sleepHeldByPond {
            out.append(MacFinding(
                kind: .mayIdleSleep, severity: .problem, headline: "This Mac may go to sleep",
                evidence: "It sleeps after \(minutes) min idle, and Pond\u{2019}s recorder isn\u{2019}t keeping it awake",
                fix: "Restart the recorder; or set this Mac never to sleep on its own in Energy settings.", place: .energy))
        }
        if p.onUPS {
            out.append(MacFinding(
                kind: .onUPS, severity: .problem, headline: "Running on its UPS",
                evidence: "The power\u{2019}s out: this Mac is running on its backup battery",
                fix: "Pond records until the UPS runs low; check the power.", place: nil))
        } else if p.onBattery {
            out.append(MacFinding(
                kind: .onBattery, severity: .warning, headline: "Running on battery",
                evidence: "This Mac sleeps, and stops recording, when its battery runs low",
                fix: "Plug it in.", place: .battery))
        } else if p.isLaptop {
            out.append(MacFinding(
                kind: .laptop, severity: .notice, headline: "A laptop",
                evidence: "Closing its lid puts it to sleep, and recording stops (unless a display is connected to it)",
                fix: nil, place: nil))
        }
        if p.restartsAfterPowerLoss == false {
            out.append(MacFinding(
                kind: .noRestartAfterPowerLoss, severity: .warning, headline: "Stays off after a power cut",
                evidence: "\u{201C}Start up automatically after a power failure\u{201D} is off",
                fix: "Turn it on in Energy settings, so recording starts again when the power comes back.", place: .energy))
        }
        if !p.logsInAutomatically {
            let why = p.fileVault == true
                ? "FileVault is on, so this Mac can\u{2019}t log in by itself"
                : "Automatic login is off"
            out.append(MacFinding(
                kind: .waitsForLogin, severity: .notice, headline: "Records only once you\u{2019}ve logged in",
                evidence: why + ": after a restart (a power cut, an overnight macOS update) Pond waits at the login screen",
                fix: p.fileVault == true
                    ? "A trade-off: FileVault protects what\u{2019}s on this Mac if it\u{2019}s stolen. Turning it off (Privacy & Security) lets it log in by itself, and record after a restart."
                    : "A trade-off: automatic login (Users & Groups) lets anyone at this Mac use it, and lets Pond record after a restart unattended.",
                place: p.fileVault == true ? .privacy : .users))
        }
        if p.lowPowerMode {
            out.append(MacFinding(
                kind: .lowPowerMode, severity: .notice, headline: "Low Power Mode is on",
                evidence: "Detection and HomeKit\u{2019}s video may fall behind", fix: nil, place: p.isLaptop ? .battery : .energy))
        }
        return out.sorted { $0.severity > $1.severity }
    }
}
