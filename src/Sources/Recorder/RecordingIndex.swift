// What continuous recording covers between two times, for the app's timeline: each camera's segments in
// order, each with an end. A segment file is named by its first frame only, so its end is taken as the next
// segment's start when that follows closely, or as one nominal segment length otherwise (a gap follows).
import Foundation
import NVRCore

public struct RecordedSpan: Equatable, Sendable {
    public var path: String
    public var start: Date
    public var end: Date

    public init(path: String, start: Date, end: Date) {
        self.path = path
        self.start = start
        self.end = end
    }

    public var seconds: Double { end.timeIntervalSince(start) }

    /// Still being written (".mp4.partial"): playable as far as it's written, a 2-second fragment at a time.
    public var isBeingWritten: Bool { path.hasSuffix(".partial") }
}

public enum RecordingIndex {
    /// The nominal length of a continuous segment (`pond run` cuts at the first keyframe after 60 s).
    public static let segmentSeconds = 60.0
    /// Slack for that keyframe: a later segment starting within this many seconds of the nominal end
    /// follows without a gap.
    static let joinSlack = 8.0

    /// One camera's segments overlapping `from ..< to`, oldest first. Only the day folders that can hold
    /// them are read. `writing`: with the segment being written (and any a crash left), as far as they go.
    public static func spans(base: String, camera: String, from: Date, to: Date, writing: Bool = false) -> [RecordedSpan] {
        let top = SegmentFiles.cameraFolder(root: base, camera: camera)
        let days = DateFormatter()
        days.locale = Locale(identifier: "en_US_POSIX")
        days.timeZone = TimeZone(identifier: "UTC")
        days.dateFormat = "yyyy-MM-dd"
        var folders: [String] = []
        // From the day before `from` (its last segment may run past midnight) through `to`'s day.
        var day = from.addingTimeInterval(-segmentSeconds)
        while day < to.addingTimeInterval(86400) {
            let name = days.string(from: day)
            if folders.last != name { folders.append(name) }
            day = day.addingTimeInterval(86400)
        }
        let fm = FileManager.default
        var starts: [(Date, String)] = []
        for folder in folders {
            for name in (try? fm.contentsOfDirectory(atPath: "\(top)/\(folder)")) ?? []
                where name.hasSuffix(".mp4") || (writing && name.hasSuffix(".mp4.partial")) {
                let stem = String(name.dropLast(4).prefix(8))   // HH-MM-SS, without any -n suffix
                guard let start = RetentionSweeper.nameFormatter.date(from: "\(folder)/\(stem)") else { continue }
                starts.append((start, "\(top)/\(folder)/\(name)"))
            }
        }
        starts.sort { $0.0 < $1.0 }
        return join(starts).filter { $0.end > from && $0.start < to }
    }

    /// Gives each segment start an end.
    static func join(_ starts: [(Date, String)]) -> [RecordedSpan] {
        var out: [RecordedSpan] = []
        for (i, (start, path)) in starts.enumerated() {
            var end = start.addingTimeInterval(segmentSeconds)
            if i + 1 < starts.count {
                let next = starts[i + 1].0
                if next.timeIntervalSince(start) <= segmentSeconds + joinSlack { end = max(start, next) }
            }
            out.append(RecordedSpan(path: path, start: start, end: end))
        }
        return out
    }

    /// When a camera's earliest recording starts: its first day folder's first segment. Cheap, whatever the
    /// span of recording: only that one folder is read.
    public static func earliest(base: String, camera: String) -> Date? {
        let top = SegmentFiles.cameraFolder(root: base, camera: camera)
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(atPath: top)) ?? []).filter { $0.count == 10 }.sorted()
        for folder in days {
            let starts = ((try? fm.contentsOfDirectory(atPath: "\(top)/\(folder)")) ?? [])
                .filter { $0.hasSuffix(".mp4") }
                .compactMap { RetentionSweeper.nameFormatter.date(from: "\(folder)/\(String($0.dropLast(4).prefix(8)))") }
            if let first = starts.min() { return first }
        }
        return nil
    }

    /// Merges touching spans into continuous stretches, for drawing.
    public static func coverage(_ spans: [RecordedSpan], tolerance: Double = 1) -> [ClosedRange<Date>] {
        var out: [ClosedRange<Date>] = []
        for span in spans {
            if let last = out.last, span.start.timeIntervalSince(last.upperBound) <= tolerance {
                out[out.count - 1] = last.lowerBound ... max(last.upperBound, span.end)
            } else {
                out.append(span.start ... span.end)
            }
        }
        return out
    }
}
