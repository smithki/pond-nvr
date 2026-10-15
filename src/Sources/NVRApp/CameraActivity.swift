// What each camera has been up to, for the live view: today's events (from detection; made up with
// POND_MOCK_EVENTS=1 until then, the same ones the timeline shows) and whether it is still being recorded.
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
    func refresh(base: String, cameras: [String]) async {
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
        let events = MockEvents.enabled ? MockEvents.make(coverage: found, day: day).filter { $0.start <= now } : []
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

    var isProblem: Bool { self != .ok && self != .startingToRecord }
    /// Has something to say on the tile.
    var showsBadge: Bool { self != .ok }

    var title: String {
        switch self {
        case .ok: ""
        case .offline: "Offline"
        case .noPicture: "No picture"
        case .notRecording: "Not recording"
        case .startingToRecord: "Starting to record"
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle"
        case .offline: "wifi.slash"
        case .noPicture: "eye.slash"
        case .notRecording: "record.circle"
        case .startingToRecord: "hourglass"
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
        case .startingToRecord: "Just added. The first minute of recording is saved about a minute after it starts."
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
    ///   - startedRecording: when the camera was added, if it was lately.
    static func of(live: TileStatus?, lastRecorded: Date?, recordingAsOf: Date?, startedRecording: Date? = nil) -> CameraHealth {
        switch live {
        case let .failed(reason)?: return .offline(reason)
        case .noPicture?: return .noPicture
        default: break
        }
        guard let recordingAsOf else { return .ok }
        guard let lastRecorded else {
            if let started = startedRecording, recordingAsOf.timeIntervalSince(started) < firstRecordingWithin {
                return .startingToRecord
            }
            return .notRecording(since: nil)
        }
        return recordingAsOf.timeIntervalSince(lastRecorded) > staleAfter ? .notRecording(since: lastRecorded) : .ok
    }
}
