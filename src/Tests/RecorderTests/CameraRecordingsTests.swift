import Foundation
import PondCore
import Testing
@testable import Recorder

@Suite struct CameraRecordingsTests {
    @Test func deletesOnlyThatCamerasFolders() throws {
        let dir = try TempFolder()
        let config = Config(storage: .init(recordings: dir.path, database: "\(dir.path)/db"))
        for path in ["continuous/porch/2026-01-01/00-00-00.mp4", "events/porch/2026-01-01/00-00-00.mp4",
                     "continuous/drive/2026-01-01/00-00-00.mp4"] {
            let full = "\(dir.path)/\(path)"
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: full, contents: Data(count: 10))
        }
        #expect(CameraRecordings.size(of: "porch", config: config) == 20)
        #expect(CameraRecordings.delete(of: "porch", config: config) == [])
        #expect(!FileManager.default.fileExists(atPath: "\(dir.path)/continuous/porch"))
        #expect(!FileManager.default.fileExists(atPath: "\(dir.path)/events/porch"))
        #expect(FileManager.default.fileExists(atPath: "\(dir.path)/continuous/drive/2026-01-01/00-00-00.mp4"))
        #expect(CameraRecordings.size(of: "porch", config: config) == 0)
    }
}
