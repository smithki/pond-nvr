import PondCore
import SwiftUI
import Testing
@testable import PondApp

@Suite struct StorageImpactTests {
    /// A 1 TB drive with 900 GB free, and one camera recording 25 GB a day.
    static func outlook() -> StorageOutlook {
        let drive = DriveFacts(volume: "/Volumes/Pond", name: "Pond", isInternal: false, isStartupDisk: false, format: "APFS",
                               total: 1_000_000_000_000, free: 900_000_000_000, spotlightIndexing: false)
        let cameras = [StorageEstimate.Camera(id: "porch", rate: 25e9 / 86400, source: .recorded)]
        return StorageOutlook(estimate: nil, drive: drive, keepDays: 14, used: 0, cameras: cameras)
    }

    @Test func aCameraThatFits() throws {
        let camera = StorageEstimate.Camera(id: "yard", rate: 25e9 / 86400, source: .checked)
        let impact = try #require(Self.outlook().adding(camera, eventDays: 30, maxContinuousGB: nil, minFreeGB: 50))
        #expect(impact.fits)
        #expect(abs(impact.perDay - 25e9) < 1e6)
        #expect(abs(impact.after.continuousPerDay - 50e9) < 1e6)
    }

    @Test func aCameraThatTipsItOver() throws {
        // 200 GB a day more: 225 GB a day won't fit 14 days in about 840 GB.
        let camera = StorageEstimate.Camera(id: "yard", rate: 200e9 / 86400, source: .checked)
        var outlook = Self.outlook()
        outlook.estimate = outlook.estimate(eventDays: 30, maxContinuousGB: nil, minFreeGB: 50)
        let impact = try #require(outlook.adding(camera, eventDays: 30, maxContinuousGB: nil, minFreeGB: 50))
        #expect(!impact.fits)
        #expect(impact.fittedBefore)
    }

    @MainActor @Test func theNewCameraIsAPartOfTheBar() throws {
        let camera = StorageEstimate.Camera(id: "yard", rate: 25e9 / 86400, source: .checked)
        let impact = try #require(Self.outlook().adding(camera, eventDays: 30, maxContinuousGB: nil, minFreeGB: 50))
        let segments = StorageBar.segments(drive: impact.drive, used: impact.used, estimate: impact.after,
                                           keepDays: impact.keepDays, reserveGB: impact.reserveGB, newCamera: ("Yard", camera.rate))
        let yard = try #require(segments.first { $0.name == "Yard" })
        let others = try #require(segments.first { $0.name == "Other cameras" })
        // Two cameras at the same rate: half each of 14 days at 50 GB a day.
        #expect(abs(yard.bytes - 350e9) < 1e6)
        #expect(abs(others.bytes - 350e9) < 1e6)
        #expect(abs(segments.reduce(0) { $0 + $1.bytes } - 1e12) < 1e6)
    }
}
