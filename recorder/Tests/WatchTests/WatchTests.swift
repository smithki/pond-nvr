import Detection
import Foundation
import PondCore
import Testing
import Understanding
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

    /// A parked car at night: the picture over it flickers (noise, infrared, passing headlights), its box keeps
    /// within a hair of where it is; it never moves (it kept an event going for hours).
    @Test func aParkedCarFlickeringAtNightHasntMoved() {
        var tracker = Tracker()
        let t0 = Date()
        var moves = 0
        for step in 0 ..< 600 {
            let jitter = Double(step % 7 - 3) * 0.0007
            let car = Detection(label: "car", category: .vehicle, confidence: 0.85,
                                box: .init(x: 0.595 + jitter, y: 0.52, width: 0.141 + jitter, height: 0.072))
            for s in tracker.update([car], mask: Self.everything, at: t0.addingTimeInterval(Double(step) * 2)) where s.track.lastMoved == t0.addingTimeInterval(Double(step) * 2) {
                moves += 1
            }
        }
        // (Its first sighting only: where the picture changed when it was first seen.)
        #expect(moves == 1)
    }

    /// Someone walking slowly moves, though no one step's far: from where they last moved, it adds up.
    @Test func aSlowWalkerMoves() {
        var tracker = Tracker()
        let t0 = Date()
        var moves = 0
        for step in 0 ..< 20 {
            let time = t0.addingTimeInterval(Double(step) * 0.5)
            for s in tracker.update([Self.person(0.1 + Double(step) * 0.02)], mask: Self.everything, at: time) where s.track.lastMoved == time {
                moves += 1
            }
        }
        // 0.02 a step, a tenth of its size (0.6) in four: moved every few steps.
        #expect(moves >= 5)
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
        let ended = builder.quiet(at: t0.addingTimeInterval(4 + 11))
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
        // (Each moving: where the picture changed, and gone somewhere.)
        func car(_ step: Int) -> Detection {
            Detection(label: "car", category: .vehicle, confidence: 0.9, box: .init(x: 0.4 + Double(step) * 0.04, y: 0.5, width: 0.3, height: 0.2))
        }
        for step in 0 ..< 3 {
            let time = t0.addingTimeInterval(Double(step) * 0.5)
            _ = builder.update(tracker.update([car(step)], mask: Self.moving, at: time), at: time)
        }
        #expect(builder.current?.category == .vehicle)
        for step in 3 ..< 6 {
            let time = t0.addingTimeInterval(Double(step) * 0.5)
            let person = TrackerTests.person(0.05 + Double(step - 3) * 0.08, confidence: 0.7)
            _ = builder.update(tracker.update([car(step), person], mask: Self.moving, at: time), at: time)
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

    /// What's understood of events: kept piece by piece, found when it's still to do, and gone with the event.
    @Test func understandingIsKeptAndFoundWhenItsDue() throws {
        let path = NSTemporaryDirectory() + "pond-events-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try #require(EventStore(path: path))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for (i, id) in ["e1", "e2", "e3"].enumerated() {
            store.save(CameraEvent(id: id, camera: "porch", start: t0.addingTimeInterval(Double(i)), end: t0.addingTimeInterval(Double(i)),
                                   category: .person, labels: ["person": 1], confidence: 0.8, snapshot: "porch/\(id).jpg"),
                       ongoing: id == "e3")
        }
        store.flush()
        // Ended ones with pictures, newest first (the ongoing one, not yet).
        #expect(store.toUnderstand(describing: true, embedder: "siglip", limit: 10).map(\.id) == ["e2", "e1"])
        // A sentence for e2: still to embed; embeddings for it later don't lose the sentence.
        store.understood("e2", .init(description: "A person at the door."))
        #expect(store.toUnderstand(describing: true, embedder: "siglip", limit: 10).map(\.id) == ["e2", "e1"])
        store.understood("e2", .init(scene: [0.6, 0.8], subject: [1, 0], embedder: "siglip"))
        #expect(store.toUnderstand(describing: true, embedder: "siglip", limit: 10).map(\.id) == ["e1"])
        #expect(store.understanding(since: t0)["e2"] == .init(description: "A person at the door.", scene: [0.6, 0.8], subject: [1, 0],
                                                            embedder: "siglip"))
        // Asked and none came (""): not asked again. Another embedder: all to embed again.
        store.understood("e1", .init(description: "", embedder: "siglip"))
        #expect(store.toUnderstand(describing: true, embedder: "siglip", limit: 10).isEmpty)
        #expect(store.toUnderstand(describing: false, embedder: "siglip-3", limit: 10).map(\.id) == ["e2", "e1"])
        // Deleted, its understanding goes too.
        _ = store.delete(["e2"], now: t0)
        #expect(store.understanding(since: t0)["e2"] == nil)
    }

    /// Clips: asked for once an event's ended (and its minute's complete), kept with when they begin, and deleted with
    /// it; one that couldn't be made isn't asked for again.
    @Test func clipsAreAskedForKeptAndDeleted() throws {
        let path = NSTemporaryDirectory() + "pond-events-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try #require(EventStore(path: path))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for (i, id) in ["e1", "e2", "e3"].enumerated() {
            store.save(CameraEvent(id: id, camera: "porch", start: t0.addingTimeInterval(Double(i) * 10), end: t0.addingTimeInterval(Double(i) * 10 + 5),
                                   category: .person, labels: ["person": 1], confidence: 0.8, snapshot: "events/porch/\(id).jpg"),
                       ongoing: id == "e3")
        }
        store.flush()
        // Ended ones only, and only those ended before the time given; newest first.
        #expect(store.toClip(endedBefore: t0.addingTimeInterval(100), limit: 10).map(\.id) == ["e2", "e1"])
        #expect(store.toClip(endedBefore: t0.addingTimeInterval(10), limit: 10).map(\.id) == ["e1"])
        store.clipped("e1", clip: "events/porch/e1.mp4", start: t0.addingTimeInterval(-3))
        store.clipped("e2", clip: "", start: nil)
        #expect(store.toClip(endedBefore: t0.addingTimeInterval(100), limit: 10).isEmpty)
        let kept = store.events(since: t0.addingTimeInterval(-60))
        #expect(kept.first { $0.event.id == "e1" }?.clip == "events/porch/e1.mp4")
        #expect(kept.first { $0.event.id == "e1" }?.clipStart == t0.addingTimeInterval(-3))
        #expect(kept.first { $0.event.id == "e2" }?.clip == nil)
        // Deleted: its picture and its clip, to delete too.
        #expect(Set(store.delete(["e1"], now: t0)) == ["events/porch/e1.jpg", "events/porch/e1.mp4"])
    }

    /// A camera removed with its recordings: its events and sightings go, the others' stay.
    @Test func aRemovedCamerasEventsGo() throws {
        let path = NSTemporaryDirectory() + "pond-events-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try #require(EventStore(path: path))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for (id, camera) in [("e1", "porch"), ("e2", "drive"), ("e3", "porch")] {
            store.save(CameraEvent(id: id, camera: camera, start: t0, end: t0, category: .person, labels: ["person": 1], confidence: 0.8),
                       ongoing: false)
        }
        store.save([Sighting(camera: "porch", time: t0, label: "person", category: .person, confidence: 0.8, box: .init(x: 0, y: 0, width: 0.1, height: 0.2)),
                    Sighting(camera: "drive", time: t0, label: "car", category: .vehicle, confidence: 0.7, box: .init(x: 0, y: 0, width: 0.2, height: 0.1))])
        store.flush()
        store.deleteCamera("porch")
        #expect(store.events(since: .distantPast).map(\.event.id) == ["e2"])
        #expect(store.sightings(camera: "porch", from: .distantPast, to: .distantFuture).isEmpty)
        #expect(store.sightings(camera: "drive", from: .distantPast, to: .distantFuture).count == 1)
    }

    /// Deleted, it stays deleted: the service, still at it (going on, or taken up again), doesn't write it back.
    @Test func aDeletedEventIsntWrittenBack() throws {
        let path = NSTemporaryDirectory() + "pond-events-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try #require(EventStore(path: path))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var event = CameraEvent(id: "e1", camera: "porch", start: t0, end: t0, category: .person, labels: ["person": 1],
                                confidence: 0.8, snapshot: "porch/e1.jpg")
        let other = CameraEvent(id: "e2", camera: "porch", start: t0, end: t0, category: .animal, labels: ["cat": 1], confidence: 0.7)
        store.save(event, ongoing: true)
        store.save(other, ongoing: false)
        store.flush()
        #expect(store.delete(["e1"], now: t0) == ["porch/e1.jpg"])
        event.end = t0.addingTimeInterval(5)
        store.save(event, ongoing: false)
        store.flush()
        #expect(store.events(since: .distantPast).map(\.event.id) == ["e2"])
        // The note's let go a day on (the service long done with it).
        store.prune(days: 30, now: t0.addingTimeInterval(2 * 86400))
        store.save(event, ongoing: false)
        store.flush()
        #expect(Set(store.events(since: .distantPast).map(\.event.id)) == ["e1", "e2"])
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
            let found = [Self.thing(.person, x: 0.45 + Double(step) * 0.03, bottom: 0.9)].compactMap { d in rules.zones(for: d).map { (d, $0) } }
            let sightings = tracker.update(found.map(\.0), mask: EventBuilderTests.moving, at: time) { d in found.first { $0.0 == d }?.1 ?? [] }
            _ = builder.update(sightings, at: time)
        }
        #expect(builder.current?.zones == ["steps"])
    }
}

@Suite struct LeftItemsTests {
    static let bag = Detection(label: "backpack", category: .item, confidence: 0.7, box: .init(x: 0.45, y: 0.8, width: 0.1, height: 0.1))
    static let person = Detection(label: "person", category: .person, confidence: 0.9, box: .init(x: 0.4, y: 0.3, width: 0.2, height: 0.6))

    @Test func aBagPutDownAndLeftIsAnEventOnce() {
        var items = LeftItems(camera: "porch")
        let t0 = Date()
        // Put down (seen where something moved), with the person over it.
        #expect(items.update([(Self.bag, ["steps"], true)], people: [Self.person], at: t0).isEmpty)
        #expect(items.isWaiting)
        // Still there, the person gone; not yet long enough.
        #expect(items.update([(Self.bag, [], false)], people: [], at: t0.addingTimeInterval(10)).isEmpty)
        #expect(items.update([(Self.bag, [], false)], people: [], at: t0.addingTimeInterval(20)).isEmpty)
        let left = items.update([(Self.bag, [], false)], people: [], at: t0.addingTimeInterval(31))
        #expect(left.count == 1 && left.first?.category == .item && left.first?.labels == ["backpack": 1])
        #expect(left.first?.zones == ["steps"] && left.first?.start == t0)
        #expect(!items.isWaiting)
        // Still there later: not again.
        #expect(items.update([(Self.bag, [], true)], people: [], at: t0.addingTimeInterval(90)).isEmpty)
    }

    @Test func oneAlreadyThereOrCarriedOffIsnt() {
        var items = LeftItems(camera: "porch")
        let t0 = Date()
        // There from the start (nothing moved where it is): never waited for.
        _ = items.update([(Self.bag, [], false)], people: [], at: t0)
        #expect(!items.isWaiting)
        // Carried past: seen moving, then gone.
        _ = items.update([(Self.bag, [], true)], people: [Self.person], at: t0.addingTimeInterval(1))
        #expect(items.isWaiting)
        _ = items.update([], people: [], at: t0.addingTimeInterval(20))
        #expect(!items.isWaiting)
    }

    @Test func oneStillHeldIsntLeft() {
        var items = LeftItems(camera: "porch")
        let t0 = Date()
        _ = items.update([(Self.bag, [], true)], people: [Self.person], at: t0)
        // Someone standing at the door with it for a minute.
        for s in stride(from: 5.0, through: 60, by: 5) {
            #expect(items.update([(Self.bag, [], false)], people: [Self.person], at: t0.addingTimeInterval(s)).isEmpty)
        }
    }
}

@Suite struct RingTests {
    @Test func aPressIsKeptAsAnEventOfItsOwn() throws {
        let path = NSTemporaryDirectory() + "pond-rings-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try #require(EventStore(path: path))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CameraWatcher.ring(camera: "doorbell", at: t0, snapshot: "events/doorbell/x.jpg", store: store) { _ in }
        store.flush()
        let kept = store.events(since: t0.addingTimeInterval(-1))
        #expect(kept.map(\.event) == [event])
        #expect(kept.first?.event.category == .ring && kept.first?.ongoing == false)
    }
}

@Suite struct IgnoredScreenTests {
    @Test func someoneOnATVIsIgnoredThoughTheirFeetAreJustOutside() {
        // A TV zone drawn a little short of the screen's bottom edge.
        let tv = Config.Zone(id: "tv", name: "TV", points: [[0.63, 0.17], [0.85, 0.23], [0.83, 0.46], [0.63, 0.38]], kind: .ignore)
        let onScreen = Detection(label: "person", category: .person, confidence: 0.9, box: .init(x: 0.66, y: 0.2, width: 0.1, height: 0.22))
        #expect(!tv.contains(x: 0.71, y: 0.42))          // where it "stands": outside
        #expect(ZoneRules([tv]).zones(for: onScreen) == nil)
        // Someone in front of the TV, mostly below it: counts.
        let inFront = Detection(label: "person", category: .person, confidence: 0.9, box: .init(x: 0.66, y: 0.3, width: 0.12, height: 0.6))
        #expect(ZoneRules([tv]).zones(for: inFront) == [])
        // Standing right at the TV, their head and shoulders before the screen, their feet on the floor: counts.
        let atTheTV = Detection(label: "person", category: .person, confidence: 0.9, box: .init(x: 0.68, y: 0.22, width: 0.1, height: 0.42))
        #expect(ZoneRules([tv]).zones(for: atTheTV) == [])
        // And in the same picture as someone on the screen, only they count.
        #expect([onScreen, atTheTV].compactMap { ZoneRules([tv]).zones(for: $0) }.count == 1)
    }

    @Test func labelsInWords() {
        #expect(CameraEvent.words(["person": 3]) == "3 people")
    }
}

@Suite struct OnePersonTwiceTests {
    // From the living room: one person found whole, and again from the waist up (over a lamp).
    static let whole = Detection(label: "person", category: .person, confidence: 0.9, box: .init(x: 0.47, y: 0.3, width: 0.12, height: 0.39))
    static let topHalf = Detection(label: "person", category: .person, confidence: 0.5, box: .init(x: 0.48, y: 0.3, width: 0.1, height: 0.25))

    @Test func foundWholeAndInPartIsOne() {
        #expect(Duplicates.merged([Self.topHalf, Self.whole]) == [Self.whole])
        // Two people side by side stay two.
        let beside = Detection(label: "person", category: .person, confidence: 0.8, box: .init(x: 0.62, y: 0.3, width: 0.12, height: 0.39))
        #expect(Duplicates.merged([Self.whole, beside]).count == 2)
    }

    @Test func anEventCountsThoseSeenAtOnceNotTracks() {
        var tracker = Tracker()
        var builder = EventBuilder(camera: "living-room")
        let t0 = Date()
        let moving = MotionMask(columns: 1, rows: 1, cells: [0])
        // One person, whose box jumps (a new track) halfway.
        for step in 0 ..< 6 {
            let time = t0.addingTimeInterval(Double(step) * 0.25)
            let x = (step < 3 ? 0.1 : 0.6) + Double(step % 3) * 0.06   // (walking)
            let d = Detection(label: "person", category: .person, confidence: 0.9, box: .init(x: x, y: 0.2, width: 0.1, height: 0.5))
            _ = builder.update(tracker.update([d], mask: moving, at: time), at: time)
        }
        #expect(builder.current?.labels == ["person": 1])
    }
}


@Suite struct StayingTests {
    static let moving = MotionMask(columns: 1, rows: 1, cells: [0])
    static let still = MotionMask(columns: 1, rows: 1, cells: [])
    static func dog(_ x: Double) -> Detection {
        Detection(label: "dog", category: .animal, confidence: 0.8, box: .init(x: x, y: 0.5, width: 0.2, height: 0.2))
    }

    /// A picture every `step` seconds from `from` to `to`, the dog at x, moving or not.
    static func run(_ tracker: inout Tracker, _ builder: inout EventBuilder, from: Double, to: Double, step: Double = 2,
                    x: (Double) -> Double, moving: Bool, t0: Date) -> [EventBuilder.Change] {
        var changes: [EventBuilder.Change] = []
        var s = from
        while s <= to {
            let time = t0.addingTimeInterval(s)
            changes += builder.update(tracker.update([dog(x(s))], mask: moving ? Self.moving : Self.still, at: time), at: time)
            s += step
        }
        return changes
    }

    @Test func aDogThatWalksInAndLiesDownIsOneEvent() {
        var tracker = Tracker(), builder = EventBuilder(camera: "living-room")
        let t0 = Date()
        var changes = Self.run(&tracker, &builder, from: 0, to: 4, step: 0.5, x: { 0.1 + $0 * 0.05 }, moving: true, t0: t0)
        // Lying there a minute: still in view, looked at every 2 s.
        changes += Self.run(&tracker, &builder, from: 6, to: 66, x: { _ in 0.3 }, moving: false, t0: t0)
        // Gets up and moves about.
        changes += Self.run(&tracker, &builder, from: 68, to: 72, step: 0.5, x: { 0.3 + ($0 - 68) * 0.02 }, moving: true, t0: t0)
        let began = changes.filter { if case .began = $0 { true } else { false } }.count
        let ended = changes.filter { if case .ended = $0 { true } else { false } }.count
        #expect(began == 1 && ended == 0)
        #expect(builder.current?.seconds ?? 0 > 70)
    }

    @Test func stillTooLongEndsAndMovingAgainTakesItUp() {
        var tracker = Tracker(), builder = EventBuilder(camera: "drive")
        let t0 = Date()
        var changes = Self.run(&tracker, &builder, from: 0, to: 3, step: 0.5, x: { 0.1 + $0 * 0.05 }, moving: true, t0: t0)
        // Still for over two minutes: ended, though in view.
        changes += Self.run(&tracker, &builder, from: 5, to: 135, x: { _ in 0.25 }, moving: false, t0: t0)
        #expect(changes.contains { if case .ended = $0 { true } else { false } })
        #expect(builder.current == nil)
        // The same dog (its track never lost) moves again: the same event, taken up.
        let first = changes.compactMap { if case let .began(e) = $0 { e.id } else { nil } }.first
        changes = Self.run(&tracker, &builder, from: 137, to: 140, step: 0.5, x: { 0.25 + ($0 - 137) * 0.02 }, moving: true, t0: t0)
        #expect(changes.contains { if case let .resumed(e) = $0 { e.id == first } else { false } })
    }

    @Test func goneAWhileThenBackIsANewEvent() {
        var tracker = Tracker(), builder = EventBuilder(camera: "yard")
        let t0 = Date()
        _ = Self.run(&tracker, &builder, from: 0, to: 3, step: 0.5, x: { 0.1 + $0 * 0.05 }, moving: true, t0: t0)
        _ = builder.quiet(at: t0.addingTimeInterval(20))
        _ = tracker.update([], mask: Self.still, at: t0.addingTimeInterval(20))
        // Back after a few minutes: a new one.
        let changes = Self.run(&tracker, &builder, from: 300, to: 303, step: 0.5, x: { 0.6 + ($0 - 300) * 0.02 }, moving: true, t0: t0)
        #expect(changes.contains { if case .began = $0 { true } else { false } })
    }
}

@Suite struct OneCatTests {
    @Test func aCatSometimesCalledADogIsACat() {
        var tracker = Tracker(), builder = EventBuilder(camera: "living-room")
        let t0 = Date()
        let moving = MotionMask(columns: 1, rows: 1, cells: [0])
        for step in 0 ..< 10 {
            let time = t0.addingTimeInterval(Double(step) * 0.25)
            let word = step % 4 == 3 ? "dog" : "cat"
            let d = Detection(label: word, category: .animal, confidence: word == "cat" ? 0.8 : 0.5,
                              box: .init(x: 0.3 + Double(step) * 0.01, y: 0.6, width: 0.1, height: 0.1))
            _ = builder.update(tracker.update([d], mask: moving, at: time), at: time)
        }
        #expect(builder.current?.labels == ["cat": 1])
    }

    @Test func aCatAndADogTogetherAreBoth() {
        var tracker = Tracker(), builder = EventBuilder(camera: "living-room")
        let t0 = Date()
        let moving = MotionMask(columns: 1, rows: 1, cells: [0])
        for step in 0 ..< 6 {
            let time = t0.addingTimeInterval(Double(step) * 0.25)
            let cat = Detection(label: "cat", category: .animal, confidence: 0.8, box: .init(x: 0.1 + Double(step) * 0.02, y: 0.6, width: 0.1, height: 0.1))
            let dog = Detection(label: "dog", category: .animal, confidence: 0.8, box: .init(x: 0.6 + Double(step) * 0.02, y: 0.6, width: 0.15, height: 0.15))
            _ = builder.update(tracker.update([cat, dog], mask: moving, at: time), at: time)
        }
        #expect(builder.current?.labels == ["cat": 1, "dog": 1])
    }
}

@Suite struct BikeTests {
    @Test func aCyclistIsABikeEventAndAVehicleZoneTakesIt() {
        #expect(DetectedCategory.forLabel("bicycle") == .bike && DetectedCategory.forLabel("motorcycle") == .bike)
        var path = Config.Zone(id: "path", name: "Path", points: [[0, 0], [1, 0], [1, 1], [0, 1]])
        path.categories = ["vehicle"]
        let bike = Detection(label: "bicycle", category: .bike, confidence: 0.8, box: .init(x: 0.4, y: 0.5, width: 0.2, height: 0.2))
        #expect(ZoneRules([path]).zones(for: bike) == ["path"])
        path.categories = ["person"]
        #expect(ZoneRules([path]).zones(for: bike) == nil)

        var tracker = Tracker(), builder = EventBuilder(camera: "street")
        let t0 = Date()
        let moving = MotionMask(columns: 1, rows: 1, cells: [0])
        for step in 0 ..< 4 {
            let time = t0.addingTimeInterval(Double(step) * 0.25)
            let dx = Double(step) * 0.03
            let rider = Detection(label: "person", category: .person, confidence: 0.9, box: .init(x: 0.4 + dx, y: 0.3, width: 0.15, height: 0.4))
            let cycle = Detection(label: "bicycle", category: .bike, confidence: 0.7, box: .init(x: 0.38 + dx, y: 0.5, width: 0.2, height: 0.2))
            _ = builder.update(tracker.update([rider, cycle], mask: moving, at: time), at: time)
        }
        #expect(builder.current?.category == .bike)
        #expect(builder.current?.labels == ["bicycle": 1, "person": 1])
    }
}

@Suite struct CloserLookTests {
    @Test func aSmallMovingThingGetsACloseUp() {
        // A cat at the left edge, low down: three cells of a 32×24 grid.
        let mask = MotionMask(columns: 32, rows: 24, cells: [20 * 32 + 1, 20 * 32 + 2, 21 * 32 + 1])
        let areas = CloserLook.areas(mask)
        #expect(areas.count == 1)
        // In a 2560×1440 picture: a 640×640 crop around it, inside the picture.
        let crop = CloserLook.crop(areas[0], width: 2560, height: 1440)!
        #expect(crop.width == 640 && crop.height == 640 && crop.minX == 0 && crop.maxY <= 1440)
        // Found at the crop's middle: back in the whole picture's terms.
        let found = Detection(label: "cat", category: .animal, confidence: 0.8, box: .init(x: 0.45, y: 0.45, width: 0.1, height: 0.1))
        let mapped = CloserLook.mapped([found], from: crop, width: 2560, height: 1440)[0]
        #expect(abs(mapped.box.x - (crop.minX + 0.45 * 640) / 2560) < 1e-9 && abs(mapped.box.width - 64.0 / 2560) < 1e-9)
    }

    @Test func somethingLargeIsSeenWhole() {
        // Half the grid moving: no closer look.
        let mask = MotionMask(columns: 4, rows: 4, cells: [0, 1, 2, 4, 5, 6, 8, 9, 10])
        #expect(CloserLook.areas(mask).isEmpty)
        // A small picture: a 640 crop would be most of it.
        #expect(CloserLook.crop(CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.05), width: 896, height: 512) == nil)
    }

    @Test func twoThingsApartAreTwoAreas() {
        let mask = MotionMask(columns: 32, rows: 24, cells: [5 * 32 + 2, 5 * 32 + 3, 18 * 32 + 25, 18 * 32 + 26, 19 * 32 + 25])
        #expect(CloserLook.areas(mask).count == 2)
    }
}

@Suite struct StreetTests {
    static func thing(_ category: DetectedCategory, _ label: String, x: Double, y: Double) -> Detection {
        Detection(label: label, category: category, confidence: 0.85, box: .init(x: x, y: y, width: 0.15, height: 0.15))
    }

    /// Motion on a 20×20 grid only where these are (what moves), not where a parked car stands.
    static func motion(_ moving: [Detection]) -> MotionMask {
        var cells = Set<Int>()
        for d in moving {
            for row in Int(d.box.y * 20) ..< min(20, Int((d.box.y + d.box.height) * 20) + 1) {
                for column in Int(d.box.x * 20) ..< min(20, Int((d.box.x + d.box.width) * 20) + 1) { cells.insert(row * 20 + column) }
            }
        }
        return MotionMask(columns: 20, rows: 20, cells: cells)
    }

    @Test func someoneWalkingPastWithTrafficEndsWhenTheyveGone() {
        var tracker = Tracker(), builder = EventBuilder(camera: "doorbell")
        let t0 = Date()
        let parked = Self.thing(.vehicle, "car", x: 0.7, y: 0.75)
        var changes: [EventBuilder.Change] = []
        // A parked car (driven in long before), a person walking past for 20 s, and a car passing every 15 s for
        // ten minutes.
        _ = tracker.update([parked], mask: Self.motion([parked]), at: t0.addingTimeInterval(-600))
        var s = 0.0
        while s < 600 {
            let time = t0.addingTimeInterval(s)
            var moving: [Detection] = []
            if s < 20 { moving.append(Self.thing(.person, "person", x: 0.05 + s * 0.02, y: 0.5)) }
            let lap = s.truncatingRemainder(dividingBy: 15)
            if lap < 4 { moving.append(Self.thing(.vehicle, "car", x: 0.05 + lap * 0.15, y: 0.2)) }
            changes += builder.update(tracker.update([parked] + moving, mask: Self.motion(moving), at: time), at: time)
            s += 0.5
        }
        let people = changes.compactMap { if case let .ended(e) = $0, e.category == .person { e } else { nil } }
        #expect(people.count == 1)
        #expect((people.first?.seconds ?? 999) < 40)
    }

    @Test func passingCarsAreEachTheirOwn() {
        var tracker = Tracker(), builder = EventBuilder(camera: "doorbell")
        let t0 = Date()
        var began = 0
        var s = 0.0
        // A car every 25 s, each in view 4 s.
        while s < 200 {
            let time = t0.addingTimeInterval(s)
            let lap = s.truncatingRemainder(dividingBy: 25)
            let found = lap < 4 ? [Self.thing(.vehicle, "car", x: 0.05 + lap * 0.15, y: 0.3)] : []
            for change in builder.update(tracker.update(found, mask: Self.motion(found), at: time), at: time) {
                if case .began = change { began += 1 }
            }
            s += 0.5
        }
        #expect(began == 8)
    }
}

@Suite struct SightingStoreTests {
    @Test func aLooksSightingsAreKeptAndReadBack() throws {
        let path = NSTemporaryDirectory() + "pond-sightings-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try #require(EventStore(path: path))
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let person = Sighting(camera: "porch", time: t, label: "person", category: .person, confidence: 0.9,
                              box: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4), track: 3)
        let onTV = Sighting(camera: "porch", time: t, label: "person", category: .person, confidence: 0.6,
                            box: .init(x: 0.7, y: 0.2, width: 0.1, height: 0.2), counted: false)
        store.save([person, onTV])
        store.save([Sighting(camera: "drive", time: t, label: "car", category: .vehicle, confidence: 0.8, box: .init(x: 0, y: 0, width: 0.1, height: 0.1))])
        store.flush()
        let read = store.sightings(camera: "porch", from: t.addingTimeInterval(-1), to: t.addingTimeInterval(1))
        #expect(read == [person, onTV])
        store.prune(days: 1, now: t.addingTimeInterval(2 * 86400))
        store.flush()
        #expect(store.sightings(camera: "porch", from: .distantPast, to: .distantFuture).isEmpty)
    }
}

@Suite struct EventSearchTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func event(_ id: String, _ category: DetectedCategory, _ labels: [String: Int], camera: String = "porch", at: Double = 0) -> CameraEvent {
        CameraEvent(id: id, camera: camera, start: t0.addingTimeInterval(at), end: t0.addingTimeInterval(at), category: category,
                    labels: labels, confidence: 0.8)
    }
    static let events = [event("p1", .person, ["person": 1], at: 1), event("p2", .person, ["person": 1, "dog": 1], at: 2),
                         event("c1", .vehicle, ["car": 1], camera: "drive", at: 3)]

    @Test func filtersAreKindsThingsCamerasAndTime() {
        func ids(_ q: EventQuery, cameras: Set<String> = []) -> [String] {
            EventSearch.answer(q, events: Self.events, understood: [:], cameraIDs: cameras, zoneIDs: [], words: nil, probability: nil).hits.map(\.id)
        }
        // A dog seen while someone was there: an animal event too. Newest first.
        #expect(ids(EventQuery(kinds: ["animal"])) == ["p2"])
        #expect(ids(EventQuery(kinds: ["person"])) == ["p2", "p1"])
        #expect(ids(EventQuery(things: ["car"])) == ["c1"])
        #expect(ids(EventQuery(), cameras: ["drive"]) == ["c1"])
        #expect(ids(EventQuery(time: TimeFilter(range: Self.t0 ... Self.t0.addingTimeInterval(1.5)))) == ["p1"])
    }

    @Test func howTheyLookedRanksByPictureAndSentence() {
        // Embeddings in two dimensions: the words point at "red", p1's picture is red, p2's isn't.
        let understood: [String: EventStore.Understood] = [
            "p1": .init(description: "A person walks by.", scene: [1, 0], embedder: "m"),
            "p2": .init(description: "A person in a red jacket with a dog.", scene: [0, 1], embedder: "m"),
        ]
        let answer = EventSearch.answer(EventQuery(kinds: ["person"], appearance: "a person in a red jacket"), events: Self.events,
                                        understood: understood, cameraIDs: [], zoneIDs: [], words: [1, 0],
                                        probability: { $0 > 0.5 ? 0.05 : 0.0001 })
        // p1 by its picture, p2 by its sentence's words (person, red, jacket: all there).
        #expect(Set(answer.hits.map(\.id)) == ["p1", "p2"])
        #expect(!answer.appearanceIgnored)
        // A picture that doesn't look it and a sentence without its words: left out.
        let none = EventSearch.answer(EventQuery(kinds: ["person"], appearance: "a woman in a green coat"), events: Self.events,
                                      understood: understood, cameraIDs: [], zoneIDs: [], words: [0, -1], probability: { _ in 0.0001 })
        #expect(none.hits.isEmpty)
    }

    @Test func aSentenceWithThePhrasesWordsTogetherMatchesBest() {
        let telling = EventSearch.telling("carrying a white bag")
        let exact = EventSearch.sentenceMatch(telling, "A person is walking on a path, carrying a white bag.")
        let apart = EventSearch.sentenceMatch(telling, "A person in white trousers, carrying a large bag.")
        #expect(exact == 1 && apart < exact && apart >= 0.6)
        #expect(EventSearch.sentenceMatch(telling, "A dog on the sofa.") == 0)
    }

    @Test func withNothingToJudgeByHowTheyLookedIsSaidToBeUnused() {
        let answer = EventSearch.answer(EventQuery(kinds: ["person"], appearance: "a red jacket"), events: Self.events, understood: [:],
                                        cameraIDs: [], zoneIDs: [], words: nil, probability: nil)
        #expect(answer.appearanceIgnored && answer.hits.map(\.id) == ["p2", "p1"])
    }
}
