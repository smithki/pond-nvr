import Foundation
import Testing
@testable import Recorder

@Suite struct RecordingIndexTests {
    static let midnight = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01 00:00:00 UTC

    func touch(_ dir: String, _ relative: String) throws {
        let path = "\(dir)/continuous/porch/\(relative)"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data([0]))
    }

    @Test func segmentsJoinUntilAGap() throws {
        let dir = try TempFolder()
        try touch(dir.path, "2025-12-31/23-59-30.mp4")        // runs past midnight
        try touch(dir.path, "2026-01-01/00-00-31.mp4")        // 61 s later: joined
        try touch(dir.path, "2026-01-01/00-01-32.mp4")
        try touch(dir.path, "2026-01-01/00-10-00.mp4")        // after a gap
        try touch(dir.path, "2026-01-01/00-10-00-1.mp4")      // a reconnect in the same second
        try touch(dir.path, "2026-01-01/00-20-00.mp4.partial") // being written: not listed
        try touch(dir.path, "2026-01-02/00-00-00.mp4")        // outside the range

        let spans = RecordingIndex.spans(base: dir.path, camera: "porch", from: Self.midnight,
                                         to: Self.midnight.addingTimeInterval(3600))
        let offsets = spans.map { [$0.start.timeIntervalSince(Self.midnight), $0.end.timeIntervalSince(Self.midnight)] }
        #expect(offsets == [[-30, 31], [31, 92], [92, 152], [600, 600], [600, 660]])

        let coverage = RecordingIndex.coverage(spans).map {
            [$0.lowerBound.timeIntervalSince(Self.midnight), $0.upperBound.timeIntervalSince(Self.midnight)]
        }
        #expect(coverage == [[-30, 152], [600, 660]])
    }

    @Test func aMissingCameraHasNothing() throws {
        let dir = try TempFolder()
        #expect(RecordingIndex.spans(base: dir.path, camera: "none", from: Self.midnight,
                                     to: Self.midnight.addingTimeInterval(86400)).isEmpty)
    }

    @Test func earliestIsTheFirstSegmentOfTheFirstDay() throws {
        let dir = try TempFolder()
        try touch(dir.path, "2026-01-02/08-00-00.mp4")
        try touch(dir.path, "2025-12-31/23-59-30.mp4")
        try touch(dir.path, "2025-12-31/23-00-00.mp4")
        try FileManager.default.createDirectory(atPath: "\(dir.path)/continuous/porch/2025-12-30", withIntermediateDirectories: true)
        #expect(RecordingIndex.earliest(base: dir.path, camera: "porch") == Self.midnight.addingTimeInterval(-3600))
        #expect(RecordingIndex.earliest(base: dir.path, camera: "none") == nil)
    }
}
