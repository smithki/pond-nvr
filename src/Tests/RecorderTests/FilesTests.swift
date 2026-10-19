import Foundation
import NVRCore
import Testing
@testable import Recorder

final class TempFolder {
    let path: String
    init() throws {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("pond-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

@Suite struct SegmentFilesTests {
    static let wall = 1_767_225_600.0   // 2026-01-01 00:00:00 UTC

    @Test func segmentsAreWrittenAsPartialThenRenamed() throws {
        let dir = try TempFolder()
        try StorageLocation.prepare(dir.path)
        let log = MemoryLog()
        let files = SegmentFiles(root: dir.path, camera: "porch", log: log)
        files.handle([.start(initSegment: [1, 2], wallTime: Self.wall + 3723), .fragment([3, 4])])
        let final = "\(dir.path)/continuous/porch/2026-01-01/01-02-03.000.mp4"
        #expect(files.state == .writing(path: final))
        #expect(FileManager.default.fileExists(atPath: final + ".partial"))
        #expect(!FileManager.default.fileExists(atPath: final))
        files.handle([.fragment([5]), .end(SegmentSummary(wallTime: 0, seconds: 1, videoFrames: 1, audioFrames: 0))])
        #expect(FileManager.default.contents(atPath: final) == Data([1, 2, 3, 4, 5]))
        #expect(!FileManager.default.fileExists(atPath: final + ".partial"))
        #expect(files.completed == 1)
        #expect(files.state == .idle)
        // The same second again (a reconnect) does not overwrite.
        files.handle([.start(initSegment: [9], wallTime: Self.wall + 3723), .end(SegmentSummary(wallTime: 0, seconds: 0, videoFrames: 0, audioFrames: 0))])
        #expect(FileManager.default.contents(atPath: final.replacingOccurrences(of: ".mp4", with: "-1.mp4")) == Data([9]))
    }

    @Test func nothingIsWrittenToAMissingDrive() throws {
        let dir = try TempFolder()
        let root = dir.path + "/unplugged"
        let log = MemoryLog()
        let files = SegmentFiles(root: root, camera: "porch", log: log)
        files.handle([.start(initSegment: [1], wallTime: Self.wall), .fragment([2])])
        #expect(!FileManager.default.fileExists(atPath: root))
        guard case .unavailable = files.state else { Issue.record("expected unavailable"); return }
        #expect(log.lines == ["porch: not recording: the recordings folder \(root) is not found: plug in the drive or mount the share"])
        // Said once, not for every segment.
        files.handle([.end(SegmentSummary(wallTime: 0, seconds: 0, videoFrames: 0, audioFrames: 0)),
                      .start(initSegment: [1], wallTime: Self.wall + 60)])
        #expect(log.lines.count == 1)
        // The drive comes back.
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        try StorageLocation.prepare(root)
        files.handle([.start(initSegment: [1], wallTime: Self.wall + 120)])
        guard case .writing = files.state else { Issue.record("expected writing"); return }
        #expect(log.lines.last == "porch: recording to \(root) again")
    }

    @Test func partialFilesAreRecovered() throws {
        let dir = try TempFolder()
        let day = "\(dir.path)/continuous/porch/2026-01-01"
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(day)/00-00-00.mp4.partial", contents: Data([1]))
        FileManager.default.createFile(atPath: "\(day)/00-01-00.mp4.partial", contents: Data())
        #expect(SegmentFiles.recoverPartials(root: dir.path, camera: "porch") == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: day) == ["00-00-00.mp4"])
    }
}

@Suite struct RetentionSweeperTests {
    /// A prepared folder with continuous files for the given UTC times (yyyy-MM-dd/HH-mm-ss) of `bytes` each.
    func folder(_ names: [String], bytes: Int = 10) throws -> (TempFolder, Config) {
        let dir = try TempFolder()
        try StorageLocation.prepare(dir.path)
        for name in names {
            let path = "\(dir.path)/continuous/porch/\(name).mp4"
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data(repeating: 0, count: bytes))
        }
        var config = Config(storage: .init(recordings: dir.path, database: dir.path + "/db"))
        config.retention = .init(continuous: .init(days: 2), events: .init(days: 30), minFreeGB: 0)
        return (dir, config)
    }

    static let now = ISO8601DateFormatter().date(from: "2026-01-10T12:00:00Z")!

    @Test func listsFilesWithTheirTimes() throws {
        let (dir, _) = try folder(["2026-01-10/11-00-00", "2026-01-10/11-01-00-1"])
        FileManager.default.createFile(atPath: "\(dir.path)/continuous/porch/2026-01-10/11-02-00.mp4.partial", contents: Data())
        let files = RetentionSweeper.list(base: dir.path, folder: "continuous", kind: .continuous).sorted { $0.path < $1.path }
        #expect(files.count == 2)
        #expect(files[0].start == ISO8601DateFormatter().date(from: "2026-01-10T11:00:00Z"))
        #expect(files[1].start == ISO8601DateFormatter().date(from: "2026-01-10T11:01:00Z"))
        #expect(files[0].camera == "porch")
        #expect(files[0].bytes == 10)
    }

    @Test func deletesExpiredFilesAndEmptyFolders() throws {
        let (dir, config) = try folder(["2026-01-07/09-00-00", "2026-01-07/09-01-00", "2026-01-09/13-00-00", "2026-01-10/11-00-00"])
        let log = MemoryLog()
        let report = RetentionSweeper(config: config, log: log).sweep(now: Self.now)
        #expect(report.deletedFiles == 2)
        #expect(report.freedBytes == 20)
        #expect(!FileManager.default.fileExists(atPath: "\(dir.path)/continuous/porch/2026-01-07"))
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/continuous/porch/2026-01-09/13-00-00.mp4"))
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/.pond-storage"))
        #expect(log.lines == ["retention: deleted 2 files, 0.0 GB"])
        // A second pass has nothing to do and says nothing.
        #expect(RetentionSweeper(config: config, log: log).sweep(now: Self.now).deletedFiles == 0)
        #expect(log.lines.count == 1)
    }

    @Test func aMissingDriveIsLeftAlone() throws {
        let (dir, config) = try folder(["2026-01-01/00-00-00"])
        try FileManager.default.removeItem(atPath: "\(dir.path)/.pond-storage")
        #expect(RetentionSweeper(config: config, log: MemoryLog()).sweep(now: Self.now).deletedFiles == 0)
    }
}
