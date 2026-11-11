// What needs attention, everywhere the app can tell: this Mac's recorder, its drive and its room, each camera
// (not recorded, or the doctor's problems and warnings), the other Ponds (gone quiet, or out of reach), and, as
// worth knowing but not wrong, the cameras kept private. One list, for the toolbar's state, its overview, the menu
// bar item and the camera rail's filter, so they all say the same.
import Foundation
import PondCore

struct Attention: Identifiable, Equatable {
    enum Level: Int, Comparable {
        /// Worth knowing, by choice (a camera kept private): listed, not counted.
        case info
        /// Something to change.
        case warning
        /// Something's wrong: recording is missed.
        case problem

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Where it's put right.
    enum Fix: Equatable {
        /// The doctor, at a camera (or at its list).
        case doctor(String?)
        /// The doctor's recorder page (whether it runs, its log).
        case recorder
        /// Not installed: started.
        case startRecorder
        case restartRecorder
        case storageSettings
        case remoteSettings
        /// Kept private: made public again (a toggle).
        case privacy(String)
    }

    var id: String
    var level: Level
    /// Which Pond it's at (nil: this Mac).
    var pond: String?
    /// The camera it's about, if one.
    var camera: String?
    var symbol: String
    var title: String
    /// In a few words, for the toolbar while it's the only thing.
    var short: String
    var detail: String?
    var fix: Fix?
}

extension AppModel {
    /// Everything that needs attention, the worst first, this Mac's before other Ponds'.
    var attention: [Attention] {
        var out: [Attention] = []
        let cameras = config?.cameras ?? []
        // The recorder.
        switch serviceState {
        case _ where isRestartingRecorder: break
        case .notInstalled where !cameras.isEmpty:
            out.append(.init(id: "recorder", level: .problem, symbol: "record.circle", title: "Not recording", short: "Not recording",
                             detail: "The recorder isn\u{2019}t started.", fix: .startRecorder))
        case let .stopped(why):
            out.append(.init(id: "recorder", level: .problem, symbol: "exclamationmark.triangle", title: "The recorder stopped",
                             short: "Recorder stopped", detail: why, fix: .recorder))
        case .running where needsRestart:
            out.append(.init(id: "recorder", level: .warning, symbol: "arrow.clockwise.circle", title: "Running with old settings",
                             short: "Restart Recorder", detail: "Restart the recorder to use the new ones.", fix: .restartRecorder))
        default: break
        }
        // The drive.
        if case let .storage(path)? = watch.problem {
            out.append(.init(id: "drive", level: .problem, symbol: "externaldrive.badge.exclamationmark",
                             title: "The recordings drive isn\u{2019}t there", short: "Drive missing", detail: "\(path): plug it in, or mount it.",
                             fix: .storageSettings))
        } else if let outlook = lastStorageOutlook, let days = outlook.estimate?.continuousDays, outlook.drive != nil,
                  days < Double(outlook.keepDays) * 0.9 {
            let room = days < 1 ? "less than a day" : days < 1.5 ? "about a day" : "about \(Int(days.rounded())) days"
            out.append(.init(id: "room", level: .warning, symbol: "externaldrive", title: "Room for \(room) of recordings",
                             short: "Drive filling up", detail: "Not the \(outlook.keepDays) days kept: the oldest go sooner.", fix: .storageSettings))
        }
        // This Mac's settings: what would stop recording unattended (the doctor's "This Mac").
        for finding in doctor.mac where finding.severity >= .warning {
            out.append(.init(id: "mac \(finding.id)", level: finding.severity == .problem ? .problem : .warning,
                             symbol: finding.severity == .problem ? "exclamationmark.triangle" : "bolt.badge.clock",
                             title: finding.headline, short: finding.headline, detail: finding.fix ?? finding.evidence, fix: .doctor(nil)))
        }
        // Each camera: not recorded (the service watch), else the doctor's worst worth a mark.
        let silent: Set<String> = if case let .notRecording(names)? = watch.problem { Set(names) } else { [] }
        for camera in cameras where !isPrivate(camera.id) {
            let finding = doctor.mark(camera.id)
            if silent.contains(camera.name) {
                out.append(.init(id: "camera \(camera.id)", level: .problem, camera: camera.id, symbol: "record.circle",
                                 title: "\(camera.name) isn\u{2019}t being recorded", short: "\(camera.name) not recorded",
                                 detail: finding?.headline ?? "Nothing recorded for a few minutes.", fix: .doctor(camera.id)))
            } else if let finding {
                out.append(.init(id: "camera \(camera.id)", level: finding.severity == .problem ? .problem : .warning,
                                 camera: camera.id, symbol: finding.severity == .problem ? "exclamationmark.triangle" : "wrench",
                                 title: "\(camera.name): \(finding.headline.prefix(1).lowercased() + finding.headline.dropFirst())",
                                 short: "\(camera.name) needs attention",
                                 detail: finding.fix ?? finding.evidence, fix: .doctor(camera.id)))
            }
        }
        // Other Ponds: gone quiet (the service watch, told as a notification too), else out of reach just now.
        for pond in otherPonds {
            if let quiet = watch.otherPonds[pond.id] {
                out.append(.init(id: "pond \(pond.id)", level: .problem, pond: pond.id, symbol: "house",
                                 title: quiet.title, short: "\(pond.name) quiet", detail: quiet.detail, fix: .remoteSettings))
            } else if let problem = remotePonds.first(where: { $0.id == pond.id })?.problem {
                out.append(.init(id: "pond \(pond.id)", level: .warning, pond: pond.id, symbol: "house",
                                 title: "\(pond.name) can\u{2019}t be reached", short: "\(pond.name) unreachable", detail: problem, fix: .remoteSettings))
            }
        }
        // Kept private, by choice: last.
        for group in allCameraGroups {
            for camera in group.cameras where isPrivate(camera.id) {
                let onCamera = isPrivateOnCameraOnly(camera.id)
                out.append(.init(id: "private \(camera.id)", level: .info, pond: group.pond, camera: camera.id, symbol: "eye.slash",
                                 title: "\(camera.name) is private", short: "\(camera.name) private",
                                 detail: onCamera ? "On the camera itself: not recorded." : "Not recorded, shown live or in the Home app.",
                                 fix: group.pond == nil && !onCamera ? .privacy(camera.id) : nil))
            }
        }
        return out.enumerated().sorted { ($0.element.level, $1.offset) > ($1.element.level, $0.offset) }.map(\.element)
    }

    /// The toolbar's words with one Pond: what needs attention, in a few words (or how many), else the recorder's
    /// state.
    var statusWords: String {
        let items = attention.filter { $0.level >= .warning }
        if items.count == 1 { return items[0].short }
        return items.isEmpty ? recorderWords : "\(items.count) need attention"
    }

    /// The recorder is running now.
    var isRecorderRunning: Bool { if case .running = serviceState { true } else { false } }

    /// How many things need attention (not counting cameras kept private).
    var attentionCount: Int { attention.count { $0.level >= .warning } }

    /// The cameras that need attention (any Pond's), for the rail's filter.
    var attentionCameras: Set<String> { Set(attention.filter { $0.level >= .warning }.compactMap(\.camera)) }
}
