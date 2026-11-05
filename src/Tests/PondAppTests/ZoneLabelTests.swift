import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import PondApp
import Watch

@MainActor
@Suite struct ZoneLabelTests {
    let label = CGSize(width: 40, height: 16)

    @Test func aCornerAddedAlongAnEdgeDoesntMoveTheLabel() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 100), CGPoint(x: 0, y: 100)]
        var more = square
        more.insert(CGPoint(x: 100, y: 0), at: 1)
        more.insert(CGPoint(x: 200, y: 50), at: 3)
        #expect(ZoneCanvas.labelCenter(square, size: label) == CGPoint(x: 100, y: 50))
        let moved = ZoneCanvas.labelCenter(more, size: label)
        #expect(abs(moved.x - 100) < 0.001 && abs(moved.y - 50) < 0.001)
    }

    @Test func inAnLTheLabelStaysInside() {
        // The centroid of this L is near its inside corner, where the label would cross the edge.
        let l = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 160), CGPoint(x: 200, y: 160),
                 CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 200)]
        let center = ZoneCanvas.labelCenter(l, size: label)
        #expect(ZoneCanvas.fits(center, size: label, in: l))
        #expect(!ZoneCanvas.fits(ZoneCanvas.centroid(l), size: label, in: l))
    }
}

@Suite struct EventSummaryTests {
    @Test func labelsInWords() {
        #expect(EventSource.list(["person": 2, "dog": 1]) == "2 people and a dog")
        #expect(EventSource.list(["umbrella": 1]) == "an umbrella")
        #expect(EventSource.list(["car": 3, "bus": 2, "cat": 1]) == "3 cars, 2 buses and a cat")
    }
}

@MainActor
@Suite struct PrivateStretchTests {
    @Test func aStretchReachesTheRecordingButNeverShrinks() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        // Made private at 0; recording stopped 2 s before and started again 30 s after it was public at 600.
        let coverage = [t.addingTimeInterval(-3600) ... t.addingTimeInterval(-2), t.addingTimeInterval(630) ... t.addingTimeInterval(900)]
        #expect(TimelineLanes.joined([t ... t.addingTimeInterval(600)], to: coverage)
                == [t.addingTimeInterval(-2) ... t.addingTimeInterval(630)])
        // Recording listed as running on into it (a nominal minute): the stretch keeps its start, on top of it.
        let longer = [t.addingTimeInterval(-3600) ... t.addingTimeInterval(26)]
        #expect(TimelineLanes.joined([t ... t.addingTimeInterval(600)], to: longer) == [t ... t.addingTimeInterval(600)])
    }
}

@MainActor
@Suite struct TimelineLoadTests {
    /// A very busy day: 20,000 events on one camera (one every ~4 s), of three kinds, some long.
    static func busyDay(_ day: Date) -> [TimelineEvent] {
        (0 ..< 20000).map { i in
            let start = day.addingTimeInterval(Double(i) * 4.3)
            let kind: TimelineEvent.Kind = [.person, .vehicle, .animal][i % 3]
            return TimelineEvent(id: "\(i)", camera: "street", kind: kind, start: start,
                                 end: start.addingTimeInterval(i % 500 == 0 ? 900 : 6), summary: "")
        }
    }

    @Test func findingAndDrawingABusyDayStaysCheap() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let index = EventIndex(Self.busyDay(day))
        // An hour's view: only that hour's events (and a long one reaching in), found by search.
        let hour = day.addingTimeInterval(36000) ... day.addingTimeInterval(39600)
        let inHour = index.overlapping(hour)
        #expect(inHour.count < 900 && inHour.allSatisfy { $0.end > hour.lowerBound && $0.start <= hour.upperBound })
        #expect(inHour.contains { $0.seconds == 900 } || !index.events.contains { $0.seconds == 900 && $0.start < hour.lowerBound && $0.end > hour.lowerBound })

        // The whole day at 24 h in a 1,400-point lane: every event in view, merged to what can be told apart.
        let whole = day ... day.addingTimeInterval(86400)
        let started = Date()
        let marks = index.overlapping(whole).map { e in
            (kind: e.kind, rect: CGRect(x: e.start.timeIntervalSince(day) / 86400 * 1400, y: 0,
                                        width: max(3, e.seconds / 86400 * 1400), height: 20), weight: 1.0)
        }
        let runs = TimelineLanes.clusters(marks)
        let took = Date().timeIntervalSince(started)
        // Three kinds, about one shape a kind for each few points: a few hundred, not 20,000.
        #expect(runs.count < 3 * 1400 / 2)
        // Well within a frame, even in a debug build (a release build is several times faster).
        #expect(took < 0.25, "took \(took) s")
        print("busy day: \(marks.count) events in view, \(runs.count) shapes, \(Int(took * 1000)) ms")
    }
}


@MainActor
@Suite struct ClusterTests {
    @Test func touchingMarksOfAnyKindAreOneChipLedByTheMostTelling() {
        func mark(_ kind: TimelineEvent.Kind, _ x: Double) -> (kind: TimelineEvent.Kind, rect: CGRect, weight: Double) {
            (kind, CGRect(x: x, y: 0, width: 4, height: 20), 1)
        }
        let clusters = TimelineLanes.clusters([mark(.animal, 0), mark(.person, 3), mark(.animal, 6), mark(.vehicle, 40)])
        #expect(clusters.count == 2)
        #expect(clusters[0].lead == .person && clusters[0].kinds.map(\.kind) == [.person, .animal])
        #expect(clusters[0].kinds.first { $0.kind == .animal }?.count == 2)
        #expect(clusters[0].rect == CGRect(x: 0, y: 0, width: 10, height: 20))
    }
}

@MainActor
@Suite struct LongBarTests {
    /// A car parked for hours with someone passing it a moment: one chip, both in it, led by the car (it took the
    /// person's colour while they were in view, and lost it as they went out of it).
    @Test func aLongMarkLeadsItsChip() {
        let marks: [(kind: TimelineEvent.Kind, rect: CGRect, weight: Double)] = [
            (.vehicle, CGRect(x: 0, y: 0, width: 600, height: 20), 1), (.person, CGRect(x: 40, y: 0, width: 3, height: 20), 1)]
        let clusters = TimelineLanes.clusters(marks, ids: ["car", "person"])
        #expect(clusters.count == 1 && clusters[0].ids == ["car", "person"])
        #expect(clusters[0].kinds.map(\.kind) == [.vehicle, .person])
        // The car alone (the person out of view): the same colour.
        #expect(TimelineLanes.clusters([marks[0]]).first?.lead == .vehicle)
    }

    /// Zoomed in, what passed a parked car is wide enough to tell apart: its own chips over the car's bar (a bird
    /// and two other cars were lost in it), the car's bar first.
    @Test func wideEnoughTheyreChipsOverTheBar() {
        let marks: [(kind: TimelineEvent.Kind, rect: CGRect, weight: Double)] = [
            (.vehicle, CGRect(x: 0, y: 0, width: 900, height: 20), 1),
            (.vehicle, CGRect(x: 20, y: 0, width: 18, height: 20), 1),
            (.animal, CGRect(x: 80, y: 0, width: 20, height: 20), 1)]
        let clusters = TimelineLanes.clusters(marks, ids: ["parked", "passing", "bird"])
        #expect(clusters.map(\.ids) == [["parked"], ["passing"], ["bird"]])
        #expect(clusters.map(\.lead) == [.vehicle, .vehicle, .animal])
    }

    /// The morning's doorbell at 15 minutes: a parked car, a car passing it (long enough to be a bar of its own),
    /// and a bird for a second; each its own, though the bird's a sliver; zoomed out, the bird's part of the car.
    @Test func zoomedInEachIsItsOwn() {
        let marks: [(kind: TimelineEvent.Kind, rect: CGRect, weight: Double)] = [
            (.vehicle, CGRect(x: 0, y: 0, width: 1400, height: 20), 1),
            (.vehicle, CGRect(x: 45, y: 0, width: 28, height: 20), 1),
            (.animal, CGRect(x: 115, y: 0, width: 3, height: 20), 1)]
        let ids = ["parked", "passing", "bird"]
        #expect(TimelineLanes.clusters(marks, ids: ids, apart: true).map(\.ids) == [["parked"], ["passing"], ["bird"]])
        // Over the parked car's bar, the others are set apart from it.
        #expect(TimelineLanes.clusters(marks, ids: ids, apart: true).map(\.over) == [false, true, true])
        #expect(TimelineLanes.clusters(marks, ids: ids).map(\.ids) == [["parked", "bird"], ["passing"]])
    }

    /// A small group zoomed in (someone, and a car by them for a moment): one chip, led by the longer, with the band.
    @Test func aSmallGroupStaysOne() {
        let marks: [(kind: TimelineEvent.Kind, rect: CGRect, weight: Double)] = [
            (.person, CGRect(x: 100, y: 0, width: 65, height: 20), 1), (.vehicle, CGRect(x: 120, y: 0, width: 4, height: 20), 1)]
        let clusters = TimelineLanes.clusters(marks, ids: ["person", "car"], apart: true)
        #expect(clusters.count == 1 && clusters[0].ids == ["person", "car"])
        #expect(clusters[0].kinds.map(\.kind) == [.person, .vehicle] && !clusters[0].over)
    }
}

@MainActor
@Suite struct ClusterIDTests {
    @Test func aChipKnowsItsEvents() {
        let marks: [(kind: TimelineEvent.Kind, rect: CGRect, weight: Double)] = [
            (.animal, CGRect(x: 10, y: 0, width: 4, height: 20), 1), (.person, CGRect(x: 0, y: 0, width: 4, height: 20), 1),
            (.person, CGRect(x: 3, y: 0, width: 4, height: 20), 1), (.vehicle, CGRect(x: 50, y: 0, width: 4, height: 20), 1)]
        let clusters = TimelineLanes.clusters(marks, ids: ["a", "b", "c", "d"])
        #expect(clusters.map(\.ids) == [["b", "c"], ["a"], ["d"]])
    }
}

@MainActor
@Suite struct LiveEdgeTests {
    static let names: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd/HH-mm-ss"
        return f
    }()

    static func write(_ root: String, _ start: Date, partial: Bool, modified: Date) throws -> String {
        let name = names.string(from: start)
        let folder = "\(root)/continuous/porch/\(name.prefix(10))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = "\(folder)/\(name.suffix(8)).mp4\(partial ? ".partial" : "")"
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        return path
    }

    @Test func theBarsEndMovesOnThroughANewFileNeverBackNorPastThePresent() async throws {
        let root = NSTemporaryDirectory() + "pond-edge-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date()
        // A minute finished, and the next being written for 20 s.
        let earlier = now.addingTimeInterval(-81).rounded()
        _ = try Self.write(root, earlier, partial: false, modified: earlier.addingTimeInterval(60))
        let current = earlier.addingTimeInterval(61)
        let writing = try Self.write(root, current, partial: true, modified: now.addingTimeInterval(-1))
        let timeline = TimelineModel()
        await timeline.load(base: root, cameras: ["porch"])
        await timeline.refreshLive()
        let first = try #require(timeline.liveEdge(of: "porch", now: Date()))
        #expect(first <= Date() && first > current)
        // No gap where the minute changed: one stretch.
        #expect(timeline.coverage["porch"]?.count == 1)

        // The minute ends: renamed, and the next begins (written a moment ago).
        try FileManager.default.moveItem(atPath: writing, toPath: String(writing.dropLast(8)))
        _ = try Self.write(root, Date().addingTimeInterval(-0.5).rounded(), partial: true, modified: Date())
        await timeline.refreshLive()
        let after = try #require(timeline.liveEdge(of: "porch", now: Date()))
        #expect(after >= first && after <= Date())
        #expect(timeline.coverage["porch"]?.count == 1)
    }
}

extension Date {
    /// To the whole second (segment files are named to the second).
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

@Suite struct BoxesAtAMomentTests {
    @Test func theLastLookJustBeforeIsShownAndNotOneTooOld() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func s(_ at: Double, _ label: String) -> Sighting {
            Sighting(camera: "porch", time: t.addingTimeInterval(at), label: label, category: .person, confidence: 0.9,
                     box: .init(x: 0, y: 0, width: 0.1, height: 0.1))
        }
        let all = [s(0, "a"), s(0, "b"), s(0.25, "c"), s(0.5, "d"), s(0.5, "e")]
        #expect(TimelineModel.look(in: all, at: t.addingTimeInterval(0.3)).map(\.label) == ["c"])
        #expect(TimelineModel.look(in: all, at: t.addingTimeInterval(0.6)).map(\.label) == ["d", "e"])
        #expect(TimelineModel.look(in: all, at: t.addingTimeInterval(2)).isEmpty)
        #expect(TimelineModel.look(in: all, at: t.addingTimeInterval(-1)).isEmpty)
    }

    @Test func aTrackedBoxGlidesBetweenLooks() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Sighting(camera: "porch", time: t, label: "person", category: .person, confidence: 0.9,
                             box: .init(x: 0.1, y: 0.2, width: 0.2, height: 0.4), track: 7)
        let second = Sighting(camera: "porch", time: t.addingTimeInterval(0.25), label: "person", category: .person, confidence: 0.9,
                              box: .init(x: 0.3, y: 0.2, width: 0.2, height: 0.4), track: 7)
        // A quarter of the way: a quarter of the way there.
        let midway = TimelineModel.glide(in: [first, second], at: t.addingTimeInterval(0.0625))
        #expect(abs((midway.first?.box.x ?? 0) - 0.15) < 1e-9)
        // After the last look: where it was last seen.
        #expect(TimelineModel.glide(in: [first, second], at: t.addingTimeInterval(0.3)).first?.box.x == 0.3)
    }
}

@MainActor @Suite struct DetectionBoxesTests {
    /// A box narrower than its label (a person, in the event panel's small picture) is drawn as wide as it is, not
    /// as wide as the label.
    @Test func aBoxIsntWidenedByItsLabel() throws {
        let person = Sighting(camera: "c", time: Date(), label: "person", category: .person, confidence: 0.87,
                              box: .init(x: 0.5, y: 0.4, width: 0.05, height: 0.4))
        let size = CGSize(width: 320, height: 180)
        let renderer = ImageRenderer(content: DetectionBoxes(boxes: [person], aspect: 16.0 / 9.0)
            .frame(width: size.width, height: size.height).background(Color.black))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let data = try #require(image.dataProvider?.data as Data?)
        // The box's bottom edge: where it's drawn, along a row through it (well below the label).
        let row = Int(size.height * 0.8) - 1
        var lit: [Int] = []
        for x in 0 ..< image.width {
            let i = row * image.bytesPerRow + x * image.bitsPerPixel / 8
            if Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2]) > 120 { lit.append(x) }
        }
        let drawn = Double((lit.max() ?? 0) - (lit.min() ?? 0))
        #expect(abs(drawn - 0.05 * size.width) < 4, "drawn \(drawn) wide")
    }
}
