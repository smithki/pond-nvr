import CoreGraphics
import Foundation
import Testing
@testable import NVRApp

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
