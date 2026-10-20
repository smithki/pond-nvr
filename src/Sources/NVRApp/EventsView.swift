// Events: what the cameras saw, newest first, a card each (its picture, its subject boxed, what and when), by day.
// Beside them, a rail of every day kept, an hour a cell shaded by how much happened: where the busy times were, and
// a way to go back far at once. A card chosen opens its details in a panel on the right (its recording, looping,
// what was found boxed over it); twice, the timeline there. Filtered by camera and kind; new events come in as
// they're made (read again every ten seconds).
import NVRCore
import SwiftUI

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
    /// The event the user's asked to delete (confirming), and those deleted (a read under way as they were may
    /// still have them).
    @State private var deleting: TimelineEvent?
    @State private var deleted: Set<String> = []
    /// How tall the filters' bar is (the grid scrolls on under it; the rail and panel start below it), and whether
    /// the grid's scrolled at all (anything under it: its glass shows).
    @State private var barHeight = 56.0
    @State private var scrolled = false
    /// Whether any card's in the strip at the grid's bottom (its glass shows).
    @State private var underBottom = false
    @Environment(\.openSettings) private var openSettingsWindow

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
        // The grid runs the view's whole height: up under the filters' bar (glass over it, the window's width, once
        // anything's under it) and down to the window's edge (under glass there too). The rail and the panel sit
        // between the two.
        HStack(alignment: .top, spacing: 14) {
            OnScreenRail(events: shown, days: keptDays, onScreen: onScreen, retention: {
                model.settingsTab = .retention
                openSettingsWindow()
            }) { hour in
                // The first card at or after that hour (newest first: the last one before the next hour).
                let next = hour.addingTimeInterval(3600)
                if let target = shown.last(where: { $0.start < next && $0.start >= hour }) ?? shown.first(where: { $0.start < next }) {
                    request = GridScroll(kind: .centre(target.id, always: true))
                }
            }
            .frame(width: ActivityRail.width)
            .padding(.top, barHeight)
            .zIndex(1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The panel's room (the panel's drawn over the glass at the window's edge, below).
            if selected != nil {
                Color.clear.frame(width: EventDetail.width)
            }
        }
        .padding(.horizontal, 16)
        // (The toolbar without a backing of its own: with the window inactive, macOS 26 draws a hairline under its
        // backing across the grid's top, the grid running up to it. Still needed? `swift scripts/capture-window.swift
        // out.png --inactive` without this, and look under the toolbar.)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Glass over the grid's edges, blurring the cards that scroll on under them, the window's width, while
        // anything's under it: under the filters, easing out just below; at the window's edge, easing in towards it.
        .overlay(alignment: .bottom) {
            EdgeGlass(fromTop: false)
                .frame(height: Self.bottomFade)
                .opacity(underBottom ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: underBottom)
        }
        // The panel, over the glass's layer and clear of it at the bottom (a surface of its own): an event's own (its
        // own player), swapped at once from one to the next; it slides in and out only as it opens and closes.
        .overlay(alignment: .topTrailing) {
            if let selected {
                ZStack {
                    EventDetail(event: selected, camera: name(selected.camera), recordings: model.config?.storage.recordingsPath ?? "",
                                source: EventSource(config: model.config),
                                watch: { watch(selected) }, close: { panel(nil) }, delete: { deleting = selected },
                                earlier: neighbour(of: selected, later: false).map { e in { choose(e) } },
                                later: neighbour(of: selected, later: true).map { e in { choose(e) } })
                        .id(selected.id)
                        .transition(.identity)
                }
                .frame(width: EventDetail.width)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, barHeight)
                // (Ending where the glass at the window's edge begins: clear of it.)
                .padding(.bottom, Self.bottomFade)
                .padding(.trailing, 16)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            EdgeGlass(fromTop: true)
                .frame(height: barHeight + Self.glassEase)
                .opacity(scrolled ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: scrolled)
        }
        .overlay(alignment: .top) {
            EventsFilterBar(model: model, cameras: cameras, kinds: kinds,
                            counts: Dictionary(grouping: forCamera, by: \.kind).mapValues(\.count))
                .padding(.top, 8)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { barHeight = $0 }
        }

        .onChange(of: selected?.id) { _, id in model.eventsState.selected = id }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let selected else { return .ignored }
            deleting = selected
            return .handled
        }
        .confirmationDialog("Delete this event?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { event in
            Button("Delete", role: .destructive) { delete(event) }
        } message: { _ in
            Text("Its picture is deleted too. The recording it's in is kept.")
        }
        .onKeyPress(.escape) {
            guard selected != nil else { return .ignored }
            panel(nil)
            return .handled
        }
        // As the grid has them: newer to the left, older to the right.
        .onKeyPress(.leftArrow) {
            guard let selected, let e = neighbour(of: selected, later: true) else { return .ignored }
            choose(e)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard let selected, let e = neighbour(of: selected, later: false) else { return .ignored }
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

    /// How far below the filters' bar the glass under it eases out.
    static let glassEase = 14.0

    /// The strip at the grid's bottom the cards scroll on under (softened there, to the window's edge).
    static let bottomFade = 80.0

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
            .padding(.top, barHeight)
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

    /// Deleted: gone from the grid (the others closing up), the panel on to the one after it (older; or before, at
    /// the end), or closed.
    func delete(_ event: TimelineEvent) {
        deleted.insert(event.id)
        if selected?.id == event.id {
            if let next = neighbour(of: event, later: false) ?? neighbour(of: event, later: true) {
                choose(next)
            } else {
                panel(nil)
            }
        }
        withAnimation(EventGrid.panelAnimation) { events.removeAll { $0.id == event.id } }
        let source = EventSource(config: model.config)
        Task.detached { source?.delete([event.id]) }
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
            .filter { $0.kind != .privacy && !deleted.contains($0.id) }
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
                         panelOpen: open, topInset: barHeight, bottomInset: Self.bottomFade, panelWidth: EventDetail.width + 14,
                         focus: focus, selected: selected?.id, fresh: fresh, request: $request,
                         name: name,
                         choose: { event in if selected == nil { panel(event) } else { choose(event) } },
                         open: { watch($0) }, delete: { deleting = $0 },
                         onVisible: { onScreen.cards = $0 }, onTop: { atTop = $0 }, onScrolled: { scrolled = $0 },
                         onUnderBottom: { underBottom = $0 })
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

/// Glass over an edge of the grid, blurring the cards under it: whole at the edge, fading to nothing away from it.
struct EdgeGlass: View {
    let fromTop: Bool
    @Environment(\.colorScheme) private var scheme

    /// How far it's toned back towards the window (glass lifts what's under it: lighter in the dark, and the other
    /// way in the light), so the edges don't stand out brighter, or duller, than what's between them.
    static let toned = 0.2

    var body: some View {
        Rectangle()
            .fill(.clear)
            .glassEffect(.regular.tint((scheme == .dark ? Color.black : Color.white).opacity(Self.toned)), in: Rectangle())
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: fromTop ? 0.55 : 0.15),
                                         .init(color: .black.opacity(0), location: 1)],
                                 startPoint: fromTop ? .top : .bottom, endPoint: fromTop ? .bottom : .top))
            .allowsHitTesting(false)
    }
}

/// The filters, a bar over the top of the grid: the camera, and a chip a kind (how many there are of it), on or off.
struct EventsFilterBar: View {
    let model: AppModel
    let cameras: [Config.Camera]
    let kinds: [TimelineEvent.Kind]
    let counts: [TimelineEvent.Kind: Int]

    var body: some View {
        HStack(spacing: 10) {
            Picker("Camera", selection: Binding(get: { model.eventsState.camera }, set: { model.eventsState.camera = $0 })) {
                Text("All Cameras").tag(String?.none)
                Divider()
                ForEach(cameras) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
            ForEach(kinds) { kind in
                let on = !model.eventsState.hidden.contains(kind)
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        if on { model.eventsState.hidden.insert(kind) } else { model.eventsState.hidden.remove(kind) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol).foregroundStyle(on ? kind.color : .secondary)
                        Text(kind.title)
                        Text("\(counts[kind] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
