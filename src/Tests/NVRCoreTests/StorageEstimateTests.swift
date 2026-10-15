import Testing
@testable import NVRCore

@Suite struct StorageEstimateTests {
    /// 3 Mbit/s, 375 kB/s: 32.4 GB a day.
    let camera = StorageEstimate.Camera(id: "a", rate: 375_000, source: .recorded)

    @Test func daysAfterEventsHaveTheirShare() throws {
        let e = try #require(StorageEstimate(cameras: [camera], room: 1e12, eventDays: 30))
        #expect(abs(e.continuousPerDay - 32.4e9) < 1)
        // 20 events × (30 s × 375 kB + 300 kB) = 231 MB a day; 30 days of them reserved.
        #expect(abs(e.eventsPerDay - 231e6) < 1)
        #expect(abs(e.eventsReserved - 6.93e9) < 1)
        #expect(abs(e.continuousDays - (1e12 - 6.93e9) / 32.4e9) < 1e-9)
        #expect(e.source == .recorded)
    }

    @Test func theLimitCaps() throws {
        let e = try #require(StorageEstimate(cameras: [camera], room: 1e12, eventDays: 30, maxContinuous: 324e9))
        #expect(abs(e.continuousDays - 10) < 1e-9)
    }

    @Test func noRoomNoDays() throws {
        let e = try #require(StorageEstimate(cameras: [camera], room: 1e9, eventDays: 30))
        #expect(e.continuousDays == 0)
    }

    @Test func theWeakestSourceShows() throws {
        let checked = StorageEstimate.Camera(id: "b", rate: 300_000, source: .checked)
        let assumed = StorageEstimate.Camera(id: "c", rate: StorageEstimate.typicalRate, source: .assumed)
        #expect(StorageEstimate(cameras: [camera, checked], room: 1e12, eventDays: 1)?.source == .checked)
        #expect(StorageEstimate(cameras: [camera, checked, assumed], room: 1e12, eventDays: 1)?.source == .assumed)
        #expect(StorageEstimate(cameras: [], room: 1e12, eventDays: 1) == nil)
    }

    @Test func durationsInWords() {
        #expect(StorageEstimate.duration(days: 41.7) == "41 days")
        #expect(StorageEstimate.duration(days: 1.5) == "1 day")
        #expect(StorageEstimate.duration(days: 0.75) == "18 hours")
        #expect(StorageEstimate.duration(days: 1.2 / 24) == "1 hour")
        #expect(StorageEstimate.duration(days: 0.5 / 24) == "30 minutes")
        #expect(StorageEstimate.size(32.4e9) == "32 GB")
        #expect(StorageEstimate.size(231e6) == "231 MB")
        #expect(StorageEstimate.size(1.775e12) == "1.8 TB")
    }
}
