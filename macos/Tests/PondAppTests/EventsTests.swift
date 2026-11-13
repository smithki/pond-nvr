// The Events view: the rail's outline of the hours in view, the grid's layout and its account of where things are.
import CoreGraphics
import Foundation
import Testing
@testable import PondApp

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

/// The grid's account of where things are, with the figures macOS 26 gives (measured): a window toolbar 52 tall
/// (counted in the scroll view's inset, though the grid's below it), the filters' bar's room 50, the strip at the
/// bottom 80, a scroll view 1079 tall. If a macOS reports otherwise, these say how.
@Suite struct GridMetricsTests {
    static func metrics(contentOffset: Double) -> GridMetrics {
        GridMetrics(reading: GridScrollReading(contentOffset: contentOffset, insetTop: 52, containerHeight: 1079),
                    topRoom: 50, bottomRoom: 80)
    }

    @Test func atTheTopTheCardsAreScrolledNothing() {
        // (The scroll view's offset, at its top, is minus its inset.)
        let top = Self.metrics(contentOffset: -52)
        #expect(top.offset == 0)
        // The height in view is between the grid's own room above and below, not less the toolbar.
        #expect(top.visibleHeight == 949)
    }

    @Test func scrollingToACardAndReadingItBackAgree() {
        let m = Self.metrics(contentOffset: -52)
        for y in [0.0, 300, 1234.5] {
            #expect(Self.metrics(contentOffset: m.contentOffset(showing: y)).offset == y)
        }
    }

    @Test func thePinnedDayIsJustUnderTheBarUntilTheNextPushesItUp() {
        let m = Self.metrics(contentOffset: 448)   // scrolled 500
        #expect(m.pinnedHeaderY(nextHeaderAt: .infinity, headerHeight: 58) == 50)
        // The next day's header 20 below the top of the height in view: the pinned one's pushed up 38.
        #expect(m.pinnedHeaderY(nextHeaderAt: 520, headerHeight: 58) == 12)
    }

    @Test func theBottomStripIsTheStretchJustBelowWhatsInView() {
        let m = Self.metrics(contentOffset: 448)
        #expect(m.bottomStrip == 1449 ... 1529)
    }
}

/// A far jump's ease, cut in two: each piece starts and ends where the whole does there, and the speed it leaves
/// at is the speed it arrives at.
@MainActor
@Suite struct JumpEaseTests {
    /// A timing curve's progress at time `t` (0…1), and its slope there (progress per time).
    func sample(_ c: (Double, Double, Double, Double), at t: Double) -> (y: Double, slope: Double) {
        func bez(_ a: Double, _ b: Double, _ u: Double) -> Double { 3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u }
        func dbez(_ a: Double, _ b: Double, _ u: Double) -> Double { 3 * (1 - u) * (1 - u) * a + 6 * (1 - u) * u * (b - a) + 3 * u * u * (1 - b) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<50 { let m = (lo + hi) / 2; if bez(c.0, c.2, m) < t { lo = m } else { hi = m } }
        let u = (lo + hi) / 2
        return (bez(c.1, c.3, u), dbez(c.1, c.3, u) / max(dbez(c.0, c.2, u), 1e-9))
    }

    @Test(arguments: [0.1, 0.3, 0.5, 0.7, 0.9])
    func thePiecesMeetAtOneSpeed(fraction: Double) {
        let (left, right, at) = JumpEase.cut(where: fraction)
        #expect(at > 0 && at < 1)
        let whole = JumpEase.curve
        // Each piece's ends, as the whole has them there.
        #expect(abs(sample(left, at: 1).y - 1) < 1e-6)
        #expect(abs(sample(right, at: 0).y) < 1e-6)
        // Speeds in the whole's terms: a piece covers `fraction` (or the rest) of the way in `at` (or the rest) of
        // the time.
        let leaving = sample(left, at: 0.999_999).slope * fraction / at
        let arriving = sample(right, at: 0.000_001).slope * (1 - fraction) / (1 - at)
        let there = sample((whole.x1, whole.y1, whole.x2, whole.y2), at: at).slope
        #expect(abs(leaving - there) < 0.01)
        #expect(abs(arriving - there) < 0.01)
    }

    @Test func withNoWayOutOrInTheOtherIsTheWholeEase() {
        let noOut = JumpEase.split(leaving: 0, arriving: 180, over: 1)
        #expect(noOut.leave == nil && noOut.arrive != nil && noOut.arriveFor == 1)
        let noIn = JumpEase.split(leaving: 180, arriving: 0, over: 1)
        #expect(noIn.arrive == nil && noIn.leave != nil && noIn.leaveFor == 1)
        let neither = JumpEase.split(leaving: 0, arriving: 0, over: 1)
        #expect(neither.leave == nil && neither.arrive == nil)
        // A shortened way out is a shorter share of the time.
        let short = JumpEase.split(leaving: 60, arriving: 180, over: 1)
        #expect(short.leaveFor < short.arriveFor && abs(short.leaveFor + short.arriveFor - 1) < 1e-9)
    }
}

/// A search's answer: by day, as any other; ranked, its closest few in a row above as well, by ids of their own.
@Suite struct SearchResultsLayoutTests {
    func events(_ n: Int) -> [TimelineEvent] {
        (0 ..< n).map { i in
            let at = Date(timeIntervalSince1970: 1_800_000_000 - Double(i) * 20_000)
            return TimelineEvent(id: "e\(i)", camera: "porch", kind: .person, start: at, end: at.addingTimeInterval(10), summary: "")
        }
    }

    func key(_ ids: [String], ranked: Bool) -> EventsView.IndexKey {
        EventsView.IndexKey(events: 1, camera: nil, hidden: [], quietedOnly: false, newOnly: nil, search: ids,
                            ranked: ranked, seen: 0)
    }

    @Test func rankedHasTopRowThenDays() {
        let all = events(10)
        // Ranked oldest first: the top row's the four oldest, best first; the days still newest first.
        let ids = all.reversed().map(\.id)
        let index = EventsView.index(of: all, key: key(ids, ranked: true), isNew: { $0.id == "e9" || $0.id == "e0" })
        #expect(index.sections.first?.day == EventsView.bestMatches)
        #expect(index.sections.first?.ids == ["top:e9", "top:e8", "top:e7", "top:e6"])
        #expect(index.sections.dropFirst().allSatisfy { $0.day != EventsView.bestMatches })
        #expect(index.sections.dropFirst().flatMap(\.ids) == all.map(\.id))
        #expect(index.byID["top:e9"]?.id == "e9")
        #expect(index.unseen == ["e9", "e0", "top:e9"])
        #expect(EventsView.eventID("top:e9") == "e9")
    }

    @Test func noTopRowWhenItWouldBeEverything() {
        let all = events(3)
        let index = EventsView.index(of: all, key: key(all.map(\.id), ranked: true), isNew: { _ in false })
        #expect(index.sections.allSatisfy { $0.day != EventsView.bestMatches })
    }

    @Test func unrankedByDayOnly() {
        let all = events(10)
        let index = EventsView.index(of: all, key: key(all.map(\.id), ranked: false), isNew: { _ in false })
        #expect(index.sections.allSatisfy { $0.day != EventsView.bestMatches })
    }
}
