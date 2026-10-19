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

/// The segment being written: from `start` (its first frame) through `through` (as far as it's written).
public struct LiveSegment: Equatable, Sendable {
    public var path: String
    public var start: Date
    public var through: Date

    public init(path: String, start: Date, through: Date) {
        self.path = path
        self.start = start
        self.through = through
    }
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
                guard let start = Self.start(folder: folder, name: name) else { continue }
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

    /// The segment a camera's recorder is writing now, and how far: its start (from its name) and the time its
    /// file was last written (each 2-second fragment, as it's added: what's recorded reaches about there). Cheap:
    /// the file `known` (the last one found) is looked at alone while it's still being written; else the day
    /// folders (today's and yesterday's, UTC) are listed for the newest. Nil if none is being written.
    public static func beingWritten(base: String, camera: String, known: String? = nil, now: Date = Date()) -> LiveSegment? {
        let fm = FileManager.default
        if let known, let segment = liveSegment(path: known) { return segment }
        let top = SegmentFiles.cameraFolder(root: base, camera: camera)
        let days = DateFormatter()
        days.locale = Locale(identifier: "en_US_POSIX")
        days.timeZone = TimeZone(identifier: "UTC")
        days.dateFormat = "yyyy-MM-dd"
        for day in [now, now.addingTimeInterval(-86400)].map(days.string(from:)) {
            let names = ((try? fm.contentsOfDirectory(atPath: "\(top)/\(day)")) ?? []).filter { $0.hasSuffix(".mp4.partial") }
            if let newest = names.max(), let segment = liveSegment(path: "\(top)/\(day)/\(newest)") { return segment }
        }
        return nil
    }

    /// A segment file being written: its start from its name, how far from when it was last written.
    static func liveSegment(path: String) -> LiveSegment? {
        guard path.hasSuffix(".mp4.partial"),
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count >= 2,
              let start = start(folder: String(parts[parts.count - 2]), name: String(parts[parts.count - 1]))
        else { return nil }
        return LiveSegment(path: path, start: start, through: max(start, modified))
    }

    /// When a segment starts, from its day folder and its name: "HH-MM-SS.mmm.mp4" (to the millisecond), or
    /// "HH-MM-SS.mp4" from before; either with a "-n" clash suffix, or ".partial" while it's written.
    public static func start(folder: String, name: String) -> Date? {
        guard let whole = RetentionSweeper.nameFormatter.date(from: "\(folder)/\(name.prefix(8))") else { return nil }
        let rest = name.dropFirst(8)
        guard rest.first == ".", let digits = Int(rest.dropFirst().prefix(3)), rest.dropFirst().prefix(3).count == 3 else { return whole }
        return whole.addingTimeInterval(Double(digits) / 1000)
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
                .compactMap { start(folder: folder, name: $0) }
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
