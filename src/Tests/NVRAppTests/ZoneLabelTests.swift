import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import NVRApp
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

@MainActor
@Suite struct RailWindowTests {
    @Test func theHoursInViewAreAStretchOfTheRailsOneLine() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Thirty days: today's hours are the last 24 of the line (696…719).
        let morning = today.addingTimeInterval(2 * 3600 + 600) ... today.addingTimeInterval(4 * 3600 + 3000)
        let span = try #require(ActivityRail.span(morning, today: today, days: 30))
        #expect(span.start == 29 * 24 + 2 && span.end == 29 * 24 + 5)
        // Across midnight: one stretch, from yesterday's 23rd hour to today's first.
        let midnight = today.addingTimeInterval(-1800) ... today.addingTimeInterval(2400)
        let across = try #require(ActivityRail.span(midnight, today: today, days: 30))
        #expect(across.start == 28 * 24 + 23 && across.end == 29 * 24 + 1)
        #expect(ActivityRail.span(nil, today: today, days: 30) == nil)
    }

    @Test func aStretchAcrossMidnightIsAPieceOnEachRow() {
        // From yesterday's last hour to today's first: two pieces, today's row (the top) and yesterday's.
        let path = RailWindow(start: 28 * 24 + 23, end: 29 * 24 + 1, days: 30).path(in: .zero)
        let pitch = ActivityRail.row + ActivityRail.rowGap
        let bounds = path.boundingRect
        #expect(abs(bounds.minY) < 0.001 && abs(bounds.maxY - (pitch + ActivityRail.row)) < 0.001)
        #expect(abs(bounds.minX - (ActivityRail.cellsX - 2)) < 0.001)
    }
}

@Suite struct EventGridLayoutTests {
    static let day = Date(timeIntervalSince1970: 1_800_000_000)

    /// A card mid-move is drawn part way from where it was to where it goes, by the phase; at rest, where it goes.
    @Test func aMoveDrawsCardsPartWay() {
        func at(_ phase: Double, start: Double) -> CGPoint {
            let t = FlipPlacement(phase: phase, target: 3, start: start, from: CGPoint(x: 0, y: 100), to: CGPoint(x: 40, y: 300))
                .effectValue(size: .zero)
            return CGPoint(x: t.m31, y: t.m32)
        }
        #expect(at(2, start: 2) == CGPoint(x: 0, y: 100))
        #expect(at(2.5, start: 2) == CGPoint(x: 20, y: 200))
        #expect(at(3, start: 2) == CGPoint(x: 40, y: 300))
        // Begun part way through another (its phase not a whole one), it runs from there.
        #expect(at(2.75, start: 2.5) == CGPoint(x: 20, y: 200))
        // At rest (no move): where it goes.
        #expect(at(3, start: 3) == CGPoint(x: 40, y: 300))
    }

    @Test func cardsGoRowByRowUnderTheirDay() {
        let sections = [EventGridLayout.Section(day: Self.day, ids: ["a", "b", "c", "d", "e"]),
                        EventGridLayout.Section(day: Self.day.addingTimeInterval(-86400), ids: ["f"])]
        let layout = EventGridLayout(sections: sections, width: 3 * 300 + 2 * 14, columns: 3)
        let card = layout.card
        #expect(card.width == 300)
        // Three a row: d starts the second row, under a.
        #expect(layout.cards["a"].map { Double($0.minY) } == EventGridLayout.headerHeight)
        #expect(layout.cards["d"]?.minX == 0 && layout.cards["d"].map { Double($0.minY) } == EventGridLayout.headerHeight + card.height + EventGridLayout.spacing)
        // The next day's header after the two rows.
        let second = EventGridLayout.headerHeight + 2 * card.height + EventGridLayout.spacing + EventGridLayout.sectionGap
        #expect(layout.headers[1].y == second)
        #expect(layout.cards["f"].map { Double($0.minY) } == second + EventGridLayout.headerHeight)
        #expect(layout.height == second + EventGridLayout.headerHeight + card.height + EventGridLayout.sectionGap)
    }

    @Test func theCardsInARangeAndAMiddleRow() throws {
        let ids = (0 ..< 30).map { "e\($0)" }
        let layout = EventGridLayout(sections: [.init(day: Self.day, ids: ids)], width: 1000, columns: 3)
        let pitch = layout.card.height + EventGridLayout.spacing
        // A view's worth from the fourth row: the fourth and fifth rows (and the sixth, if it reaches).
        let top = EventGridLayout.headerHeight + 3 * pitch
        let shown = layout.cards(in: top ... (top + pitch * 1.5)).map(\.id)
        #expect(shown.first == "e9" && shown.contains("e14") && !shown.contains("e8"))
        // Its row in the middle of a 600-tall view.
        let frame = try #require(layout.cards["e12"])
        #expect(layout.centring("e12", view: 600) == Double(frame.midY) - 300)
        // Near the top or bottom, as near as the ends allow.
        #expect(layout.centring("e0", view: 600) == 0)
        #expect(layout.centring("e29", view: 600) == layout.height - 600)
    }

    @Test func theSameCardsNarrowerAreShorterAndTheRowsMove() {
        let sections = [EventGridLayout.Section(day: Self.day, ids: (0 ..< 12).map { "e\($0)" })]
        let wide = EventGridLayout(sections: sections, width: 1300, columns: 4)
        let narrow = EventGridLayout(sections: sections, width: 900, columns: 4)
        #expect(narrow.card.height < wide.card.height && narrow.height < wide.height)
        #expect(narrow.cards["e8"]!.minY < wide.cards["e8"]!.minY)
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
