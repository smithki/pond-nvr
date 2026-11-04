// Events: what the cameras saw, newest first, a card each (its picture, its subject boxed, what and when), by day.
// Beside them, a rail of every day kept, an hour a cell shaded by how much happened: where the busy times were, and
// a way to go back far at once. A card chosen opens its details in a panel on the right (its recording, looping,
// what was found boxed over it); twice, the timeline there. Filtered by camera and kind; new events come in as
// they're made (read again every ten seconds).
import NVRCore
import SwiftUI
import Understanding

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
    /// A question asked (the search field), its answer (the events shown are those it found), and whether it's
    /// being answered now.
    @State private var question = ""
    @State private var search: SearchResult?
    /// Why the last question went unanswered (the service isn't running).
    @State private var searchProblem: EventSearcher.Problem?
    @State private var searching = false
    /// It's taking a while (the models still being readied: the first search after an install or update).
    @State private var slow = false
    @Environment(\.openSettings) private var openSettingsWindow

    /// The cameras whose events are shown: this Mac's, and other Ponds' as chosen (as Live's).
    var cameras: [Config.Camera] { model.liveCameras }
    /// How far back events are kept.
    var keptDays: Int { model.config?.retention.events.days ?? 30 }

    /// The camera's, newest first.
    var forCamera: [TimelineEvent] { events.filter { camera == nil || $0.camera == camera } }
    /// Shown: the camera's, of the kinds on; of a search, those it found (best first, when it ranks them).
    var shown: [TimelineEvent] {
        let all = forCamera.filter { !hidden.contains($0.kind) }
        guard let search else { return all }
        let rank = Dictionary(search.ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let found = all.filter { rank[$0.id] != nil }
        return search.ranked ? found.sorted { rank[$0.id]! < rank[$1.id]! } : found
    }
    /// The section a search's ranked answer is in (its own, not a day's).
    static let bestMatches = Date.distantFuture
    /// The kinds there are (for the chips), in the timeline's order.
    var kinds: [TimelineEvent.Kind] { TimelineEvent.Kind.allCases.filter { k in forCamera.contains { $0.kind == k } } }

    /// Shown, by day: newest day first (or a search's ranked answer, best first, as one).
    var days: [(day: Date, events: [TimelineEvent])] {
        if search?.ranked == true { return shown.isEmpty ? [] : [(Self.bestMatches, shown)] }
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
                            counts: Dictionary(grouping: forCamera, by: \.kind).mapValues(\.count),
                            question: $question, searching: searching, slow: slow, problem: searchProblem, result: search,
                            submit: { ask() }, clear: { clearSearch() }, remove: { remove($0) })
                .padding(.top, 8)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { barHeight = $0 }
        }

        .onChange(of: selected?.id) { _, id in model.eventsState.selected = id }
        // Other Ponds shown or not: their events read again; a camera filtered by that's no longer shown let go.
        .onChange(of: model.shownPonds) { _, shown in
            if let camera = model.eventsState.camera, !shown.includes(AppModel.pond(of: camera)) { model.eventsState.camera = nil }
            Task { await load() }
        }
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
            // Opened with a question (`--search QUESTION`: for trying it, and pictures for the docs): asked at once.
            if let asked = launchArgument("--search"), question.isEmpty {
                question = asked
                ask()
            }
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
                Label(events.isEmpty ? (model.shownPonds == .all || model.remotePonds.isEmpty ? "No events yet" : "No events from \(model.shownName) yet")
                      : search != nil ? "Nothing found" : "No events here",
                      systemImage: search != nil ? "magnifyingglass" : "figure.walk.motion")
            } description: {
                if let search {
                    Text("No events match \u{201C}\(search.question)\u{201D}." + (search.appearanceIgnored
                        ? " How things looked can't be searched yet: events are still being described."
                        : " Try fewer words, or take off one of the parts it was read as."))
                } else {
                    Text(events.isEmpty
                         ? "People, vehicles, bikes and animals your cameras see appear here, each with its picture. Detection is on for each camera in its settings."
                         : "Nothing matches these filters.")
                }
            } actions: {
                // Only some Ponds shown: the others a click away.
                if model.shownPonds != .all, !model.remotePonds.isEmpty {
                    Button("Show All Ponds") {
                        model.shownPonds = .all
                        model.shownPondsNudge += 1
                    }
                }
            }
            .padding(.top, barHeight)
        } else {
            grid
        }
    }

    /// A camera's name; one that's been removed (its events kept, with its recordings, until retention lets them go)
    /// is said to be.
    // MARK: Search

    /// The question in the search field answered (or, `reading` given, a reading of it answered again: a part taken
    /// off it).
    func ask(reading: (EventQuery, Bool)? = nil) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.config != nil else { return clearSearch() }
        searching = true
        slow = false
        searchProblem = nil
        Task {
            try? await Task.sleep(for: .seconds(2))
            if searching { withAnimation(.easeOut(duration: 0.2)) { slow = true } }
        }
        Task {
            // This Mac's answer, and (with others shown) the other Ponds', at once.
            let client = model.controlClient, shown = model.shownPonds
            async let mine = EventSearcher.search(text, reading: reading, client: client)
            let asksOthers = shown != .this && !model.otherPonds.isEmpty
            async let theirs: (results: [SearchResult], events: [TimelineEvent]) = asksOthers
                ? EventSearcher.others(text, reading: reading, client: client, shown: shown) : ([], [])
            let (answer, others) = await (mine, theirs)
            // (Answered after another was asked: not this one's to show.)
            guard question.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            searching = false
            slow = false
            switch answer {
            case let .success(result):
                // Their events found that aren't in the grid yet (older than the newest it reads): added, so they show.
                let known = Set(events.map(\.id))
                let added = others.events.filter { !known.contains($0.id) && !deleted.contains($0.id) }
                withAnimation(.snappy(duration: 0.3)) {
                    if !added.isEmpty { events = (events + added).sorted { $0.start > $1.start } }
                    search = EventSearcher.merged(result, others.results, includeMine: shown.includes(nil))
                }
                request = GridScroll(kind: .top, animated: false)
            case let .failure(problem):
                searchProblem = problem
            }
        }
    }

    func clearSearch() {
        question = ""
        searching = false
        slow = false
        searchProblem = nil
        withAnimation(.snappy(duration: 0.3)) { search = nil }
    }

    /// A part of how the question was read taken off it; the rest answered again (not read again).
    func remove(_ part: SearchPart) {
        guard var query = search?.query, let byModel = search?.byModel else { return }
        switch part {
        case let .kind(k): query.kinds.remove(k)
        case let .thing(t): query.things.remove(t)
        case let .camera(c): query.cameras.remove(c)
        case let .zone(z): query.zones.remove(z)
        case .time: query.time = TimeFilter()
        case .appearance: query.appearance = nil
        }
        if query.isEmpty { return clearSearch() }
        ask(reading: (query, byModel))
    }

    /// A camera's name; with several Ponds' events together, and its Pond's (this Mac's too).
    func name(_ camera: String) -> String {
        let name = cameras.first { $0.id == camera }?.name ?? "Removed camera"
        guard model.shownPonds == .all, !model.remotePonds.isEmpty else { return name }
        let pond = AppModel.pond(of: camera).flatMap { id in model.remotePonds.first { $0.id == id }?.name } ?? model.thisPondName
        return "\(name) \u{00B7} \(pond)"
    }

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
        // (Another Pond's: not on this Mac's timeline.)
        guard event.pond == nil else { return }
        model.timelineJump = TimelineJump(camera: event.camera, time: event.start)
        model.mode = .timeline
    }

    func load() async {
        guard let source = EventSource(config: model.config) else { return }
        let from = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(keptDays - 1) * 86400)
        let to = Date().addingTimeInterval(60)
        // This Mac's (unless another Pond alone is shown), and other Ponds' as chosen.
        let own = model.shownPonds.includes(nil) ? await Task.detached { source.events(from: from, to: to) }.value : []
        let others = await model.remoteEvents(since: from)
        let found = (own + others)
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
                         name: name, title: { $0 == Self.bestMatches ? "Best Matches" : Self.dayTitle($0) },
                         choose: { event in if selected == nil { panel(event) } else { choose(event) } },
                         open: { watch($0) }, delete: { deleting = $0 },
                         onVisible: { onScreen.cards = $0 }, onTop: { atTop = $0 }, onScrolled: { scrolled = $0 },
                         onUnderBottom: { underBottom = $0 })
        }
    }

    /// As many as fit at least 300 wide in the width there is without the panel (the panel narrows them, it doesn't
    /// change how many there are a row).
    func columnCount(_ available: Double) -> Int { max(1, Int((available + 14) / (300 + 14))) }

    nonisolated static func dayTitle(_ day: Date) -> String {
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
    /// The camera filtered by, as the filter says it (its Pond's too, with several); else all of them.
    var cameraTitle: String {
        guard let id = model.eventsState.camera else { return "All Cameras" }
        let name = model.allCameraGroups.flatMap(\.cameras).first { $0.id == id }?.name ?? "A removed camera"
        guard !model.remotePonds.isEmpty else { return name }
        let pond = AppModel.pond(of: id).flatMap { p in model.remotePonds.first { $0.id == p }?.name } ?? model.thisPondName
        return "\(name) \u{00B7} \(pond)"
    }

    /// A camera to filter by (nil: all of them): one of a Pond not shown shows all Ponds, so its events are there.
    func choose(camera: String?) {
        // (At once: the toolbar's button, its glass resizing, doesn't animate its words changing well.)
        if let camera, !model.shownPonds.includes(AppModel.pond(of: camera)) {
            model.shownPonds = .all
            model.shownPondsNudge += 1
        }
        model.eventsState.camera = camera
    }

    let model: AppModel
    let cameras: [Config.Camera]
    let kinds: [TimelineEvent.Kind]
    let counts: [TimelineEvent.Kind: Int]
    /// The search: its field, whether it's being answered, how it was read (its parts, a chip each), and what's
    /// done when it's asked, cleared, or a part's taken off.
    @Binding var question: String
    let searching: Bool
    /// Searching's taking a while: said, so it doesn't look stuck. Or it couldn't be done, and why.
    var slow = false
    var problem: EventSearcher.Problem?
    let result: SearchResult?
    let submit: () -> Void
    let clear: () -> Void
    let remove: (SearchPart) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            filters
            if let problem {
                Label(problem.words, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if searching && slow {
                Label("Getting search ready\u{2026} The first search after Pond starts takes a little longer.",
                      systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if let result {
                SearchReading(result: result, remove: remove)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    var filters: some View {
        HStack(spacing: 10) {
            // As wide as the activity rail under it, whatever it lists; a tinted chip while it filters by a camera (as
            // the kinds' are while on), with a way back to all of them.
            Menu {
                let selection = Binding(get: { model.eventsState.camera }, set: { choose(camera: $0) })
                let groups = model.allCameraGroups
                let shown = groups.filter { model.shownPonds.includes($0.pond) }, hidden = groups.filter { !model.shownPonds.includes($0.pond) }
                Picker("Camera", selection: selection) {
                    Text("All Cameras").tag(String?.none)
                    // Several Ponds shown: a section each.
                    if groups.count > 1 {
                        ForEach(shown, id: \.name) { group in
                            Section(group.name) {
                                ForEach(group.cameras) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    } else {
                        Divider()
                        ForEach(cameras) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                .pickerStyle(.inline)
                // Those not shown, folded away a submenu each, so a camera is never missing from here; choosing one of
                // theirs shows its Pond as well.
                if !hidden.isEmpty {
                    Section("Other Ponds") {
                        ForEach(hidden, id: \.name) { group in
                            Menu(group.name) {
                                Picker(group.name, selection: selection) {
                                    ForEach(group.cameras) { Text($0.name).tag(Optional($0.id)) }
                                }
                                .pickerStyle(.inline)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.eventsState.camera == nil ? "video" : "video.fill")
                    Text(cameraTitle).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: ActivityRail.width)
                .background(model.eventsState.camera == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor.opacity(0.35)),
                            in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(model.eventsState.camera == nil ? 0 : 0.8), lineWidth: 1))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .overlay(alignment: .trailing) {
                // Filtering: back to every camera, at a click.
                if model.eventsState.camera != nil {
                    Button { choose(camera: nil) } label: {
                        Image(systemName: "xmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 26)
                    .help("Show every camera\u{2019}s events")
                }
            }
            .animation(.snappy(duration: 0.2), value: model.eventsState.camera)
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
            searchField
        }
    }

    /// A question in plain words: what, where, when, how it looked.
    var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search, like \u{201C}a man in a red jacket last night\u{201D}", text: $question)
                .textFieldStyle(.plain)
                .onSubmit(submit)
            if searching {
                ProgressView().controlSize(.small)
            } else if !question.isEmpty || result != nil {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 220, idealWidth: 340, maxWidth: 380)
        .glassEffect(.regular, in: .capsule)
    }
}

/// A part of how a question was read (a chip under the search field), to take off it.
enum SearchPart: Hashable {
    case kind(String), thing(String), camera(String), zone(String), time, appearance
}

/// How a question was read, a chip a part (each one taken off with its ×): what kinds and things, which cameras
/// and zones, when, and how they looked; marked when the Mac's own model read it.
struct SearchReading: View {
    let result: SearchResult
    let remove: (SearchPart) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: result.byModel ? "sparkles" : "text.magnifyingglass")
                .foregroundStyle(.secondary)
                .help(result.byModel ? "Read by Apple Intelligence, on this Mac" : "Read by plain rules (Apple Intelligence isn\u{2019}t on)")
            Text("\(result.ids.count) found:").foregroundStyle(.secondary).monospacedDigit()
            ForEach(parts, id: \.part) { item in
                HStack(spacing: 4) {
                    Text(item.title)
                    Button { remove(item.part) } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Take this off the search")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
            }
            if result.appearanceIgnored {
                Text("How things looked can\u{2019}t be searched yet: events are still being described.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    var parts: [(part: SearchPart, title: String)] {
        let q = result.query
        var out: [(SearchPart, String)] = q.kinds.sorted().map { (.kind($0), TimelineEvent.Kind(rawValue: $0)?.title ?? $0.capitalized) }
        out += q.things.sorted().map { (.thing($0), $0.capitalized) }
        out += q.cameras.sorted().map { (.camera($0), $0) }
        out += q.zones.sorted().map { (.zone($0), $0) }
        if !q.time.isEmpty { out.append((.time, Self.describe(q.time))) }
        if let appearance = q.appearance { out.append((.appearance, "Looking like \u{201C}\(appearance)\u{201D}")) }
        return out
    }

    /// When, in words: "Oct 19, 8:00 PM – Oct 20, 6:00 AM", or "8 PM – 6 AM, any day".
    static func describe(_ time: TimeFilter) -> String {
        var words: [String] = []
        if let range = time.range {
            let format = DateIntervalFormatter()
            format.dateStyle = .medium
            format.timeStyle = .short
            words.append(format.string(from: range.lowerBound, to: range.upperBound))
        }
        if let hours = time.hours {
            let day = Calendar.current.startOfDay(for: Date())
            func hour(_ h: Int) -> String {
                (Calendar.current.date(byAdding: .hour, value: h, to: day) ?? day).formatted(.dateTime.hour())
            }
            words.append("\(hour(hours.from)) \u{2013} \(hour(hours.to))" + (time.range == nil ? ", any day" : ""))
        }
        return words.joined(separator: ", ")
    }
}
