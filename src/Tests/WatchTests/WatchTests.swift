import Detection
import Foundation
import NVRCore
import Testing
@testable import Watch

@Suite struct MotionGateTests {
    @Test func aCellThatChangesMovesAndTheBackgroundFollowsSlowly() {
        var gate = MotionGate(columns: 4, rows: 4, threshold: 18, learning: 0.05, minimumCells: 1)
        let still = [Float](repeating: 100, count: 16)
        #expect(!gate.moving(still).isMoving)            // the first: the background
        #expect(!gate.moving(still).isMoving)
        var someone = still
        someone[5] = 200
        let mask = gate.moving(someone)
        #expect(mask.cells == [5])
        // The cell at row 1, column 1 is covered by a box over the picture's second quarter each way.
        #expect(mask.overlaps((0.25, 0.25, 0.2, 0.2)))
        #expect(!mask.overlaps((0.75, 0.75, 0.2, 0.2)))
        // Daylight brightening slowly is followed, not moving.
        var gentle = MotionGate(columns: 4, rows: 4, minimumCells: 1)
        for step in 0 ..< 100 { _ = gentle.moving(still.map { $0 + Float(step) * 0.5 }) }
        #expect(!gentle.moving(still.map { $0 + 50 }).isMoving)
    }

    @Test func aSpeckOfNoiseIsntMotion() {
        var gate = MotionGate(columns: 4, rows: 4, minimumCells: 3)
        let still = [Float](repeating: 100, count: 16)
        _ = gate.moving(still)
        var speck = still
        speck[0] = 255
        #expect(!gate.moving(speck).isMoving)
    }
}

@Suite struct TrackerTests {
    static func person(_ x: Double, confidence: Double = 0.9) -> Detection {
        Detection(label: "person", category: .person, confidence: confidence, box: .init(x: x, y: 0.2, width: 0.2, height: 0.6))
    }

    static let everything = MotionMask(columns: 1, rows: 1, cells: [0])
    static let nothing = MotionMask(columns: 1, rows: 1, cells: [])

    @Test func someoneWalkingIsOneTrack() {
        var tracker = Tracker()
        let t0 = Date()
        var ids = Set<Int>()
        for step in 0 ..< 5 {
            for s in tracker.update([Self.person(0.1 + Double(step) * 0.03)], mask: Self.everything, at: t0.addingTimeInterval(Double(step) * 0.25)) {
                ids.insert(s.track.id)
            }
        }
        #expect(ids.count == 1)
        #expect(tracker.tracks.first?.seen == 5)
    }

    @Test func twoPeopleApartAreTwoTracksAndTheUnseenAreForgotten() {
        var tracker = Tracker()
        let t0 = Date()
        let both = tracker.update([Self.person(0.0), Self.person(0.7)], mask: Self.everything, at: t0)
        #expect(Set(both.map(\.track.id)).count == 2)
        _ = tracker.update([], mask: Self.nothing, at: t0.addingTimeInterval(10))
        #expect(tracker.tracks.isEmpty)
    }

    @Test func somethingNeverSeenWhereThingsMoveHasntMoved() {
        var tracker = Tracker()
        let parked = Detection(label: "car", category: .vehicle, confidence: 0.8, box: .init(x: 0.6, y: 0.4, width: 0.2, height: 0.1))
        let mask = MotionMask(columns: 4, rows: 4, cells: [0])   // movement only at the top left
        let seen = tracker.update([parked], mask: mask, at: Date())
        #expect(seen.first?.track.moved == false)
    }
}

@Suite struct EventBuilderTests {
    static let moving = MotionMask(columns: 1, rows: 1, cells: [0])

    @Test func aPersonWalkingPastIsOneEventThatEndsWhenQuiet() {
        var tracker = Tracker()
        var builder = EventBuilder(camera: "porch")
        let t0 = Date()
        var changes: [EventBuilder.Change] = []
        for step in 0 ..< 8 {
            let time = t0.addingTimeInterval(Double(step) * 0.5)
            let d = TrackerTests.person(0.1 + Double(step) * 0.05, confidence: step == 4 ? 0.97 : 0.8)
            changes += builder.update(tracker.update([d], mask: Self.moving, at: time), at: time)
        }
        // Begun on the second sighting; a better picture at the surest one.
        #expect(changes.filter { if case .began = $0 { true } else { false } }.count == 1)
        #expect(changes.contains { if case let .better(e) = $0 { e.confidence == 0.97 } else { false } })
        // Quiet for longer than it waits: ended.
        let ended = builder.quiet(at: t0.addingTimeInterval(4 + 7))
        guard case let .ended(event)? = ended.first else {
            Issue.record("no end")
            return
        }
        #expect(event.category == .person && event.labels == ["person": 1])
        #expect(event.start == t0)
        #expect(builder.current == nil)
    }

    @Test func aParkedCarAloneMakesNoEvent() {
        var tracker = Tracker()
        var builder = EventBuilder(camera: "porch")
        let t0 = Date()
        let still = MotionMask(columns: 1, rows: 1, cells: [])
        let car = Detection(label: "car", category: .vehicle, confidence: 0.8, box: .init(x: 0.6, y: 0.4, width: 0.2, height: 0.1))
        var changes: [EventBuilder.Change] = []
        for step in 0 ..< 10 {
            let time = t0.addingTimeInterval(Double(step))
            changes += builder.update(tracker.update([car], mask: still, at: time), at: time)
        }
        #expect(changes.isEmpty)
    }

    @Test func aPersonOutranksAVehicleInTheSameEvent() {
        var tracker = Tracker()
        var builder = EventBuilder(camera: "drive")
        let t0 = Date()
        let car = Detection(label: "car", category: .vehicle, confidence: 0.9, box: .init(x: 0.5, y: 0.5, width: 0.3, height: 0.2))
        for step in 0 ..< 3 {
            let time = t0.addingTimeInterval(Double(step) * 0.5)
            _ = builder.update(tracker.update([car], mask: Self.moving, at: time), at: time)
        }
        #expect(builder.current?.category == .vehicle)
        for step in 3 ..< 6 {
            let time = t0.addingTimeInterval(Double(step) * 0.5)
            _ = builder.update(tracker.update([car, TrackerTests.person(0.1, confidence: 0.7)], mask: Self.moving, at: time), at: time)
        }
        #expect(builder.current?.category == .person)
        #expect(builder.current?.labels == ["car": 1, "person": 1])
    }
}

@Suite struct EventStoreTests {
    @Test func anEventIsKeptAsItGoesOnAndEnds() throws {
        let path = NSTemporaryDirectory() + "pond-events-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try #require(EventStore(path: path))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var event = CameraEvent(id: "e1", camera: "porch", start: t0, end: t0, category: .vehicle, labels: ["car": 1], confidence: 0.6)
        store.save(event, ongoing: true)
        event.end = t0.addingTimeInterval(9)
        event.category = .person
        event.labels = ["car": 1, "person": 1]
        event.snapshot = "events/porch/2027-01-15/08-00-00-e1.jpg"
        event.box = .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        store.save(event, ongoing: false)
        store.flush()
        let kept = store.events(since: t0.addingTimeInterval(-1))
        #expect(kept == [EventStore.Kept(event: event, ongoing: false)])
        #expect(store.events(since: t0, camera: "drive").isEmpty)
        store.prune(days: 1, now: t0.addingTimeInterval(2 * 86400))
        store.flush()
        #expect(store.events(since: .distantPast).isEmpty)
    }
}

@Suite struct ZoneTests {
    // The steps: the bottom middle of the picture.
    static let steps = Config.Zone(id: "steps", name: "Steps", points: [[0.3, 0.6], [0.7, 0.6], [0.7, 1], [0.3, 1]])
    static let road = Config.Zone(id: "road", name: "Road", points: [[0, 0], [1, 0], [1, 0.3], [0, 0.3]], kind: .ignore)

    static func thing(_ category: DetectedCategory, x: Double, bottom: Double) -> Detection {
        Detection(label: category.rawValue, category: category, confidence: 0.9, box: .init(x: x - 0.05, y: bottom - 0.2, width: 0.1, height: 0.2))
    }

    @Test func aZoneHoldsWhatStandsInIt() {
        #expect(Self.steps.contains(x: 0.5, y: 0.8))
        #expect(!Self.steps.contains(x: 0.1, y: 0.8))
        // Not convex: an L.
        let l = Config.Zone(id: "l", name: "L", points: [[0, 0], [0.5, 0], [0.5, 0.5], [1, 0.5], [1, 1], [0, 1]])
        #expect(l.contains(x: 0.25, y: 0.25) && l.contains(x: 0.75, y: 0.75) && !l.contains(x: 0.75, y: 0.25))
    }

    @Test func withWatchedZonesOnlyWhatsInOneCounts() {
        let rules = ZoneRules([Self.steps, Self.road])
        #expect(rules.zones(for: Self.thing(.person, x: 0.5, bottom: 0.9)) == ["steps"])
        // Its head in the zone, its feet not: not in it.
        #expect(rules.zones(for: Self.thing(.person, x: 0.1, bottom: 0.9)) == nil)
        // On the road: ignored.
        #expect(rules.zones(for: Self.thing(.vehicle, x: 0.5, bottom: 0.2)) == nil)
        // No zones: everything counts, in none.
        #expect(ZoneRules([]).zones(for: Self.thing(.person, x: 0.1, bottom: 0.2)) == [])
        // Only an ignored zone: everywhere else counts.
        #expect(ZoneRules([Self.road]).zones(for: Self.thing(.person, x: 0.1, bottom: 0.9)) == [])
    }

    @Test func aZoneTakesOnlyItsKinds() {
        var steps = Self.steps
        steps.categories = ["person", "package"]
        let rules = ZoneRules([steps])
        #expect(rules.zones(for: Self.thing(.package, x: 0.5, bottom: 0.9)) == ["steps"])
        #expect(rules.zones(for: Self.thing(.animal, x: 0.5, bottom: 0.9)) == nil)
    }

    @Test func motionInAnIgnoredZoneDoesntCount() {
        let ignored = ZoneRules([Self.road]).ignoredCells(columns: 4, rows: 4)
        #expect(ignored == [0, 1, 2, 3])          // the top row
        var gate = MotionGate(columns: 4, rows: 4, minimumCells: 1)
        gate.ignored = ignored
        let still = [Float](repeating: 100, count: 16)
        _ = gate.moving(still)
        var trees = still
        trees[1] = 200
        #expect(!gate.moving(trees).isMoving)
    }

    @Test func anEventKeepsTheZonesItWasIn() {
        var tracker = Tracker()
        var builder = EventBuilder(camera: "porch")
        let rules = ZoneRules([Self.steps])
        let t0 = Date()
        for step in 0 ..< 3 {
            let time = t0.addingTimeInterval(Double(step) * 0.5)
            let found = [Self.thing(.person, x: 0.5, bottom: 0.9)].compactMap { d in rules.zones(for: d).map { (d, $0) } }
            let sightings = tracker.update(found.map(\.0), mask: EventBuilderTests.moving, at: time) { d in found.first { $0.0 == d }?.1 ?? [] }
            _ = builder.update(sightings, at: time)
        }
        #expect(builder.current?.zones == ["steps"])
    }
}
