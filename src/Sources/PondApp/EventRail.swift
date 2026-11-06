// The Events view's rail: every day kept, newest at the top, an hour a cell shaded by how much happened; the days
// on screen in the grid marked, the hours they span outlined, a cell a click away from its hour in the grid.
import SwiftUI

/// The cards on screen in the grid.
@Observable
final class GridOnScreen {
    var cards: Set<String> = []
}

/// The rail, given what's on screen: the days it marks, the hours it outlines.
struct OnScreenRail: View {
    let events: [TimelineEvent]
    let days: Int
    let onScreen: GridOnScreen
    let retention: () -> Void
    let go: (Date) -> Void

    var body: some View {
        let shown = events.filter { onScreen.cards.contains($0.id) }
        let starts = shown.map(\.start)
        ActivityRail(events: events, days: days, onScreen: Set(shown.map { Calendar.current.startOfDay(for: $0.start) }),
                     window: starts.min().flatMap { low in starts.max().map { low ... $0 } }, retention: retention, go: go)
    }
}

/// Every day kept, newest at the top, an hour a cell shaded by how many events it had: busy times at a glance, and
/// a click away. The days on screen in the grid are marked, and the hours they span outlined: one outline running
/// through the days, from the oldest hour on screen to the newest, that grows, shrinks and slides with the grid,
/// wrapping from the end of one day's row to the start of the next. Laid out from fixed measures (no layout's
/// guess), so the outline sits exactly on its cells.
struct ActivityRail: View {
    @Environment(AppModel.self) private var model
    let events: [TimelineEvent]
    let days: Int
    let onScreen: Set<Date>
    /// The time the grid shows now.
    var window: ClosedRange<Date>?
    /// Opens the retention settings (how many days there are is theirs).
    let retention: () -> Void
    let go: (Date) -> Void

    nonisolated static let label = 46.0, labelGap = 6.0, pad = 2.0, cell = 5.0, gap = 1.0
    nonisolated static let row = 20.0, rowGap = 5.0, top = 6.0
    nonisolated static let cellHeight = row - 2 * pad
    /// Where the hours begin in a row.
    nonisolated static let cellsX = label + labelGap + pad
    nonisolated static let rowWidth = cellsX + 24 * cell + 23 * gap + pad
    nonisolated static let width = rowWidth + 4

    /// The hour under the pointer: its row, its hour, how many, when.
    @State private var hovered: (back: Int, h: Int, count: Int, hour: Date)?
    /// How far the rail is scrolled (the hover label's drawn over it, not in it, so nothing cuts it off).
    @State private var offset = 0.0
    /// How far down its list starts (the filters' bar over its top).
    @State private var inset = 0.0
    /// The hours outlined as drawn: following what's in view, animated; shown first, grown out from its middle.
    @State private var drawn: RailSpan?

    /// Events an hour, by the hour's start.
    var counts: [Date: Int] {
        let calendar = Calendar.current
        return events.reduce(into: [:]) { counts, e in
            if let hour = calendar.dateInterval(of: .hour, for: e.start)?.start { counts[hour, default: 0] += 1 }
        }
    }

    var body: some View {
        let counts = counts
        let busiest = Double(max(1, counts.values.max() ?? 1))
        let today = Calendar.current.startOfDay(for: Date())
        let span = Self.span(window, today: today, days: days)
        ScrollView {
            ZStack(alignment: .topLeading) {
                // The hours in view: shaded under the cells, outlined over them (the busiest hours' colour doesn't
                // cover its edge).
                RailWindow(start: drawn?.start ?? 0, end: drawn?.end ?? 0, days: days)
                    .fill(.white.opacity(0.12))
                    .opacity(span == nil ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: span == nil)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: Self.rowGap) {
                    ForEach(0 ..< days, id: \.self) { back in
                        row(back, day: Calendar.current.date(byAdding: .day, value: -back, to: today) ?? today,
                            counts: counts, busiest: busiest)
                            .zIndex(hovered?.back == back ? 1 : 0)
                    }
                }
                RailWindow(start: drawn?.start ?? 0, end: drawn?.end ?? 0, days: days)
                    .stroke(.white.opacity(0.85), lineWidth: 1.5)
                    .opacity(span == nil ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: span == nil)
                    .allowsHitTesting(false)
                // The hour under the pointer, lifted over everything (the outline too), in its own colour.
                if let hovered {
                    // One at a time, there at once and gone at once (it grows on its own, from its own middle): moving
                    // the pointer along a row leaves no others fading behind it.
                    LiftedCell()
                        .id("\(hovered.back)-\(hovered.h)")
                        .padding(.leading, Self.cellsX + Double(hovered.h) * (Self.cell + Self.gap))
                        .padding(.top, Double(hovered.back) * (Self.row + Self.rowGap) + Self.pad)
                        .allowsHitTesting(false)
                        .transition(.identity)
                        .transaction { $0.animation = nil }
                }
            }
            .frame(width: Self.width, alignment: .topLeading)
            .padding(.vertical, Self.top)
            // Why it goes back as far as it does, and where that's changed.
            // How many of these are new, and their being seen, all at once.
            let new = events.count(where: model.seenEvents.isNew)
            if new > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                        Text(new == 1 ? "1 new event" : "\(new) new events")
                    }
                    Button("Mark All Seen") { withAnimation(.easeOut(duration: 0.3)) { model.seenEvents.sawAll() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
                .font(.caption2)
                .frame(width: Self.rowWidth - Self.cellsX + Self.pad, alignment: .leading)
                .padding(.leading, Self.cellsX - Self.pad)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Events are kept \(days == 1 ? "1 day" : "\(days) days").")
                    .foregroundStyle(.secondary)
                Button("Retention Settings\u{2026}", action: retention)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            .font(.caption2)
            .frame(width: Self.rowWidth - Self.cellsX + Self.pad, alignment: .leading)
            .padding(.leading, Self.cellsX - Self.pad)
            .padding(.top, 6)
            // (Clear of the glass at the window's edge, scrolled to the end.)
            .padding(.bottom, EventsView.bottomFade)
        }
        .scrollIndicators(.never)
        // (Its offset from under the filters' bar, which it scrolls on under: the label's placed in the view's frame.)
        .onScrollGeometryChange(for: [Double].self) { [$0.contentOffset.y, $0.contentInsets.top] } action: { _, v in
            offset = v[0]
            inset = v[1]
        }
        .onChange(of: span, initial: true) { _, span in follow(span) }
        // The hovered hour, said beside it at once: over the rail (past its edge if need be), not cut off by it.
        .overlay(alignment: .topLeading) {
            if let hovered {
                let x = Self.cellsX + Double(hovered.h) * (Self.cell + Self.gap) + Self.cell / 2
                let y = Self.top + Double(hovered.back) * (Self.row + Self.rowGap) - offset
                Text("\(hovered.hour.formatted(.dateTime.weekday(.abbreviated).hour())) \u{00B7} \(hovered.count == 1 ? "1 event" : "\(hovered.count) events")")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .fixedSize()
                    .position(x: max(x, 56), y: y < inset + 24 ? y + Self.row + 14 : y - 14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered?.hour)
    }

    /// The outline to the hours now in view: moved there; or, the first time there are some, put at their middle at
    /// once and grown out from it.
    func follow(_ span: RailSpan?) {
        guard let span else { return }
        guard drawn != nil else {
            let middle = ((span.start + span.end) / 2).rounded(.down)
            drawn = RailSpan(start: middle, end: middle)
            // (Next turn of the run loop: drawn at its middle first, so there's something to grow from.)
            DispatchQueue.main.async { withAnimation(.snappy(duration: 0.45)) { drawn = span } }
            return
        }
        withAnimation(.snappy(duration: 0.35)) { drawn = span }
    }

    func row(_ back: Int, day: Date, counts: [Date: Int], busiest: Double) -> some View {
        let on = onScreen.contains(day)
        return HStack(spacing: 0) {
            Text(back == 0 ? "Today" : day.formatted(.dateTime.month(.abbreviated).day()))
                .font(.caption2.monospacedDigit().weight(on ? .semibold : .regular))
                .foregroundStyle(on ? .primary : .secondary)
                .frame(width: Self.label, alignment: .trailing)
            Color.clear.frame(width: Self.labelGap)
            HStack(spacing: Self.gap) {
                ForEach(0 ..< 24, id: \.self) { h in
                    let hour = Calendar.current.date(byAdding: .hour, value: h, to: day) ?? day
                    let n = counts[hour] ?? 0
                    RailCell(count: n, busiest: busiest, hour: hour, go: { go(hour) }) { inside in
                        if inside { hovered = (back, h, n, hour) } else if hovered?.hour == hour { hovered = nil }
                    }
                }
            }
            .padding(Self.pad)
            // On screen in the grid: a neutral panel under the row (the cells are the accent colour; the mark
            // mustn't be).
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.primary.opacity(on ? 0.1 : 0))
                    .animation(.easeInOut(duration: 0.25), value: on)
            }
        }
        .frame(width: Self.rowWidth, height: Self.row, alignment: .leading)
    }

    /// The hours `window` spans, as a stretch of the rail's one line of hours (counted from the oldest day's first
    /// hour): its first hour, and past its last.
    static func span(_ window: ClosedRange<Date>?, today: Date, days: Int) -> RailSpan? {
        guard let window else { return nil }
        let calendar = Calendar.current
        let oldest = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        // By the calendar: the day's row and the hour's cell (a day the clocks change has 23 or 25 hours, but its row
        // has 24 cells, as every row does: counting hours since the first row put the outline an hour off after one).
        func index(_ date: Date) -> Double {
            let days = calendar.dateComponents([.day], from: oldest, to: calendar.startOfDay(for: date)).day ?? 0
            return Double(days * 24 + calendar.component(.hour, from: date))
        }
        let start = max(0, index(window.lowerBound)), end = min(Double(days * 24), index(window.upperBound) + 1)
        return end > start ? RailSpan(start: start, end: end) : nil
    }
}

/// A stretch of the rail's one line of hours (counted from the oldest day's first hour): its first, and past its last.
struct RailSpan: Equatable {
    var start: Double
    var end: Double
}

/// The rail's hours in view, as one shape: a piece a day it crosses, from `start` to `end` on the rail's one line of
/// hours. Both animate, so as the grid scrolls it grows, shrinks and slides, wrapping from one day's row to the next
/// as a line of text does.
struct RailWindow: Shape {
    var start: Double
    var end: Double
    let days: Int

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set {
            start = newValue.first
            end = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard end > start else { return path }
        let step = ActivityRail.cell + ActivityRail.gap
        var day = Int((start / 24).rounded(.down))
        while Double(day * 24) < end, day < days {
            let from = max(start, Double(day * 24)) - Double(day * 24)
            let to = min(end, Double((day + 1) * 24)) - Double(day * 24)
            if to > from {
                // Rows newest at the top: the oldest day's is the last.
                let back = days - 1 - day
                let x = ActivityRail.cellsX + from * step - 2
                let width = (to - from) * step - ActivityRail.gap + 4
                let y = Double(back) * (ActivityRail.row + ActivityRail.rowGap)
                path.addRoundedRect(in: CGRect(x: x, y: y, width: width, height: ActivityRail.row),
                                    cornerSize: CGSize(width: 3, height: 3))
            }
            day += 1
        }
        return path
    }
}

/// An hour in the rail: shaded by how much happened; one with events lifted under the pointer (drawn by the rail, over
/// the outline of the hours on screen; its hour said beside it), and a click takes the grid there.
struct RailCell: View {
    let count: Int
    let busiest: Double
    let hour: Date
    let go: () -> Void
    /// Told as the pointer comes and goes (one with events), for the rail's label.
    var hover: (Bool) -> Void = { _ in }
    @State private var hovering = false

    var body: some View {
        let lit = count > 0
        RoundedRectangle(cornerRadius: 1.5)
            .fill(lit ? AnyShapeStyle(Color.accentColor.opacity(0.25 + 0.75 * Double(count) / busiest)) : AnyShapeStyle(.quaternary.opacity(0.5)))
            .frame(width: ActivityRail.cell, height: ActivityRail.cellHeight)
            // As wide as the gaps either side: a tiny cell, easy to hit.
            .contentShape(Rectangle().inset(by: -ActivityRail.gap))
            .onHover { inside in
                hovering = lit && inside
                if lit { hover(inside) }
            }
            .pointerStyle(lit ? .link : nil)
            .onTapGesture { if lit { go() } }
    }

}

/// An hour with events under the pointer: its colour whole, grown a little from its own middle, lifted on a soft
/// shadow.
struct LiftedCell: View {
    @State private var grown = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .brightness(0.08)
            .frame(width: ActivityRail.cell, height: ActivityRail.cellHeight)
            .scaleEffect(grown ? 1.5 : 1)
            .shadow(color: .black.opacity(grown ? 0.55 : 0), radius: 2.5, y: 1)
            .onAppear { withAnimation(.snappy(duration: 0.15)) { grown = true } }
    }
}
