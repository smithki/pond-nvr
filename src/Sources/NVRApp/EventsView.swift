// Events: what the cameras saw, newest first, a card each (its picture, its subject boxed, what and when), by day.
// Beside them, a rail of every day kept, an hour a cell shaded by how much happened: where the busy times were, and
// a way to go back far at once. A card chosen opens its details in a panel on the right (its recording, looping,
// what was found boxed over it); twice, the timeline there. Filtered by camera and kind; new events come in as
// they're made (read again every ten seconds).
import AppKit
import AVFoundation
import Detection
import NVRCore
import Recorder
import SwiftUI
import Watch

struct EventsView: View {
    @Environment(AppModel.self) private var model
    @State private var events: [TimelineEvent] = []
    @State private var loaded = false
    /// The event whose details are open, one camera's events or all (nil), the kinds hidden: kept with the app's
    /// model, so coming back (the toolbar's back, say) finds the view as it was left.
    @State private var selected: TimelineEvent?
    var camera: String? {
        get { model.eventsState.camera }
        nonmutating set { model.eventsState.camera = newValue }
    }
    var hidden: Set<TimelineEvent.Kind> {
        get { model.eventsState.hidden }
        nonmutating set { model.eventsState.hidden = newValue }
    }
    /// Moves asked of the grid (a card's row to the middle, the top), and the card the panel's opening or closing
    /// centres (the chosen one, or the one that was).
    @State private var request: GridScroll?
    @State private var focus: String?
    /// The cards on screen in the grid (the rail draws the hours they span and marks their days). Kept apart, read
    /// by the rail alone: they change as the grid scrolls, and this view needn't be made again each time.
    @State private var onScreen = GridOnScreen()
    /// The grid's at its top (new events slide in there; scrolled down, they're added without moving the view).
    @State private var atTop = true
    /// Events just come in (since the last read): they glow a moment, in their kind's colour.
    @State private var fresh: Set<String> = []

    var cameras: [Config.Camera] { model.config?.cameras ?? [] }
    /// How far back events are kept.
    var keptDays: Int { model.config?.retention.events.days ?? 30 }

    /// The camera's, newest first.
    var forCamera: [TimelineEvent] { events.filter { camera == nil || $0.camera == camera } }
    var shown: [TimelineEvent] { forCamera.filter { !hidden.contains($0.kind) } }
    /// The kinds there are (for the chips), in the timeline's order.
    var kinds: [TimelineEvent.Kind] { TimelineEvent.Kind.allCases.filter { k in forCamera.contains { $0.kind == k } } }

    /// Shown, by day: newest day first.
    var days: [(day: Date, events: [TimelineEvent])] {
        let calendar = Calendar.current
        return Dictionary(grouping: shown) { calendar.startOfDay(for: $0.start) }
            .map { ($0.key, $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filters
            HStack(alignment: .top, spacing: 14) {
                OnScreenRail(events: shown, days: keptDays, onScreen: onScreen) { hour in
                    // The first card at or after that hour (newest first: the last one before the next hour).
                    let next = hour.addingTimeInterval(3600)
                    if let target = shown.last(where: { $0.start < next && $0.start >= hour }) ?? shown.first(where: { $0.start < next }) {
                        request = GridScroll(kind: .centre(target.id, always: true))
                    }
                }
                .frame(width: ActivityRail.width)
                .zIndex(1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let selected {
                    // A panel an event (its own player), swapped at once from one to the next; it slides in and out
                    // only as it opens and closes.
                    ZStack {
                        EventDetail(event: selected, camera: name(selected.camera), recordings: model.config?.storage.recordingsPath ?? "",
                                    source: EventSource(config: model.config),
                                    watch: { watch(selected) }, close: { panel(nil) },
                                    earlier: neighbour(of: selected, later: false).map { e in { choose(e) } },
                                    later: neighbour(of: selected, later: true).map { e in { choose(e) } })
                            .id(selected.id)
                            .transition(.identity)
                    }
                    .frame(width: EventDetail.width)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(16)
        .onChange(of: selected?.id) { _, id in model.eventsState.selected = id }
        .onKeyPress(.escape) {
            guard selected != nil else { return .ignored }
            panel(nil)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard let selected, let e = neighbour(of: selected, later: false) else { return .ignored }
            choose(e)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard let selected, let e = neighbour(of: selected, later: true) else { return .ignored }
            choose(e)
            return .handled
        }
        .task {
            // New ones as they're made: read again every ten seconds.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    @ViewBuilder
    var content: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            ContentUnavailableView {
                Label(events.isEmpty ? "No events yet" : "No events here", systemImage: "figure.walk.motion")
            } description: {
                Text(events.isEmpty
                     ? "People, vehicles, bikes and animals your cameras see appear here, each with its picture. Detection is on for each camera in its settings."
                     : "Nothing matches these filters.")
            }
        } else {
            grid
        }
    }

    func name(_ camera: String) -> String { cameras.first { $0.id == camera }?.name ?? camera }

    /// Opens the panel on an event, or closes it (nil): the panel slides, the cards reshape and the chosen card's
    /// row glides to the middle of the grid, one animation (the grid scrolls in it).
    func panel(_ event: TimelineEvent?) {
        focus = (event ?? selected)?.id
        withAnimation(EventGrid.panelAnimation) { selected = event }
    }

    /// The event shown just before or after this one (the grid is newest first).
    func neighbour(of event: TimelineEvent, later: Bool) -> TimelineEvent? {
        guard let i = shown.firstIndex(where: { $0.id == event.id }) else { return nil }
        let j = later ? i - 1 : i + 1
        return shown.indices.contains(j) ? shown[j] : nil
    }

    /// Another event's details (the arrows): its card's row brought to the middle if it isn't wholly in view.
    func choose(_ event: TimelineEvent) {
        selected = event
        focus = event.id
        request = GridScroll(kind: .centre(event.id, always: false))
    }

    func watch(_ event: TimelineEvent) {
        model.timelineJump = TimelineJump(camera: event.camera, time: event.start)
        model.mode = .timeline
    }

    func load() async {
        guard let source = EventSource(config: model.config) else { return }
        let from = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(keptDays - 1) * 86400)
        let to = Date().addingTimeInterval(60)
        let found = await Task.detached { source.events(from: from, to: to) }.value
            .filter { $0.kind != .privacy }
            .sorted { $0.start > $1.start }
        if found != events {
            // New ones (after the first read) come in smoothly, the others making room, and glow a moment.
            let arrived = loaded ? Set(found.map(\.id)).subtracting(events.map(\.id)) : []
            // (Scrolled down, without animation: the grid keeps what's on screen where it is.)
            withAnimation(loaded && atTop ? .snappy(duration: 0.4) : nil) { events = found }
            if !arrived.isEmpty {
                fresh.formUnion(arrived)
                Task {
                    try? await Task.sleep(for: .seconds(NewEventGlow.lasts))
                    fresh.subtract(arrived)
                }
            }
        }
        // The open one, as it is now (an ongoing one goes on); on coming back, the one that was open, in view.
        if let open = selected, let now = found.first(where: { $0.id == open.id }), now != open { selected = now }
        if !loaded, selected == nil, let id = model.eventsState.selected, let was = found.first(where: { $0.id == id }) {
            selected = was
            focus = id
            request = GridScroll(kind: .centre(id, always: true), animated: false)
        }
        loaded = true
    }

    // MARK: Filters

    var filters: some View {
        HStack(spacing: 10) {
            Picker("Camera", selection: Binding(get: { camera }, set: { camera = $0 })) {
                Text("All Cameras").tag(String?.none)
                Divider()
                ForEach(cameras) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
            ForEach(kinds) { kind in
                let on = !hidden.contains(kind)
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        if on { hidden.insert(kind) } else { hidden.remove(kind) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol).foregroundStyle(on ? kind.color : .secondary)
                        Text(kind.title)
                        Text("\(forCamera.count { $0.kind == kind })").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .opacity(on ? 1 : 0.55)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(on ? .regular.tint(kind.color.opacity(0.25)).interactive() : .regular.interactive(), in: .capsule)
                .help(on ? "Hide \(kind.title.lowercased()) events" : "Show \(kind.title.lowercased()) events")
            }
            Spacer()
        }
    }

    // MARK: Cards

    /// The grid, as wide as the room it's given (read from a view that takes what it's offered: the grid's content,
    /// laid out to that width, mustn't feed back into it). The columns come from the width there'd be without the
    /// panel, so the panel opening narrows the cards (smoothly) instead of changing how many there are a row.
    var grid: some View {
        let open = selected != nil
        return GeometryReader { geo in
            EventGrid(sections: days.map { EventGridLayout.Section(day: $0.day, ids: $0.events.map(\.id)) },
                         events: Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                         width: max(200, geo.size.width),
                         columns: columnCount(geo.size.width + (open ? EventDetail.width + 14 : 0)),
                         panelOpen: open, panelWidth: EventDetail.width + 14,
                         focus: focus, selected: selected?.id, fresh: fresh, request: $request,
                         name: name,
                         choose: { event in if selected == nil { panel(event) } else { choose(event) } },
                         open: { watch($0) },
                         onVisible: { onScreen.cards = $0 }, onTop: { atTop = $0 })
        }
    }

    /// As many as fit at least 300 wide in the width there is without the panel (the panel narrows them, it doesn't
    /// change how many there are a row).
    func columnCount(_ available: Double) -> Int { max(1, Int((available + 14) / (300 + 14))) }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

// MARK: - The rail

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
    let go: (Date) -> Void

    var body: some View {
        let shown = events.filter { onScreen.cards.contains($0.id) }
        let starts = shown.map(\.start)
        ActivityRail(events: events, days: days, onScreen: Set(shown.map { Calendar.current.startOfDay(for: $0.start) }),
                     window: starts.min().flatMap { low in starts.max().map { low ... $0 } }, go: go)
    }
}

/// Every day kept, newest at the top, an hour a cell shaded by how many events it had: busy times at a glance, and
/// a click away. The days on screen in the grid are marked, and the hours they span outlined: one outline running
/// through the days, from the oldest hour on screen to the newest, that grows, shrinks and slides with the grid,
/// wrapping from the end of one day's row to the start of the next. Laid out from fixed measures (no layout's
/// guess), so the outline sits exactly on its cells.
struct ActivityRail: View {
    let events: [TimelineEvent]
    let days: Int
    let onScreen: Set<Date>
    /// The time the grid shows now.
    var window: ClosedRange<Date>?
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
                // The hours in view: under the cells (a hovered cell grows over it).
                RailWindow(start: span?.start ?? 0, end: span?.end ?? 0, days: days)
                    .fill(.white.opacity(0.12))
                    .overlay {
                        RailWindow(start: span?.start ?? 0, end: span?.end ?? 0, days: days)
                            .stroke(.white.opacity(0.85), lineWidth: 1.5)
                    }
                    .opacity(span == nil ? 0 : 1)
                    .animation(.snappy(duration: 0.35), value: span?.start)
                    .animation(.snappy(duration: 0.35), value: span?.end)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: Self.rowGap) {
                    ForEach(0 ..< days, id: \.self) { back in
                        row(back, day: Calendar.current.date(byAdding: .day, value: -back, to: today) ?? today,
                            counts: counts, busiest: busiest)
                            .zIndex(hovered?.back == back ? 1 : 0)
                    }
                }
            }
            .frame(width: Self.width, alignment: .topLeading)
            .padding(.vertical, Self.top)
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y } action: { _, y in offset = y }
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
                    .position(x: max(x, 56), y: y < 24 ? y + Self.row + 14 : y - 14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered?.hour)
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
    static func span(_ window: ClosedRange<Date>?, today: Date, days: Int) -> (start: Double, end: Double)? {
        guard let window else { return nil }
        let calendar = Calendar.current
        let oldest = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        func index(_ date: Date) -> Double {
            let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
            return (hour.timeIntervalSince(oldest) / 3600).rounded()
        }
        let start = max(0, index(window.lowerBound)), end = min(Double(days * 24), index(window.upperBound) + 1)
        return end > start ? (start, end) : nil
    }
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

/// An hour in the rail: shaded by how much happened; one with events grows a little under the pointer (its hour
/// said beside it), and a click takes the grid there.
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
            .overlay {
                if lit {
                    RoundedRectangle(cornerRadius: 1.5).strokeBorder(.white.opacity(hovering ? 0.9 : 0), lineWidth: 1)
                }
            }
            .frame(width: ActivityRail.cell, height: ActivityRail.cellHeight)
            .scaleEffect(lit && hovering ? 1.45 : 1)
            .zIndex(hovering ? 1 : 0)
            .animation(.snappy(duration: 0.15), value: hovering)
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

// MARK: - A card

/// One event: its picture with its subject boxed and its kind on it, what happened, where and when. A click opens its
/// details; two, the timeline there.
struct EventCard: View {
    let event: TimelineEvent
    let camera: String
    let selected: Bool
    /// Just come in: glows a moment.
    var fresh = false
    let choose: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var aspect: Double { CameraAspect.known(event.camera) ?? 16.0 / 9.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EventPicture(event: event, aspect: aspect, frame: 16.0 / 9.0)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.summary)
                    .font(.callout)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text("\(camera) \u{00B7} \(event.start.formatted(date: .omitted, time: .shortened)) \u{00B7} \(EventCallout.length(event.seconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: EventGridLayout.textHeight, maxHeight: EventGridLayout.textHeight, alignment: .topLeading)
        }
        .padding(EventGridLayout.pad)
        // Resized as one (the panel opening): its picture and words move with it, not each on its own.
        .geometryGroup()
        .background(.quaternary.opacity(hovering || selected ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.accentColor, lineWidth: 2)
            }
        }
        // Always there, switched on and off (one inserted and removed would fade where the card was).
        .overlay { NewEventGlow(color: event.kind.color, cornerRadius: 14, active: fresh) }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Click for details, double-click to watch on the timeline")
        .contextMenu {
            Button("Watch on the Timeline", action: open)
            if let snapshot = event.snapshot {
                Button("Show Picture in Finder") { NSWorkspace.shared.activateFileViewerSelecting([snapshot]) }
            }
        }
    }
}

/// An event's picture, its subject boxed, its kind in a badge.
struct EventPicture: View {
    let event: TimelineEvent
    /// The picture's own shape.
    let aspect: Double
    /// The shape it's shown in (the grid's, alike for every card: a picture of another shape fills it, cropped);
    /// nil, its own.
    var frame: Double?

    var body: some View {
        let image = event.snapshot.flatMap(EventPictures.image)
        // The picture's own shape (from the picture, when there is one), and the frame's: the frame alone sizes the
        // card (a box of its shape), the picture filling it, cropped, so every card in the grid is alike.
        let own = image.map { $0.size.height > 0 ? Double($0.size.width / $0.size.height) : aspect } ?? aspect
        let shown = frame ?? own
        Color.clear
            .aspectRatio(shown, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: event.kind.symbol).font(.largeTitle).foregroundStyle(.tertiary) }
                }
            }
            .overlay {
                if let box = event.box {
                    GeometryReader { geo in
                        // The picture as it fills the frame (centred, the overflow cropped), the box on it.
                        let w = geo.size.width, h = geo.size.height
                        let picture = own > w / h ? CGSize(width: h * own, height: h) : CGSize(width: w, height: w / own)
                        let dx = (w - picture.width) / 2, dy = (h - picture.height) / 2
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(event.kind.color, lineWidth: 2)
                            .frame(width: box.width * picture.width, height: box.height * picture.height)
                            .position(x: dx + (box.x + box.width / 2) * picture.width, y: dy + (box.y + box.height / 2) * picture.height)
                    }
                }
            }
            .overlay(alignment: .topLeading) { KindBadge(event: event).padding(8) }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct KindBadge: View {
    let event: TimelineEvent

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: event.kind.symbol)
            Text(event.kind.title)
            if event.ongoing { Text("Now").foregroundStyle(.red) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // A plain capsule, not glass: there's one on every card, and glass on each is costly to redraw as they move.
        .background(event.kind.color.opacity(0.85), in: Capsule())
    }
}

// MARK: - The details

/// One event in full: its recording from a little before to a little after, looping, what was found boxed over it;
/// what was seen, where and when; and the way to the timeline.
struct EventDetail: View {
    let event: TimelineEvent
    let camera: String
    let recordings: String
    let source: EventSource?
    let watch: () -> Void
    let close: () -> Void
    /// The event before and after it (in what's shown), if there are.
    var earlier: (() -> Void)?
    var later: (() -> Void)?

    static let width = 380.0
    /// Shown from this long before it to this long after.
    static let around = 3.0

    @AppStorage("eventBoxes") private var boxes = true
    /// Made once the clip's ready (not with each redraw), let go when the panel goes.
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    /// The wall time of the clip's start, and what was found in it.
    @State private var origin: Date?
    @State private var sightings: [Sighting] = []
    @State private var noRecording = false
    /// The recording file it begins in.
    @State private var recording: String?

    var aspect: Double { CameraAspect.known(event.camera) ?? 16.0 / 9.0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                clip
                seen
                facts
                actions
            }
            .padding(16)
        }
        .scrollIndicators(.never)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task { await prepare() }
        .onDisappear {
            looper?.disableLooping()
            player?.pause()
            player?.removeAllItems()
            looper = nil
            player = nil
        }
    }

    /// What it was, in a sentence; where and how long ago; the way to the events either side, and out.
    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                KindBadge(event: event)
                Spacer()
                HStack(spacing: 2) {
                    round("chevron.left", help: "Earlier event (\u{2190})", action: earlier)
                    round("chevron.right", help: "Later event (\u{2192})", action: later)
                }
                round("xmark", help: "Close (Esc)", action: close)
            }
            Text(event.summary)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(camera) \u{00B7} \(event.ongoing ? "now" : event.start.formatted(.relative(presentation: .named)))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    func round(_ symbol: String, help: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol).font(.callout.weight(.semibold)).frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(action == nil)
        .opacity(action == nil ? 0.4 : 1)
        .help(help)
    }

    /// What was seen: a chip each, the most at once of each.
    @ViewBuilder
    var seen: some View {
        if !event.labels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Seen").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(event.labels.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { label, n in
                        let kind = TimelineEvent.Kind(DetectedCategory.forLabel(label))
                        HStack(spacing: 5) {
                            Image(systemName: kind.symbol).foregroundStyle(kind.color)
                            Text(n == 1 ? label : "\(n) \(CameraEvent.plural(label))")
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(kind.color.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
    }

    /// When, how long, how sure, where: a tile each, two a row.
    var facts: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            tile("Started", event.start.formatted(date: .omitted, time: .standard),
                 detail: event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            tile("Ended", event.ongoing ? "Going on" : event.end.formatted(date: .omitted, time: .standard))
            tile("Length", event.ongoing ? "So far \(EventCallout.length(event.seconds))" : EventCallout.length(event.seconds))
            if let confidence = event.confidence {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Confidence").font(.caption).foregroundStyle(.secondary)
                    Text("\(Int((confidence * 100).rounded()))%").font(.title3.weight(.semibold).monospacedDigit())
                    ProgressView(value: confidence).tint(event.kind.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .help("How sure the model was, at its surest sighting")
            }
            tile("Zones", event.zones.isEmpty ? "Anywhere" : event.zones.joined(separator: ", "))
            tile("Camera", camera)
        }
    }

    func tile(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                .textSelection(.enabled)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var actions: some View {
        HStack(spacing: 8) {
            Button(action: watch) {
                Label("Watch on Timeline", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Menu {
                if let snapshot = event.snapshot {
                    Button("Show Picture in Finder") { NSWorkspace.shared.activateFileViewerSelecting([snapshot]) }
                }
                if let recording {
                    Button("Show Recording in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording)]) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            // Drawn as a button beside the other, as tall as it.
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .controlSize(.large)
            .fixedSize()
            .disabled(event.snapshot == nil && recording == nil)
        }
    }

    /// The recording round it, looping, with its boxes; its picture until the recording's ready (or if there's none).
    var clip: some View {
        ZStack {
            EventPicture(event: event, aspect: aspect).opacity(origin == nil ? 1 : 0)
            if origin != nil, let player {
                PlayerLayerView(player: player)
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                if boxes, let origin {
                    SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                        let seconds = player.currentTime().seconds
                        DetectionBoxes(boxes: seconds.isFinite ? TimelineModel.glide(in: sightings, at: origin.addingTimeInterval(seconds)) : [],
                                       aspect: aspect)
                    }
                    .aspectRatio(aspect, contentMode: .fit)
                    .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if origin != nil {
                Button { boxes.toggle() } label: {
                    Image(systemName: "viewfinder").symbolVariant(boxes ? .fill : .none)
                        .font(.callout).frame(width: 26, height: 26).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(8)
                .help(boxes ? "Hide the boxes" : "Show boxes round what was found")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if noRecording {
                Text("No recording of this").font(.caption).padding(6).glassEffect(.regular, in: .capsule).padding(8)
            }
        }
    }

    /// The clip (a composition of the recording from a little before to a little after), looping and muted, and
    /// what was found in it.
    func prepare() async {
        // Not while the panel's sliding in (or the arrows are stepping through): the player's made once it's still.
        try? await Task.sleep(for: .seconds(0.45))
        guard !Task.isCancelled else { return }
        let from = event.start.addingTimeInterval(-Self.around)
        let to = (event.ongoing ? Date() : event.end).addingTimeInterval(Self.around)
        let recordings = self.recordings, camera = event.camera, source = self.source
        let spans = await Task.detached {
            RecordingIndex.spans(base: recordings, camera: camera, from: from, to: to, writing: true)
        }.value
        recording = spans.first { $0.start <= event.start && event.start < $0.end }?.path ?? spans.first?.path
        guard let built = await TimelineModel.composition(spans, from: from) else {
            noRecording = true
            return
        }
        let found = await Task.detached { source?.sightings(camera: camera, from: from, to: to) ?? [] }.value
        let length = min(built.end, to).timeIntervalSince(from)
        guard length > 0.5 else {
            noRecording = true
            return
        }
        guard !Task.isCancelled else { return }
        let item = AVPlayerItem(asset: built.composition)
        let player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item,
                                timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600)))
        self.player = player
        sightings = found
        origin = from
        player.play()
    }
}

/// Round a card just come in: a ring in its kind's colour that glows up as it lands and settles away, as a camera
/// just added to the live view does.
struct NewEventGlow: View {
    let color: Color
    let cornerRadius: Double
    let active: Bool

    /// How long it glows.
    static let lasts = 3.5

    var change: Animation { active ? .spring(duration: 0.5, bounce: 0.35).delay(0.35) : .easeOut(duration: 0.8) }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 3)
            // Only its own glow animates: its place and size are the card's.
            .animation(change) { ring in
                ring.shadow(color: color.opacity(0.9), radius: active ? 12 : 0)
                    .shadow(color: color.opacity(0.5), radius: active ? 24 : 0)
                    .opacity(active ? 1 : 0)
            }
            .allowsHitTesting(false)
    }
}

