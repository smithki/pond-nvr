import Foundation
import Testing
@testable import Recorder

@Suite struct LiveSegmentTests {
    /// A camera folder with a day's segments, in a temporary root.
    static func folder() throws -> (root: String, day: String) {
        let root = NSTemporaryDirectory() + "pond-live-\(UUID().uuidString)"
        let day = "\(root)/continuous/porch/2026-10-19"
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        return (root, day)
    }

    static func write(_ path: String, modified: Date) throws {
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }

    @Test func theSegmentBeingWrittenReachesItsLastWrite() throws {
        let (root, day) = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let start = try #require(RetentionSweeper.nameFormatter.date(from: "2026-10-19/06-01-48"))
        try Self.write("\(day)/06-00-46.mp4", modified: start)
        try Self.write("\(day)/06-01-48.mp4.partial", modified: start.addingTimeInterval(22))
        let now = start.addingTimeInterval(23)
        let live = try #require(RecordingIndex.beingWritten(base: root, camera: "porch", now: now))
        #expect(live.start == start && live.through == start.addingTimeInterval(22))
        #expect(live.path.hasSuffix("06-01-48.mp4.partial"))
    }

    @Test func aNewFileJustBegunReachesNoFurtherThanItsStart() throws {
        let (root, day) = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let start = try #require(RetentionSweeper.nameFormatter.date(from: "2026-10-19/06-02-50"))
        // Created a moment before the first frame it's named for (clocks): never before its start.
        try Self.write("\(day)/06-02-50.mp4.partial", modified: start.addingTimeInterval(-0.3))
        let live = try #require(RecordingIndex.beingWritten(base: root, camera: "porch", now: start))
        #expect(live.through == start)
    }

    @Test func whenTheFileIsFinishedTheNextIsFound() throws {
        let (root, day) = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let first = try #require(RetentionSweeper.nameFormatter.date(from: "2026-10-19/06-01-48"))
        try Self.write("\(day)/06-01-48.mp4.partial", modified: first.addingTimeInterval(60))
        let was = try #require(RecordingIndex.beingWritten(base: root, camera: "porch", now: first.addingTimeInterval(60)))
        // Renamed when done, and the next begun.
        try FileManager.default.moveItem(atPath: was.path, toPath: "\(day)/06-01-48.mp4")
        let next = first.addingTimeInterval(61)
        try Self.write("\(day)/06-02-49.mp4.partial", modified: next.addingTimeInterval(1))
        let now = try #require(RecordingIndex.beingWritten(base: root, camera: "porch", known: was.path, now: next.addingTimeInterval(2)))
        #expect(now.path.hasSuffix("06-02-49.mp4.partial") && abs(now.start.timeIntervalSince(next)) < 1)
        // Not recording: nothing being written.
        try FileManager.default.moveItem(atPath: now.path, toPath: "\(day)/06-02-49.mp4")
        #expect(RecordingIndex.beingWritten(base: root, camera: "porch", known: now.path, now: next.addingTimeInterval(5)) == nil)
    }
}
