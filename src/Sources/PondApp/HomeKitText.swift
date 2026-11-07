// HomeKit's state in words, with what to do about it. Only causes that are known get named; anything else
// says so plainly and points to the service's log, rather than guessing or showing log lines.
import AppKit
import Control
import PondCore

struct HomeKitText: Equatable {
    var title: String
    var detail: String
    var actions: [Action]

    enum Action: Equatable {
        /// Start (or restart) the background service.
        case startService
        /// The camera's settings, where its setup code, password and connection check are.
        case cameraSettings
        /// The service's log, for causes pond cannot name.
        case showLog

        var label: String {
            switch self {
            case .startService: "Start Service"
            case .cameraSettings: "Camera Settings…"
            case .showLog: "Show Log"
            }
        }
    }

    init(title: String, detail: String, actions: [Action] = []) {
        self.title = title
        self.detail = detail
        self.actions = actions
    }

    /// Where the words are read: a camera's settings say "below" for what is there, rather than sending you
    /// to the settings you are in.
    enum Place { case popover, settings }

    /// Where in a camera's settings a part of them is, said from `place`.
    static func settings(_ part: String, from place: Place) -> String {
        place == .settings ? "under \(part), below" : "in its settings \u{203A} \(part)"
    }

    init(_ state: HomeKitState, camera: Config.Camera, in place: Place = .popover) {
        let name = camera.name
        switch state {
        case .serviceStopped:
            self.init(title: "HomeKit is off",
                      detail: "The Home app reaches \(name) through Pond\u{2019}s background service, which isn\u{2019}t running.",
                      actions: [.startService])
        case .waitingForService:
            self.init(title: "Not in HomeKit yet",
                      detail: "Pond\u{2019}s service started before \(name) was added to HomeKit. Restart it to add the camera.",
                      actions: [.startService])
        case .notAdded:
            self.init(title: "Not in the Home app yet",
                      detail: "Add \(name) in the Home app with its setup code.",
                      actions: [.cameraSettings])
        case let .problem(problem):
            self = Self.problem(problem, camera: camera)
        case let .doorbellButton(state):
            self = Self.doorbell(state, camera: camera, in: place)
        case .live:
            self.init(title: "Live in the Home app", detail: "Someone is watching \(name) in the Home app.")
        case .ready:
            self.init(title: "In the Home app", detail: "\(name) is in the Home app.")
        }
    }

    static func problem(_ problem: HomeKitStatus.Problem, camera: Config.Camera) -> HomeKitText {
        let name = camera.name
        let asked = switch problem.during {
        case .liveView: "the Home app asked for live video"
        case .snapshot: "the Home app asked for a picture"
        case .starting: "HomeKit started"
        }
        switch problem.kind {
        case .cameraUnreachable:
            return HomeKitText(title: "\(name) can\u{2019}t be reached",
                               detail: "\(name) didn\u{2019}t answer at \(camera.host) when \(asked).",
                               actions: [.cameraSettings])
        case .loginRefused:
            return HomeKitText(title: "\(name) turned down the password",
                               detail: "The camera refused the saved username and password when \(asked). Enter the password it uses now.",
                               actions: [.cameraSettings])
        case .noAnswer:
            return HomeKitText(title: "No answer from \(name)",
                               detail: "\(name) took the connection but didn\u{2019}t reply when \(asked).",
                               actions: [.cameraSettings])
        case .noVideo:
            return HomeKitText(title: "No video from \(name)",
                               detail: "\(name) connected but sent no picture when \(asked).",
                               actions: [.cameraSettings])
        case .noPassword:
            return HomeKitText(title: "No password for \(name)",
                               detail: "There\u{2019}s no password for \(name) in your Keychain, so HomeKit can\u{2019}t reach it.",
                               actions: [.cameraSettings])
        case .couldNotStart:
            return HomeKitText(title: "HomeKit couldn\u{2019}t start \(name)",
                               detail: "Pond\u{2019}s service couldn\u{2019}t make \(name) available to the Home app. Its log has the details.",
                               actions: [.startService, .showLog])
        case .other:
            return HomeKitText(title: "Something went wrong in HomeKit",
                               detail: "Pond doesn\u{2019}t know what went wrong when \(asked). The service\u{2019}s log has the details.",
                               actions: [.showLog])
        }
    }

    static func doorbell(_ state: HomeKitStatus.DoorbellState, camera: Config.Camera, in place: Place = .popover) -> HomeKitText {
        let name = camera.name
        switch state {
        case .watching:
            return HomeKitText(title: "In the Home app", detail: "\(name) rings in the Home app when its button is pressed.")
        case .notSupported:
            return HomeKitText(title: "The Home app won\u{2019}t ring",
                               detail: "\(name) doesn\u{2019}t report button presses in a way Pond can read, so the Home app shows its video but won\u{2019}t ring.")
        case .unknownModel:
            return HomeKitText(title: "The Home app won\u{2019}t ring",
                               detail: "Pond doesn\u{2019}t know what model \(name) is, so it can\u{2019}t watch the button. Run Check\u{2026} on its Doctor tab lets Pond ask the camera.",
                               actions: [.cameraSettings])
        case .cameraUnreachable:
            return HomeKitText(title: "The Home app won\u{2019}t ring",
                               detail: "Pond can\u{2019}t reach \(name) at \(camera.host) to watch its button. It keeps trying.",
                               actions: [.cameraSettings])
        case .loginRefused:
            return HomeKitText(title: "The Home app won\u{2019}t ring",
                               detail: "\(name) turned down the saved password when Pond asked about its button. Enter the password it uses now.",
                               actions: [.cameraSettings])
        case .videoOnly:
            return HomeKitText(title: "The Home app won\u{2019}t ring",
                               detail: "\(name) is set to video only, so Pond doesn\u{2019}t watch its button. Change it \(settings("Device", from: place)).",
                               actions: [.cameraSettings])
        }
    }

    static func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: LaunchAgent.logPath))
    }
}

/// HomeKit Secure Video's state in words: one line for the popover and settings, and a detail.
struct RecordingText: Equatable {
    var title: String
    var detail: String
    /// Something to do or know about (shown in orange).
    var attention = false

    init(_ r: HomeKitStatus.Recording, camera: Config.Camera, now: Date = Date(), in place: HomeKitText.Place = .popover) {
        let name = camera.name
        let last = r.lastClip.map { clip -> String in
            let size = ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .file)
            return "Last recording \(Self.when(clip.at, now: now)), \(Int(clip.seconds.rounded())) s, \(size)."
        }
        if !r.motion, camera.isVideoOnly {
            self.init(title: "Won\u{2019}t record", attention: true,
                      detail: "\(name) is set to video only, so Pond doesn\u{2019}t watch its own motion, which is what starts a recording. Choose Pond\u{2019}s detection for its motion in the Home app, or change how Pond talks to it \(HomeKitText.settings("Device", from: place)).")
        } else if !r.motion {
            self.init(title: "Won\u{2019}t record", attention: true,
                      detail: "Pond can\u{2019}t see motion from \(name), and motion is what starts a recording.")
        } else if !r.on {
            self.init(title: "Recording off in the Home app",
                      detail: "To record \(name)\u{2019}s motion to iCloud: in the Home app, \(name)\u{2019}s settings \u{203A} Recording Options.")
        } else if !r.chosen {
            self.init(title: "Waiting for your home hub",
                      detail: "Recording is on; your home hub hasn\u{2019}t set it up yet. It usually does within a minute.")
        } else if r.recording {
            self.init(title: "Recording now", detail: "Sending a recording of \(name) to your home hub." + (last.map { " " + $0 } ?? ""))
        } else if let problem = r.problem {
            let why = switch problem.kind {
            case .notAllowed: "Your home hub asked to record while recording was off for \(name)."
            case .notChosen: "Your home hub asked to record before setting up how."
            case .noVideo: "Pond couldn\u{2019}t read \(name)\u{2019}s video for a recording."
            case .cutShort: "Your home hub ended a recording with an error."
            case .other: "A recording didn\u{2019}t go as it should. The service\u{2019}s log has the details."
            }
            self.init(title: "A recording failed", attention: true, detail: why + (last.map { " " + $0 } ?? ""))
        } else {
            self.init(title: r.sound ? "Recording motion, with sound" : "Recording motion",
                      detail: last ?? "No recordings yet: they start when \(name) sees motion.")
        }
    }

    init(title: String, attention: Bool = false, detail: String) {
        self.title = title
        self.detail = detail
        self.attention = attention
    }

    /// "at 2:57 PM", "yesterday at 9:12 AM", "Oct 12 at 9:12 AM".
    static func when(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }
}
