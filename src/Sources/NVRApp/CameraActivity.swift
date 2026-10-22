// What each camera has been up to, for the live view: today's events (from detection, as the timeline shows
// them; made up with POND_MOCK_EVENTS=1) and whether it is still being recorded.
import Foundation
import Observation
import Recorder

@MainActor
@Observable
final class CameraActivity {
    struct Summary: Equatable {
        /// Events since midnight.
        var eventsToday = 0
        var latest: TimelineEvent?
        /// The last few, newest first.
        var recent: [TimelineEvent] = []
    }

    private(set) var summaries: [String: Summary] = [:]

    subscript(camera: String) -> Summary { summaries[camera] ?? Summary() }

    /// Reads today's recordings and events, off the main thread.
    func refresh(base: String, cameras: [String], source: EventSource?) async {
        let day = Calendar.current.startOfDay(for: Date())
        let found = await Task.detached {
            var coverage: [String: [ClosedRange<Date>]] = [:]
            for c in cameras {
                coverage[c] = RecordingIndex.coverage(RecordingIndex.spans(base: base, camera: c, from: day,
                                                                          to: day.addingTimeInterval(86400)))
            }
            return coverage
        }.value
        let now = Date()
        let events = MockEvents.enabled ? MockEvents.make(coverage: found, day: day).filter { $0.start <= now }
            : await Task.detached { source?.events(from: day, to: now) ?? [] }.value
        var out: [String: Summary] = [:]
        for c in cameras {
            let mine = events.filter { $0.camera == c }
            out[c] = Summary(eventsToday: mine.count, latest: mine.last, recent: Array(mine.suffix(5).reversed()))
        }
        summaries = out
    }
}

/// How a camera is doing, as far as the app can tell: from its live connection while it is on the stage, and
/// from its recordings otherwise.
enum CameraHealth: Equatable {
    case ok
    /// Configured, but the connection fails.
    case offline(String)
    /// Connected, but no video: privacy mode, or the camera stopped sending.
    case noPicture
    /// Nothing recorded lately although the recorder runs.
    case notRecording(since: Date?)
    /// Just added: its first minute isn't saved yet. Not a problem, but said, so the empty camera is explained.
    case startingToRecord
    /// Made private in Pond: not recorded or shown, by choice. Not a problem.
    case keptPrivate

    var isProblem: Bool { self != .ok && self != .startingToRecord && self != .keptPrivate }
    /// Has something to say on the tile.
    var showsBadge: Bool { self != .ok }

    var title: String {
        switch self {
        case .ok: ""
        case .offline: "Offline"
        case .noPicture: "No picture"
        case .notRecording: "Not recording"
        case .startingToRecord: "Starting to record"
        case .keptPrivate: "Private"
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle"
        case .offline: "wifi.slash"
        case .noPicture: "eye.slash"
        case .notRecording: "record.circle"
        case .startingToRecord: "hourglass"
        case .keptPrivate: "eye.slash"
        }
    }

    var detail: String {
        switch self {
        case .ok: ""
        case let .offline(reason): "Can\u{2019}t connect: \(reason)"
        case .noPicture: "Connected, but no video. Is privacy mode on?"
        case let .notRecording(since?):
            "Nothing recorded since \(since.formatted(date: .omitted, time: .shortened))."
        case .notRecording(nil): "Nothing recorded yet."
        case .startingToRecord: "Recording has just started. Its first minute is saved about a minute after it starts."
        case .keptPrivate: "Private: not recorded, shown live or in the Home app."
        }
    }

    /// Recordings older than this, while the recorder runs, mean the camera is not being recorded.
    static let staleAfter: TimeInterval = 5 * 60
    /// A new camera's first minute is saved about a minute after recording begins (with a restart of the
    /// recorder before it); until this long, its having none is expected.
    static let firstRecordingWithin: TimeInterval = 3 * 60

    /// - Parameters:
    ///   - live: the tile's status, if the camera is on the stage.
    ///   - lastRecorded: when its newest recording was made.
    ///   - recordingAsOf: the time recordings should be current to (now, while the recorder runs), or nil if
    ///     staleness says nothing (the recorder is stopped).
    ///   - startedRecording: when its recording began, if lately: the camera added, or the service started.
    static func of(live: TileStatus?, lastRecorded: Date?, recordingAsOf: Date?, startedRecording: Date? = nil) -> CameraHealth {
        switch live {
        case let .failed(reason)?: return .offline(reason)
        case .noPicture?: return .noPicture
        default: break
        }
        guard let recordingAsOf else { return .ok }
        let started = startedRecording.flatMap { recordingAsOf.timeIntervalSince($0) < firstRecordingWithin ? $0 : nil }
        guard let lastRecorded else { return started == nil ? .notRecording(since: nil) : .startingToRecord }
        guard recordingAsOf.timeIntervalSince(lastRecorded) > staleAfter else { return .ok }
        // Nothing lately, but recording began again since (the service started after a gap): its first minute
        // isn't saved yet.
        if let started, lastRecorded < started { return .startingToRecord }
        return .notRecording(since: lastRecorded)
    }
}
