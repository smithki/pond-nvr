import Foundation
import Testing
@testable import PondCore

@Suite struct StorageLocationTests {
    @Test func missingFolderIsMissing() throws {
        let dir = try TempDir()
        #expect(StorageLocation.status(of: dir.file("unplugged")) == .missing)
    }

    @Test func unmarkedFolderIsNotPrepared() throws {
        let dir = try TempDir()
        #expect(StorageLocation.status(of: dir.path) == .notPrepared)
    }

    @Test func prepareCreatesAndMarks() throws {
        let dir = try TempDir()
        let folder = dir.file("recordings")
        let id = try StorageLocation.prepare(folder)
        #expect(StorageLocation.status(of: folder) == .ready(id: id))
        // Choosing the same folder again keeps its id.
        #expect(try StorageLocation.prepare(folder) == id)
        // No test files are left behind by the write check.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == [StorageLocation.markerName])
    }

    @Test func prepareMarksAnExistingFolder() throws {
        let dir = try TempDir()
        let id = try StorageLocation.prepare(dir.path)
        #expect(StorageLocation.status(of: dir.path) == .ready(id: id))
    }

    @Test func prepareRefusesAMissingParent() throws {
        let dir = try TempDir()
        let parent = dir.file("Pond")
        #expect(throws: StorageLocation.PrepareError.parentMissing(parent)) {
            try StorageLocation.prepare(dir.file("Pond/recordings"))
        }
        #expect(!FileManager.default.fileExists(atPath: parent))
    }

    // /Volumes/Pond missing means the drive is not mounted; creating it would record onto the boot disk.
    @Test func prepareRefusesANewFolderInVolumes() {
        #expect(throws: StorageLocation.PrepareError.directlyInVolumes) {
            try StorageLocation.prepare("/Volumes/pond-test-not-a-drive")
        }
        #expect(throws: StorageLocation.PrepareError.notFullPath) {
            try StorageLocation.prepare("relative")
        }
    }

    @Test func spaceIsReported() throws {
        let dir = try TempDir()
        let space = try #require(StorageLocation.space(of: dir.path))
        #expect(space.total > 0)
        #expect(space.free > 0 && space.free <= space.total)
    }
}
