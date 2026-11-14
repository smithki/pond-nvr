// Events: what the cameras saw, newest first, a card each (its picture, its subject boxed, what and when), by day.
// Beside them, a rail of every day kept, an hour a cell shaded by how much happened: where the busy times were, and
// a way to go back far at once. A card chosen opens its details in a panel on the right (its recording, looping,
// what was found boxed over it); twice, the timeline there. Filtered by camera and kind; new events come in as
// they're made (read again every ten seconds).
import PondCore
import SwiftUI
import Understanding

struct EventsView: View {
    @Environment(AppModel.self) private var model
    @State private var events: [TimelineEvent] = []
    @State private var loaded = false
    /// The event whose details are open, one camera's events or all (nil), the kinds hidden: kept with the app's
    /// model, so coming back (the toolbar's back, say) finds the view as it was left.
    @State private var selected: TimelineEvent?
    /// The grid's made room for the panel (with it, as one move).
    @State private var roomMade = false
    /// Events read while scrolled down that would move the cards, waiting; and whether it's near the top.
    @State private var held: Read?
    @State private var near = true
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
    @State private var indexKept = IndexKept()
    /// Counts up as the events change (each change, however small): what the index is of.
    @State private var eventsVersion = 0
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
    /// A search's answer by best match (one that can be: how things looked asked about), else newest first. Its
    /// own switch, under the search, says which; each answer begins by best match when it can be.
    @State private var bestMatch = true
    /// Shown by best match now: no days, the rail dimmed, each card dated.
    var byBestMatch: Bool { index.days.first?.day == Self.bestMatches }
    /// Why the last question went unanswered (the service isn't running).
    @State private var searchProblem: EventSearcher.Problem?
    @State private var searching = false
    /// It's taking a while (the models still being readied: the first search after an install or update).
    @State private var slow = false
    /// Whether the window's in front: a card on screen counts as seen only then.
    @Environment(\.controlActiveState) private var windowState
    /// On screen this long, a new card's seen (not just scrolled past).
    static let seenAfter = 1.0

    /// The cameras whose events are shown: this Mac's, and other Ponds' as chosen (as Live's).
    var cameras: [Config.Camera] { model.liveCameras }
    /// How far back events are kept.
    var keptDays: Int { model.config?.retention.events.days ?? 30 }

    /// What's being looked at: which new cards, and whether the window's in front.
    struct Looking: Equatable {
        var cards: Set<String>
        var front: Bool
    }

    /// The section a search's answer is in shown by best match (its own, not a day's).
    nonisolated static let bestMatches = Date.distantFuture

    /// Everything shown that's worked out from the events, worked out once for what it's of (`IndexKey`) and kept: the
    /// view's made again often (the panel opening, each step, the filters), and with a large library, going through
    /// every event each time (as these were, each its own pass, dozens a time) froze the panel's and the grid's moves.
    struct EventsIndex: Sendable {
        /// The camera's (or every camera's), quieted or not as asked; and how many of the camera's are quieted.
        var forCamera: [TimelineEvent] = []
        var quietedCount = 0
        /// Shown: those of the kinds on (and new, if asked); of a search, those it found (best first, when ranked).
        var shown: [TimelineEvent] = []
        /// Each shown one's place in `shown` (the arrows' next and previous, at once).
        var position: [String: Int] = [:]
        /// The kinds there are (for the chips), in the timeline's order, and how many of each.
        var kinds: [TimelineEvent.Kind] = []
        var counts: [TimelineEvent.Kind: Int] = [:]
        /// The camera's new ones, and those of them shown.
        var newIDs: Set<String> = []
        var unseen: Set<String> = []
        /// Shown, by day: newest day first (or a search's answer by best match, best first, as one).
        var days: [(day: Date, events: [TimelineEvent])] = []
        /// Shown, an hour at a time (the rail's shading), by the hour's start.
        var hourCounts: [Date: Int] = [:]
        /// The grid's: its sections, and the shown by id. Made once here (made as the grid was, each time Events was
        /// worked out, the grid's were new each time, and compared, event by event, many times a second).
        var sections: [EventGridLayout.Section] = []
        var byID: [String: TimelineEvent] = [:]
    }

    /// What the index is of: compared each time it's asked for, cheaply (the events by their version, what's seen by
    /// its own), so it's worked out again only once one of them has changed.
    struct IndexKey: Equatable, Sendable {
        var events: Int
        var camera: String?
        var hidden: Set<TimelineEvent.Kind>
        var quietedOnly: Bool
        var newOnly: Set<String>?
        var search: [String]?
        var ranked: Bool
        var seen: Int
    }

    /// The index as last worked out, and what of (not watched: a cache).
    final class IndexKept {
        var key: IndexKey?
        var seen: Int?
        var index = EventsIndex()
    }

    /// What the index would be of, for the events of `version`.
    func indexKey(events version: Int) -> IndexKey {
        IndexKey(events: version, camera: camera, hidden: hidden, quietedOnly: model.eventsState.quietedOnly,
                 newOnly: model.eventsState.newOnly, search: search?.ids, ranked: (search?.ranked ?? false) && bestMatch,
                 // What's seen changes what's shown only with only the new shown; otherwise just which are new is
                 // worked out again (one seen after another, as they come on screen: the whole index each time was
                 // too much).
                 seen: model.eventsState.newOnly != nil ? model.seenEvents.version : 0)
    }

    var index: EventsIndex {
        let seen = model.seenEvents.version
        let key = indexKey(events: eventsVersion)
        if indexKept.key == key {
            if indexKept.seen != seen {
                Self.renew(&indexKept.index, isNew: model.seenEvents.newness)
                indexKept.seen = seen
            }
            return indexKept.index
        }
        let made = Self.index(of: events, key: key, isNew: model.seenEvents.newness)
        indexKept.key = key
        indexKept.seen = seen
        indexKept.index = made
        return made
    }

    /// Which are new, worked out again (what's seen having changed).
    nonisolated static func renew(_ index: inout EventsIndex, isNew: (TimelineEvent) -> Bool) {
        let newIDs = Set(index.forCamera.lazy.filter(isNew).map(\.id))
        guard newIDs != index.newIDs else { return }
        index.newIDs = newIDs
        index.unseen = Set(index.shown.lazy.filter { newIDs.contains($0.id) }.map(\.id))
    }

    /// Worked out in one pass over the events (and one over those shown).
    nonisolated static func index(of events: [TimelineEvent], key: IndexKey, isNew: (TimelineEvent) -> Bool) -> EventsIndex {
        var index = EventsIndex()
        for event in events where key.camera == nil || event.camera == key.camera {
            if event.quieted != nil { index.quietedCount += 1 }
            guard (event.quieted != nil) == key.quietedOnly else { continue }
            index.forCamera.append(event)
            index.counts[event.kind, default: 0] += 1
            if isNew(event) { index.newIDs.insert(event.id) }
        }
        index.kinds = TimelineEvent.Kind.allCases.filter { index.counts[$0] != nil }
        var shown = index.forCamera.filter { event in
            !key.hidden.contains(event.kind) && (key.newOnly.map { $0.contains(event.id) || index.newIDs.contains(event.id) } ?? true)
        }
        if let ids = key.search {
            let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            shown = shown.filter { rank[$0.id] != nil }
            if key.ranked { shown.sort { rank[$0.id]! < rank[$1.id]! } }
        }
        index.shown = shown
        index.position = Dictionary(shown.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        index.unseen = Set(shown.lazy.filter { index.newIDs.contains($0.id) }.map(\.id))
        let calendar = Calendar.current
        if key.ranked {
            index.days = shown.isEmpty ? [] : [(Self.bestMatches, shown)]
        } else {
            var byDay: [Date: [TimelineEvent]] = [:]
            for event in shown { byDay[calendar.startOfDay(for: event.start), default: []].append(event) }
            index.days = byDay.map { (day: $0.key, events: $0.value) }.sorted { $0.day > $1.day }
        }
        index.sections = index.days.map { EventGridLayout.Section(day: $0.day, ids: $0.events.map(\.id)) }
        index.byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for event in shown {
            if let hour = calendar.dateInterval(of: .hour, for: event.start)?.start { index.hourCounts[hour, default: 0] += 1 }
        }
        return index
    }

    var forCamera: [TimelineEvent] { index.forCamera }
    var quietedCount: Int { index.quietedCount }
    var shown: [TimelineEvent] { index.shown }
    var kinds: [TimelineEvent.Kind] { index.kinds }
    var days: [(day: Date, events: [TimelineEvent])] { index.days }

    /// The window's size class, from its width: what's beside the grid, and how the panel opens. Changes of class
    /// animate (the rail sliding away or back); the grid reflowing as the window's resized within one doesn't.
    enum SizeClass {
        /// No room for the rail; the panel covers the cards, the window's width, until closed.
        case narrow
        /// The rail, which slides away for the panel (the cards would be too cramped beside both).
        case medium
        /// The rail, and the panel beside it.
        case wide

        @MainActor init(_ width: Double) {
            self = width == 0 || width >= EventsView.railWithPanelNeeds ? .wide : width >= EventsView.railNeeds ? .medium : .narrow
        }
    }
    @State private var sizeClass = SizeClass.wide

    /// Whether the window's wide enough for the rail (the filters' camera menu is as wide as it then, over it).
    var railFits: Bool { sizeClass != .narrow }
    static let railNeeds = 760.0
    @State private var opened = false

    /// How wide the cards are with the rail and the panel both beside them, in a window this wide (as many a row as
    /// with the panel closed).
    static func cardsBesidePanel(_ width: Double) -> Double {
        let closed = width - 32 - (ActivityRail.width + 14)
        let columns = Double(columnCount(closed))
        return (closed - (EventDetail.width + 14) - 14 * (columns - 1)) / columns
    }
    /// How wide the window must be for the cards beside both the rail and the panel never to be too cramped, at it
    /// or wider. (The cards' width jumps as a row gains a card: one width, not the cards' own, so the rail doesn't
    /// come and go as the window's resized.)
    static let railWithPanelNeeds: Double = {
        var width = 3000.0
        while width > railNeeds, cardsBesidePanel(width - 1) >= cardsNeed { width -= 1 }
        return width
    }()
    /// With the panel open, the rail goes (sliding away) when the cards would be too cramped beside both.
    var railMakesRoom: Bool { sizeClass == .medium }
    /// Narrower than the rail needs, the panel isn't beside the cards but over them, the window's width, until closed.
    var panelCovers: Bool { sizeClass == .narrow }
    /// How narrow the cards can get beside the panel (a row of them likes 300).
    static let cardsNeed = 220.0

    /// The cards faded away under the panel (a narrow window, an event open).
    var cardsHidden: Bool { selected != nil && panelCovers }
    var railShown: Bool { railFits && !(roomMade && railMakesRoom) }
    /// Where the grid begins: beside the rail, when it's there.
    var gridLeading: Double { railShown ? ActivityRail.width + 14 : 0 }
    /// How much narrower the panel opening makes the grid (less the rail's room, when it goes as the panel comes).
    var panelTakes: Double { EventDetail.width + 14 - (railMakesRoom ? ActivityRail.width + 14 : 0) }

    /// The page's surface: the cards, the rail beside them, the glass at the window's edge and the panel over it,
    /// laid out and moved as one by `EventsShell`.
    var layers: some View { shell }

    /// The width the page has (the grid's room worked out from it, for the AppKit shell).
    @State private var shellWidth = 0.0

    var shell: some View {
        let open = roomMade && !panelCovers
        let gridWidth = max(200, shellWidth - 32 - gridLeading - (open ? EventDetail.width + 14 : 0))
        let showsGrid = loaded && !shown.isEmpty
        let placeholder: AnyView? = showsGrid ? nil : AnyView(content)
        let rail: AnyView? = railShown ? AnyView(railView) : nil
        return EventsShell(grid: showsGrid ? makeGrid(width: gridWidth) : nil, placeholder: placeholder,
                           rail: rail,
                           railKey: EventsShell.RailKey(hourCounts: index.hourCounts, days: keptDays, dimmed: byBestMatch, shown: index.shown.count),
                           selected: selected,
                           panelFor: { AnyView(panelView($0)) },
                           skeletonFor: { event in
                               AnyView(EventDetail.skeleton(event: event, camera: name(event.camera), covers: panelCovers)
                                   .background { EventDetail.shape(covering: panelCovers).fill(Color(nsColor: .windowBackgroundColor)) })
                           },
                           panelKey: selected.map { s in
                               EventsShell.PanelKey(event: s, camera: name(s.camera),
                                                    earlier: neighbour(of: s, later: false)?.id, later: neighbour(of: s, later: true)?.id,
                                                    covers: panelCovers)
                           },
                           glass: AnyView(EdgeGlass(fromTop: false)), glassShown: underBottom,
                           barHeight: barHeight, gridLeading: gridLeading, roomMade: roomMade, panelCovers: panelCovers,
                           cardsHidden: cardsHidden, model: model)
    }

    /// The rail, as it's drawn beside the cards.
    var railView: some View {
        OnScreenRail(shown: index.shown, position: index.position, hourCounts: index.hourCounts, days: keptDays,
                     onScreen: onScreen, dimmed: byBestMatch, retention: {
            model.showSettings(.storage)
        }) { hour in
            // The first card at or after that hour (newest first: the last one before the next hour).
            let next = hour.addingTimeInterval(3600)
            if let target = shown.last(where: { $0.start < next && $0.start >= hour }) ?? shown.first(where: { $0.start < next }) {
                request = GridScroll(kind: .centre(target.id, always: true))
            }
        }
    }

    /// The panel's own: an event's details, on the window's surface.
    func panelView(_ selected: TimelineEvent) -> some View {
        EventDetail(event: selected, camera: name(selected.camera), recordings: model.config?.storage.recordingsPath ?? "",
                    source: EventSource(config: model.config),
                    watch: { watch(selected) }, close: { panel(nil) }, delete: { deleting = selected },
                    earlier: neighbour(of: selected, later: false).map { e in { choose(e) } },
                    later: neighbour(of: selected, later: true).map { e in { choose(e) } })
            .id(selected.id)
            .background { EventDetail.shape(covering: panelCovers).fill(Color(nsColor: .windowBackgroundColor)) }
            .environment(\.panelCovers, panelCovers)
    }

    var body: some View {
        // The grid runs the view's whole height: up under the filters' bar (glass over it, the window's width, once
        // anything's under it) and down to the window's edge (under glass there too). The rail and the panel sit
        // between the two.
        // The grid given its room at once, as it will be (the rail's and the panel's taken off its sides, not
        // animated): it moves its cards there itself, from where they were. Its room animated with the rail and the
        // panel, it was laid out again at each width on the way, a row losing a card and getting it back as the rail
        // went and the panel came. The rail slides over its side.
        layers
        // (The toolbar without a backing of its own: with the window inactive, macOS 26 draws a hairline under its
        // backing across the grid's top, the grid running up to it. Still needed? `swift scripts/capture-window.swift
        // out.png --inactive` without this, and look under the toolbar.)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // New cards on screen a moment, the window in front and the cards not under the panel: seen. By a view of its
        // own, which alone reads what's on screen: read here, every row the grid scrolled past made this whole view
        // again (and its list of events gone through dozens of times), mid-scroll.
        .background {
            SeenOnScreen(onScreen: onScreen, unseen: index.unseen, shown: index.shown, position: index.position,
                         looking: windowState == .key && !cardsHidden)
        }
        // And one opened.
        .onChange(of: selected?.id) { if let selected { model.seenEvents.saw([selected]) } }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { new in
            // Into another size class: the rail and the panel move to their new places, animated.
            let next = SizeClass(new)
            if next != sizeClass { withAnimation(EventGrid.panelAnimation) { sizeClass = next } }
            shellWidth = new
        }
        .overlay(alignment: .top) {
            EdgeGlass(fromTop: true)
                .frame(height: barHeight + Self.glassEase)
                .opacity(scrolled && !cardsHidden ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: scrolled)
        }
        .overlay(alignment: .top) {
            EventsFilterBar(model: model, cameras: cameras, railShown: railFits, kinds: kinds,
                            counts: index.counts,
                            newCount: model.eventsState.newOnly != nil ? shown.count : index.newIDs.count,
                            newIDs: index.newIDs, quietedCount: quietedCount,
                            question: $question, searching: searching, slow: slow, problem: searchProblem, result: search,
                            submit: { ask() }, clear: { clearSearch() }, remove: { remove($0) })
                .equatable()
                .padding(.top, 8)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
                    // (The grid's top moving with the bar as a row under the filters comes or goes, at the row's pace.)
                    // (Measured the first time: at once.)
                    withAnimation(barHeight == 0 ? nil : .smooth(duration: 0.35)) { barHeight = height }
                }
        }

        .onChange(of: selected?.id) { _, id in model.eventsSelected = id }
        // (The snapshot mode's transition check, doing as the user would.)
        .onChange(of: model.eventsDrive) { _, drive in
            guard let drive else { return }
            let list = shown
            switch drive.action {
            case let .open(n): if list.indices.contains(n) { panel(list[n]) }
            case .close: panel(nil)
            case let .step(later): if let selected, let next = neighbour(of: selected, later: later) { choose(next) }
            case let .centre(n): if list.indices.contains(n) { request = GridScroll(kind: .centre(list[n].id, always: true)) }
            }
        }
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
        // Something said of an event: read again (what's like it, quieted).
        .onChange(of: model.feedbackChanged) { Task { await load() } }
        .task {
            // Opened with a question (`--search QUESTION`: for trying it, and pictures for the docs): asked at once.
            if let asked = launchArgument("--search"), question.isEmpty {
                question = asked
                ask()
            }
            // New ones as they're made: read again every ten seconds.
            while !Task.isCancelled {
                await load()
                // (`--open-event`: the newest opened in the panel, once loaded: for trying it, and pictures.)
                if !opened, CommandLine.arguments.contains("--open-event"), let first = shown.first {
                    opened = true
                    panel(first)
                }
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
            // (The grid's the shell's own.)
            EmptyView()
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
                let answer = EventSearcher.merged(result, others.results, includeMine: shown.includes(nil))
                // The grid crossfades to the answer, at its top.
                // (Into a search from all of them: where they were kept, to come back to.)
                swap(top: true, remember: search == nil) {
                    if !added.isEmpty {
                        events = (events + added).sorted { $0.start > $1.start }
                        eventsVersion += 1
                    }
                    search = answer
                    bestMatch = true
                }
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
        // Back to them all, the card at the top still there.
        // (Back where it was before the search.)
        if search != nil { swap(top: false, restore: true) { search = nil } }
    }

    /// The events shown changed wholesale: by the grid, faded out and in, if it's shown (else at once).
    func swap(top: Bool, remember: Bool = false, restore: Bool = false, _ change: @escaping @MainActor () -> Void) {
        if loaded, !shown.isEmpty {
            request = GridScroll(kind: .swap(top: top), change: changed(change), remember: remember, restore: restore)
        } else {
            withAnimation(.snappy(duration: 0.3)) { change() }
        }
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
    /// row glides to the middle of the grid (the grid scrolls in it), all as one move.
    func panel(_ event: TimelineEvent?) {
        focus = (event ?? selected)?.id
        let open = event != nil
        // (One curve, the grid's zoom's: the panel and the rail move with the cards.)
        withAnimation(EventGrid.reshapeAnimation) {
            selected = event
            roomMade = open
        }
    }

    /// The event shown just before or after this one (the grid is newest first).
    func neighbour(of event: TimelineEvent, later: Bool) -> TimelineEvent? {
        let index = self.index
        guard let i = index.position[event.id] else { return nil }
        let j = later ? i - 1 : i + 1
        return index.shown.indices.contains(j) ? index.shown[j] : nil
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
        withAnimation(EventGrid.panelAnimation) {
            events.removeAll { $0.id == event.id }
            eventsVersion += 1
        }
        let source = EventSource(config: model.config)
        Task.detached { source?.delete([event.id]) }
    }

    func watch(_ event: TimelineEvent) {
        // (Another Pond's: not on this Mac's timeline.)
        guard event.pond == nil else { return }
        model.timelineJump = TimelineJump(camera: event.camera, time: event.start)
        model.mode = .timeline
    }

    /// Events read, and what's worked out from them, to show (or, scrolled down, held back until the Now button or
    /// a scroll up lets them in).
    struct Read: Sendable {
        let found: [TimelineEvent]
        /// Those there were when they were read, and those that weren't among them.
        let before: [TimelineEvent]
        let arrived: Set<String>
        /// Whether any came or went (moving the cards), or only changed.
        let moves: Bool
        let version: Int
        let key: IndexKey
        let seen: Int
        let index: EventsIndex
    }

    /// Shown (the grid moving with them at the top: `animated`), if those there are are still those they were
    /// read beside (else read again).
    func take(_ read: Read, animated: Bool) {
        guard events == read.before else {
            Task { await load() }
            return
        }
        withAnimation(animated ? .snappy(duration: 0.4) : nil) {
            events = read.found
            eventsVersion = read.version
        }
        // (Kept for these events, unless what it's of changed meanwhile: then worked out again when asked.)
        if indexKey(events: read.version) == read.key, model.seenEvents.version == read.seen {
            indexKept.key = read.key
            indexKept.seen = read.seen
            indexKept.index = read.index
        }
        let arrived = read.arrived
        if !arrived.isEmpty {
            fresh.formUnion(arrived)
            Task {
                try? await Task.sleep(for: .seconds(NewEventGlow.lasts))
                fresh.subtract(arrived)
            }
        }
    }

    /// A change, made for the grid: told whether what it shows changed with it.
    func changed(_ change: @escaping @MainActor () -> Void) -> GridChange {
        { @MainActor in
            let before = index.sections
            change()
            return index.sections != before
        }
    }

    /// Those held back, let in (the Now button, as the grid goes up).
    func letHeldIn() {
        guard let held else { return }
        self.held = nil
        take(held, animated: false)
    }

    func load() async {
        guard let source = EventSource(config: model.config) else { return }
        let from = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(keptDays - 1) * 86400)
        let to = Date().addingTimeInterval(60)
        // This Mac's (unless another Pond alone is shown), and other Ponds' as chosen.
        let own = model.shownPonds.includes(nil) ? await Task.detached { source.events(from: from, to: to) }.value : []
        let others = await model.remoteEvents(since: from)
        // What's new among them, for the counts (another Pond's are known only as Events reads them).
        let after = model.seenEvents.before
        let (ownRecent, othersRecent) = await Task.detached {
            (EventsSeen.recent(own, after: after), EventsSeen.recent(others, after: after))
        }.value
        if model.shownPonds.includes(nil) { model.seenEvents.found(recent: ownRecent, elsewhere: false) }
        model.seenEvents.found(recent: othersRecent, elsewhere: true)
        // Sorted, compared with those there are, and the index of them worked out, away from the main thread (each
        // read, every ten seconds, held up the grid's moving otherwise, tens of milliseconds with many events).
        let deleted = deleted, before = events, version = eventsVersion + 1, first = !loaded
        let key = indexKey(events: version), seen = model.seenEvents.version, isNew = model.seenEvents.newness
        let read = await Task.detached { () -> Read? in
            let found = (own + others)
                .filter { $0.kind != .privacy && !deleted.contains($0.id) }
                .sorted { $0.start > $1.start }
            guard found != before else { return nil }
            // New ones (after the first read) come in smoothly, the others making room, and glow a moment.
            let arrived = !first ? Set(found.map(\.id)).subtracting(before.map(\.id)) : []
            return Read(found: found, before: before, arrived: arrived, moves: found.map(\.id) != before.map(\.id),
                        version: version, key: key, seen: seen, index: Self.index(of: found, key: key, isNew: isNew))
        }.value
        if let read, events == before {
            // Further down than a short scroll from the top, those that would move the cards (come or gone) wait,
            // counted on the Now button, which lets them in as it goes up (or they come in once it's near the top):
            // the cards on screen not moved by them as they're read or as the panel reshapes them.
            if loaded, read.moves, !near {
                held = read
            } else {
                held = nil
                take(read, animated: loaded && atTop)
            }
        }
        // The open one, as it is now (an ongoing one goes on); on coming back, the one that was open, in view.
        if let open = selected, let now = events.first(where: { $0.id == open.id }), now != open { selected = now }
        if !loaded, selected == nil, let id = model.eventsSelected, let was = events.first(where: { $0.id == id }) {
            selected = was
            roomMade = true
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
    /// The grid's inputs, for a grid `width` wide.
    func makeGrid(width: Double) -> EventGrid {
        let open = roomMade && !panelCovers
        let index = self.index
        // Each camera named once here, not as each card's made.
        let named = Dictionary(cameras.map { ($0.id, name($0.id)) }, uniquingKeysWith: { a, _ in a })
        let names: (String) -> String = { named[$0] ?? name($0) }
        return EventGrid(sections: index.sections, events: index.byID,
                         width: width,
                         // (One a row in a narrow window, whatever its width: two fit at its widest, and going between one
                         // and two there, by a few points, the rows kept changing.)
                         columns: sizeClass == .narrow ? 1 : Self.columnCount(width + (open ? panelTakes : 0)),
                         panelOpen: open, leading: gridLeading, topInset: barHeight, bottomInset: Self.bottomFade, panelWidth: panelTakes,
                         focus: focus, selected: selected?.id, fresh: fresh,
                         unseen: index.unseen, request: $request,
                         name: names, title: { $0 == Self.bestMatches ? "Best Matches" : Self.dayTitle($0) },
                         choose: { event in if selected == nil { panel(event) } else { choose(event) } },
                         open: { watch($0) }, delete: { deleting = $0 },
                         onVisible: { onScreen.tell($0) }, onTop: { atTop = $0 },
                         onNear: { now in
                             near = now
                             if now, let held { self.held = nil; take(held, animated: atTop) }
                         },
                         newWaiting: held.map { $0.arrived.count } ?? 0,
                         letIn: held == nil ? nil : changed { letHeldIn() },
                         onScrolled: { scrolled = $0 },
                         onUnderBottom: { underBottom = $0 },
                         byBestMatch: byBestMatch,
                         order: search.map { found in
                             EventGrid.GridOrder(bestMatch: byBestMatch, canRank: found.ranked) { best in
                                 swap(top: true) { bestMatch = best }
                             }
                         })
    }

    /// As many as fit at least 300 wide in the width there is without the panel (the panel narrows them, it doesn't
    /// change how many there are a row).
    static func columnCount(_ available: Double) -> Int { max(1, Int((available + 14) / (300 + 14))) }

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
struct EventsFilterBar: View, Equatable {
    /// The same bar, from what it shows (not what's done on asking: closures, never equal, had it worked out again on
    /// every change to Events, many times a second as the grid moves).
    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            a.model === b.model && a.cameras == b.cameras && a.railShown == b.railShown && a.kinds == b.kinds
                && a.counts == b.counts && a.newCount == b.newCount && a.newIDs == b.newIDs
                && a.quietedCount == b.quietedCount && a.question == b.question && a.searching == b.searching
                && a.slow == b.slow && a.problem == b.problem && a.result == b.result
        }
    }

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
    /// The activity rail's under the camera filter (not in a narrow window): the filter as wide as it.
    var railShown = true
    let kinds: [TimelineEvent.Kind]
    let counts: [TimelineEvent.Kind: Int]
    /// How many are new (or, with only the new shown, how many those are), and the new ones' ids, for New's chip.
    var newCount = 0
    var newIDs: Set<String> = []
    /// How many are quieted (probably nothing), for their chip.
    var quietedCount = 0
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
            Group {
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
            // Down from under the filters, out of a blur, and back up into them; one to the next, crossfading.
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -10)).combined(with: Self.focusing),
                                    removal: .opacity.combined(with: .offset(y: -10)).combined(with: Self.focusing)))
        }
        .animation(.smooth(duration: 0.35), value: row)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Which row's under the filters (for its coming and going, and from one to another).
    enum Row: Equatable { case none, problem, slow, result }

    var row: Row { problem != nil ? .problem : searching && slow ? .slow : result != nil ? .result : .none }

    /// Coming into focus as it comes, out of it as it goes.
    static let focusing = AnyTransition.modifier(active: Blurring(radius: 6), identity: Blurring(radius: 0))

    struct Blurring: ViewModifier {
        let radius: Double
        func body(content: Content) -> some View { content.blur(radius: radius) }
    }

    // As much as fits, in one row while it can: the kinds named and the search roomy; the search narrower (its
    // placeholder just "Search"); the kinds by their symbols; the kinds in one menu. Then two rows, the search across the
    // second. Chosen by what each piece measures against the bar's width (each its own width: squeezed, a chip's words
    // broke a letter at a time).
    @ViewBuilder
    var filters: some View {
        Group {
            switch layout {
            case .named: row { kindChips(titled: true) } search: { searchField(fill: false) }
            case .namedCompact: row { kindChips(titled: true) } search: { searchField(fill: false, compact: true) }
            case .symbols: row { kindChips(titled: false) } search: { searchField(fill: false, compact: true) }
            case .menu: row { kindsMenu } search: { searchField(fill: false, compact: true) }
            case .twoRows:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        cameraFilter
                        kindsMenu
                        Spacer(minLength: 0)
                    }
                    searchField(fill: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { barWidth = $0 }
        // The pieces' own widths, measured unseen.
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                kindChips(titled: true).onGeometryChange(for: Double.self) { $0.size.width } action: { namedWidth = $0 }
                kindChips(titled: false).onGeometryChange(for: Double.self) { $0.size.width } action: { symbolsWidth = $0 }
                kindsMenu.onGeometryChange(for: Double.self) { $0.size.width } action: { menuWidth = $0 }
            }
            .fixedSize()
            .hidden()
            .allowsHitTesting(false)
        }
    }

    enum FilterLayout { case named, namedCompact, symbols, menu, twoRows }

    /// The first layout whose pieces fit the bar's width (before it's measured: the first).
    var layout: FilterLayout {
        guard barWidth > 0 else { return .named }
        let camera = railShown ? ActivityRail.width : Self.narrowFilterWidth
        func fits(_ kinds: Double, _ search: Double) -> Bool { camera + 10 + kinds + 10 + search <= barWidth }
        if fits(namedWidth, 340) { return .named }
        if fits(namedWidth, 180) { return .namedCompact }
        if fits(symbolsWidth, 180) { return .symbols }
        if fits(menuWidth, 140) { return .menu }
        return .twoRows
    }

    @State private var barWidth = 0.0
    @State private var namedWidth = 0.0
    @State private var symbolsWidth = 0.0
    @State private var menuWidth = 0.0

    func row(@ViewBuilder kinds: () -> some View, @ViewBuilder search: () -> some View) -> some View {
        HStack(spacing: 10) {
            cameraFilter
            kinds()
            Spacer(minLength: 10)
            search()
        }
    }

    /// The search field's room for words, and how much its example needs.
    @State private var fieldWidth = 0.0
    static let exampleNeeds = 300.0

    /// The camera filter's width without the activity rail under it (a narrow window).
    static let narrowFilterWidth = 190.0

    var cameraFilter: some View {
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
            .frame(width: railShown ? ActivityRail.width : Self.narrowFilterWidth)
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
    }

    /// The new ones alone, or all: a chip, always there (shown only while there were new ones, it came and went as
    /// one came in on screen and was seen a moment later, and the bar jumped each time; now only its count rolls).
    /// On, it keeps those new as it was turned on (seen as they're looked at, they'd go one by one otherwise).
    @ViewBuilder
    func newChip(titled: Bool) -> some View {
        let on = model.eventsState.newOnly != nil
        let count = newCount
        Group {
            Button {
                withAnimation(.snappy(duration: 0.25)) { toggleNewOnly() }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(on || count > 0 ? Color.accentColor : .secondary).frame(width: 7, height: 7)
                    if titled { Text("New") }
                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(count)))
                }
                .font(.callout)
                .padding(.horizontal, titled ? 10 : 8)
                .padding(.vertical, 5)
                .opacity(on ? 1 : 0.7)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(on ? .regular.tint(Color.accentColor.opacity(0.25)).interactive() : .regular.interactive(), in: .capsule)
            .help(on ? "Show every event" : "Show only the events you haven\u{2019}t seen")
            // Every one seen, at once: beside the chip that counts them (always there, as it is; off with none new).
            Button {
                withAnimation(.snappy(duration: 0.25)) { model.seenEvents.sawAll() }
            } label: {
                if titled { Text("Mark All Seen") } else { Image(systemName: "checkmark.circle") }
            }
            .font(.callout)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(model.seenEvents.count == 0)
            .help("Count every event as seen")
            // The quieted (like those dismissed): there while there are some (or they're shown), to look them over.
            let quieted = model.eventsState.quietedOnly
            if quieted || quietedCount > 0 {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { model.eventsState.quietedOnly.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "moon.zzz").foregroundStyle(quieted ? Color.accentColor : .secondary)
                        if titled { Text("Quieted") }
                        Text("\(quietedCount)").monospacedDigit().foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(quietedCount)))
                    }
                    .font(.callout)
                    .padding(.horizontal, titled ? 10 : 8)
                    .padding(.vertical, 5)
                    .opacity(quieted ? 1 : 0.7)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(quieted ? .regular.tint(Color.accentColor.opacity(0.25)).interactive() : .regular.interactive(), in: .capsule)
                .help(quieted ? "Show the events not quieted" : "Show the events quieted as probably nothing (like those you dismissed)")
            }
        }
    }

    func toggleNewOnly() {
        model.eventsState.newOnly = model.eventsState.newOnly == nil ? newIDs : nil
    }

    func kindChips(titled: Bool) -> some View {
        HStack(spacing: titled ? 10 : 6) {
        newChip(titled: titled)
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
        }
        .fixedSize()
    }

    /// Every kind, on or off, in one menu: where there isn't room for their chips.
    var kindsMenu: some View {
        let on = kinds.filter { !model.eventsState.hidden.contains($0) }.count
        return Menu {
            Toggle(isOn: Binding(get: { model.eventsState.newOnly != nil }, set: { _ in
                withAnimation(.snappy(duration: 0.25)) { toggleNewOnly() }
            })) {
                Label("Only New", systemImage: "circle.fill")
            }
            Divider()
            ForEach(kinds) { kind in
                Toggle(isOn: Binding(get: { !model.eventsState.hidden.contains(kind) }, set: { show in
                    withAnimation(.snappy(duration: 0.25)) {
                        if show { model.eventsState.hidden.remove(kind) } else { model.eventsState.hidden.insert(kind) }
                    }
                })) {
                    Label("\(kind.title) (\(counts[kind] ?? 0))", systemImage: kind.symbol)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(on == kinds.count ? "All Kinds" : "\(on) of \(kinds.count) Kinds")
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Which kinds of event show")
    }

    /// A question in plain words: what, where, when, how it looked. Beside the filters, as wide as suits it; on a row
    /// of its own (`fill`), across it.
    func searchField(fill: Bool, compact: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            // An example of what can be asked where there's room for it; just "Search" where there isn't.
            TextField(fieldWidth >= Self.exampleNeeds ? "Search, like \u{201C}a man in a red jacket last night\u{201D}" : "Search",
                      text: $question)
                .textFieldStyle(.plain)
                .onSubmit(submit)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { fieldWidth = $0 }
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
        .frame(minWidth: compact ? 140 : 220, idealWidth: compact ? 180 : 340, maxWidth: fill ? .infinity : 380)
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

extension EnvironmentValues {
    /// Whether the Events view's panel covers the cards (a narrow window) or sits beside them.
    @Entry var panelCovers = false
}

/// The new cards on screen a moment, the window in front: seen. Reads what's on screen itself (as the rail does), so
/// the grid scrolling makes this again, not the Events view; and from the cards on screen (a few), not every event.
struct SeenOnScreen: View {
    let onScreen: GridOnScreen
    let unseen: Set<String>
    let shown: [TimelineEvent]
    let position: [String: Int]
    let looking: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let new = onScreen.cards.intersection(unseen)
        Color.clear
            .task(id: EventsView.Looking(cards: new, front: looking)) {
                guard !new.isEmpty, looking else { return }
                try? await Task.sleep(for: .seconds(EventsView.seenAfter))
                guard !Task.isCancelled else { return }
                model.seenEvents.saw(new.compactMap { position[$0].map { shown[$0] } })
            }
    }
}
