// Gaps in a camera's recordings, and why each happened, from what the service recorded at the time (its health
// incidents): this Mac asleep, off or restarting; the recorder stopped or not running; the drive full or missing;
// the camera's own trouble. A private stretch isn't a gap (it's shown as private), and a short one (reconnecting
// after a hiccup) isn't worth saying. For the timeline ("Not recorded 03:12–06:40: the drive was full") and the
// doctor.
import Foundation

public struct RecordingGap: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case macAsleep, macOff, recorderStopped, recorderNotRunning
        /// The drive: why, in words ("the recordings drive was full").
        case storage(String)
        case macNetwork, unreachable, loginRefused, privacyMode, didntWake, videoStopped, restarted
        /// Nothing recorded explains it (or it's older than what's kept).
        case unknown

        /// Why, in words, to follow "Not recorded: " (nil when unknown).
        public var words: String? {
            switch self {
            case .macAsleep: "this Mac was asleep"
            case .macOff: "this Mac was off or restarting"
            case .recorderStopped: "Pond\u{2019}s recorder was stopped"
            case .recorderNotRunning: "Pond\u{2019}s recorder wasn\u{2019}t running"
            case let .storage(why): why
            case .macNetwork: "this Mac lost the network"
            case .unreachable: "the camera didn\u{2019}t answer"
            case .loginRefused: "the camera refused its login"
            case .privacyMode: "the camera\u{2019}s own privacy mode was on"
            case .didntWake: "the camera\u{2019}s video didn\u{2019}t come back after privacy mode"
            case .videoStopped: "the camera\u{2019}s video stopped"
            case .restarted: "Pond was restarting the camera"
            case .unknown: nil
            }
        }

        /// This Mac's or Pond's side (not the camera's).
        public var isMacSide: Bool {
            switch self {
            case .macAsleep, .macOff, .recorderStopped, .recorderNotRunning, .storage, .macNetwork: true
            default: false
            }
        }
    }

    public var range: ClosedRange<Date>
    public var reason: Reason
    /// Still going (its end is when it was looked at).
    public var ongoing: Bool

    public init(range: ClosedRange<Date>, reason: Reason, ongoing: Bool = false) {
        self.range = range
        self.reason = reason
        self.ongoing = ongoing
    }

    public var seconds: TimeInterval { range.upperBound.timeIntervalSince(range.lowerBound) }

    /// "Not recorded: this Mac was asleep." ("Not recording: …" while it goes on.)
    public var sentence: String {
        (ongoing ? "Not recording" : "Not recorded") + (reason.words.map { ": \($0)." } ?? ".")
    }
}

public enum RecordingGaps {
    /// Shorter than this isn't said (a reconnect after a hiccup, a segment's end and the next's start).
    public static let shortest: TimeInterval = 120
    /// How far before a gap's start what caused it may have been recorded (a stall's ten seconds, a few retries).
    static let before: TimeInterval = 120

    /// A camera's gaps between `coverage` (its recordings, in time order, joined where they meet), less its
    /// private stretches; and from its last recording to `through` (when given: it isn't recording now). `incidents`
    /// are every camera's and the Mac's, from a little before the first gap.
    public static func find(camera: String, coverage: [ClosedRange<Date>], through: Date? = nil,
                            privateSpans: [ClosedRange<Date>] = [], incidents: [HealthIncident]) -> [RecordingGap] {
        let sorted = coverage.sorted { $0.lowerBound < $1.lowerBound }
        var holes: [(ClosedRange<Date>, Bool)] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.lowerBound > a.upperBound {
            holes.append((a.upperBound ... b.lowerBound, false))
        }
        if let through, let last = sorted.last?.upperBound, through > last { holes.append((last ... through, true)) }
        let all = incidents.sorted { $0.time < $1.time }
        let macWide = HealthDiagnosis.macWideTimes(all)
        var gaps: [RecordingGap] = []
        for (hole, ongoing) in holes {
            for piece in subtract(privateSpans, from: hole)
            where piece.upperBound.timeIntervalSince(piece.lowerBound) >= shortest {
                gaps.append(RecordingGap(range: piece, reason: reason(camera: camera, gap: piece, incidents: all, macWide: macWide),
                                         ongoing: ongoing && piece.upperBound == hole.upperBound))
            }
        }
        return gaps
    }

    /// What's left of `range` outside `spans`.
    static func subtract(_ spans: [ClosedRange<Date>], from range: ClosedRange<Date>) -> [ClosedRange<Date>] {
        var pieces = [range]
        for span in spans {
            pieces = pieces.flatMap { piece -> [ClosedRange<Date>] in
                guard span.upperBound > piece.lowerBound, span.lowerBound < piece.upperBound else { return [piece] }
                var out: [ClosedRange<Date>] = []
                if span.lowerBound > piece.lowerBound { out.append(piece.lowerBound ... span.lowerBound) }
                if span.upperBound < piece.upperBound { out.append(span.upperBound ... piece.upperBound) }
                return out
            }
        }
        return pieces
    }

    /// Its likeliest reason: this Mac's side first (asleep, off, the recorder stopped: everything stops, whatever
    /// the camera was doing), then the drive, then what the camera did as it began, then the recorder starting
    /// again within it with no stop recorded (it quit, or the power went).
    static func reason(camera: String, gap: ClosedRange<Date>, incidents all: [HealthIncident], macWide: [Date]) -> RecordingGap.Reason {
        let start = gap.lowerBound, end = gap.upperBound
        let lead = start.addingTimeInterval(-before)
        func mac(_ kind: HealthIncident.Kind, from: Date, to: Date) -> HealthIncident? {
            all.last { $0.kind == kind && $0.time >= from && $0.time <= to }
        }
        // Asleep: it went to sleep just before, or during (recording ends as the Mac does).
        if mac(.macSleeping, from: lead, to: end) != nil { return .macAsleep }
        if mac(.macStarted, from: lead, to: end) != nil { return .macOff }
        if mac(.serviceStopped, from: lead, to: end) != nil { return .recorderStopped }
        // The drive: this camera's, or any's (they share it).
        let drive: [HealthIncident] = all.filter { (incident: HealthIncident) -> Bool in
            incident.kind == .storageFailed && incident.time >= lead && incident.time <= end
        }
        if let failed = drive.last(where: { $0.camera == camera }) ?? drive.last {
            return .storage(failed.detail ?? "the recordings drive couldn\u{2019}t be written to")
        }
        // What the camera did as it began.
        let mine = all.last { $0.camera == camera && $0.time >= lead && $0.time <= start.addingTimeInterval(60)
                              && cameraKinds.contains($0.kind) }
        if let mine {
            switch mine.kind {
            case .unreachable:
                return macWide.contains { abs($0.timeIntervalSince(mine.time)) < 60 } ? .macNetwork : .unreachable
            case .loginRefused: return .loginRefused
            case .privacyMode: return .privacyMode
            case .wakeFailed: return .didntWake
            case .restarted: return .restarted
            default: return .videoStopped
            }
        }
        if mac(.serviceStarted, from: start, to: end.addingTimeInterval(before)) != nil { return .recorderNotRunning }
        return .unknown
    }

    static let cameraKinds: Set<HealthIncident.Kind> = [.stalled, .unreachable, .loginRefused, .failed, .privacyMode, .wakeFailed,
                                                        .restarted]
}
