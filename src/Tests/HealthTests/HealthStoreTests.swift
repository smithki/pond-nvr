import Foundation
import NVRCore
import Testing
@testable import Health

@Suite struct HealthStoreTests {
    static func store() throws -> (HealthStore, String) {
        let dir = NSTemporaryDirectory() + "pond-health-\(UUID().uuidString)"
        let store = try #require(HealthStore(path: dir + "/pond.sqlite"))
        return (store, dir)
    }

    @Test func incidentsComeBackInOrder() throws {
        let (store, dir) = try Self.store()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let now = Date()
        store.record(HealthIncident(camera: "porch", time: now, kind: .stalled, detail: "no video for 10 s"))
        store.record(HealthIncident(camera: "porch", time: now.addingTimeInterval(-60), kind: .connected))
        store.flush()
        let read = store.incidents(since: now.addingTimeInterval(-3600))
        #expect(read.map(\.kind) == [.connected, .stalled])
        #expect(read.last?.detail == "no video for 10 s")
    }

    @Test func partsOfTheSameFiveMinutesAddUp() throws {
        let (store, dir) = try Self.store()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var a = HealthSample(camera: "porch", start: Date())
        a.received = 100
        a.lost = 2
        a.clockOffset = 3
        var b = HealthSample(camera: "porch", start: a.start)
        b.received = 50
        b.controlsFailed = 1
        store.add(a)
        store.add(b)
        store.flush()
        let read = store.samples(since: a.start, camera: "porch")
        #expect(read.count == 1)
        #expect(read[0].received == 150 && read[0].lost == 2 && read[0].controlsFailed == 1 && read[0].clockOffset == 3)
    }

    @Test func aWeekIsKept() throws {
        let (store, dir) = try Self.store()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let now = Date()
        store.record(HealthIncident(camera: "porch", time: now.addingTimeInterval(-8 * 86400), kind: .stalled))
        store.record(HealthIncident(camera: "porch", time: now.addingTimeInterval(-6 * 86400), kind: .stalled))
        store.prune(now: now)
        store.flush()
        #expect(store.incidents(since: .distantPast).count == 1)
    }

    @Test func theAppReadsWhatTheServiceWrites() throws {
        let (store, dir) = try Self.store()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        store.record(HealthIncident(camera: "porch", kind: .connected))
        store.flush()
        let reader = try #require(HealthStore(path: dir + "/pond.sqlite", readOnly: true))
        #expect(reader.incidents(since: .distantPast).map(\.kind) == [.connected])
    }
}

@Suite struct PrivateSpanTests {
    @Test func privateStretchesFromChanges() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let changes: [(String, Date, Bool)] = [
            ("porch", t.addingTimeInterval(-500), true),    // private before the window
            ("porch", t.addingTimeInterval(100), false),
            ("porch", t.addingTimeInterval(200), true),     // still private at its end
            ("drive", t.addingTimeInterval(300), true),
            ("drive", t.addingTimeInterval(310), true),     // told twice: one stretch
            ("drive", t.addingTimeInterval(400), false),
            ("yard", t.addingTimeInterval(50), false),      // public, never private
        ]
        let spans = HealthStore.spans(changes, from: t, to: t.addingTimeInterval(1000))
        #expect(spans["porch"] == [t ... t.addingTimeInterval(100), t.addingTimeInterval(200) ... t.addingTimeInterval(1000)])
        #expect(spans["drive"] == [t.addingTimeInterval(300) ... t.addingTimeInterval(400)])
        #expect(spans["yard"] == nil)
    }
}
