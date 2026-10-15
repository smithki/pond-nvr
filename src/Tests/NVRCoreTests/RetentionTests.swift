import Foundation
import Testing
@testable import NVRCore

@Suite struct RetentionTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let gb: Int64 = 1_000_000_000

    /// One continuous file per hour going back `hours`, `size` bytes each; oldest first.
    static func continuous(hours: Int, size: Int64 = gb) -> [RecordedFile] {
        (1 ... hours).reversed().map { h in
            RecordedFile(path: "c\(h)", camera: "porch", kind: .continuous,
                         start: now.addingTimeInterval(-Double(h) * 3600), bytes: size)
        }
    }

    static func event(daysAgo: Double, size: Int64 = 50_000_000) -> RecordedFile {
        RecordedFile(path: "e\(daysAgo)", camera: "porch", kind: .event,
                     start: now.addingTimeInterval(-daysAgo * 86400), bytes: size)
    }

    static let plenty = VolumeSpace(total: 2000 * gb, free: 1000 * gb)

    @Test func nothingToDoWithinLimits() {
        let plan = Retention.plan(files: Self.continuous(hours: 48) + [Self.event(daysAgo: 2)],
                                  policy: .init(), now: Self.now, space: Self.plenty)
        #expect(plan == RetentionPlan(deletions: [], warnings: []))
    }

    @Test func oldContinuousAndOldEventsGoByAge() {
        let policy = Config.Retention(continuous: .init(days: 1), events: .init(days: 30))
        let files = Self.continuous(hours: 30) + [Self.event(daysAgo: 31), Self.event(daysAgo: 29)]
        let plan = Retention.plan(files: files, policy: policy, now: Self.now, space: Self.plenty)
        // Hours 25...30 are older than a day.
        #expect(plan.deletions.map(\.path) == ["c30", "c29", "c28", "c27", "c26", "c25", "e31.0"])
        #expect(plan.warnings == [])
    }

    @Test func sizeCapDeletesOldestContinuous() {
        let policy = Config.Retention(continuous: .init(days: 7, maxSizeGB: 10))
        let plan = Retention.plan(files: Self.continuous(hours: 12), policy: policy, now: Self.now, space: Self.plenty)
        #expect(plan.deletions.map(\.path) == ["c12", "c11"])
    }

    @Test func lowSpaceOverwritesOldestContinuousAndWarns() {
        // 20 GB free with a 25 GB reserve: the 5 oldest 1 GB hours go.
        let space = VolumeSpace(total: 2000 * Self.gb, free: 20 * Self.gb)
        let plan = Retention.plan(files: Self.continuous(hours: 48), policy: .init(), now: Self.now, space: space)
        #expect(plan.deletions.map(\.path) == ["c48", "c47", "c46", "c45", "c44"])
        #expect(plan.bytesFreed == 5 * Self.gb)
        #expect(plan.warnings == ["Only 1.8 of the 7 days of continuous recording fit on the drive."])
    }

    @Test func spaceFreedByAgeCountsTowardTheReserve() {
        let policy = Config.Retention(continuous: .init(days: 1))
        let space = VolumeSpace(total: 2000 * Self.gb, free: 20 * Self.gb)
        // Hours 25...30 expire (6 GB), which already makes 26 GB free.
        let plan = Retention.plan(files: Self.continuous(hours: 30), policy: policy, now: Self.now, space: space)
        #expect(plan.deletions.count == 6)
        #expect(plan.warnings == [])
    }

    @Test func eventClipsAreNeverDeletedForSpace() {
        let space = VolumeSpace(total: 100 * Self.gb, free: 1 * Self.gb)
        let files = Self.continuous(hours: 2) + [Self.event(daysAgo: 1, size: 90 * Self.gb)]
        let plan = Retention.plan(files: files, policy: .init(), now: Self.now, space: space)
        #expect(plan.deletions.map(\.path) == ["c2", "c1"])
        #expect(plan.warnings.count == 1)
        #expect(plan.warnings[0].hasPrefix("The drive is 22.0 GB short of the 25 GB to keep free"))
    }

    @Test func noSpaceInformationMeansAgeAndCapOnly() {
        let plan = Retention.plan(files: Self.continuous(hours: 3), policy: .init(), now: Self.now, space: nil)
        #expect(plan.deletions == [])
    }
}
