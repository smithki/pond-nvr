// The Events view's grid of cards, laid out by Pond, not a lazy grid: every card is the same size, so where each one
// goes is arithmetic (columns, a card's width and height, a header a day). Knowing every place exactly, before a
// change and after, the details panel opening or closing isn't a scroll at all: the scroll is put at once where the
// chosen card's row will be in the middle, and every card is drawn moving from where it was on screen to where it
// goes, one animation (the scroll view's own animated scrolling, alongside SwiftUI's, never kept in step). The cards
// a page and a half either side of the screen are made, and through a move every card on screen before it or after,
// so nothing on screen is let go and made again (which flickers). The day headers are pinned by it too, and what's
// on screen is known exactly (for the rail).
import AppKit
import SwiftUI

/// Where every card and header goes, for days of events at a width.
struct EventGridLayout {
    struct Section: Equatable {
        let day: Date
        let ids: [String]
    }

    nonisolated static let spacing = 14.0, headerHeight = 58.0, sectionGap = 8.0, pad = 8.0, textHeight = 56.0

    let width: Double
    let columns: Int
    let card: CGSize
    let headers: [(day: Date, y: Double, count: Int)]
    /// Every card's frame, by id, and in order (top to bottom, row by row).
    let cards: [String: CGRect]
    let order: [(id: String, frame: CGRect)]
    let height: Double

    init(sections: [Section], width: Double, columns: Int) {
        let n = max(1, columns)
        let cw = max(120, (width - Self.spacing * Double(n - 1)) / Double(n))
        // A card: its picture (16:9, the card less its padding), its words below.
        let ch = Self.pad + (cw - 2 * Self.pad) * 9 / 16 + Self.pad + Self.textHeight + Self.pad
        var headers: [(day: Date, y: Double, count: Int)] = []
        var cards: [String: CGRect] = [:]
        var order: [(id: String, frame: CGRect)] = []
        var y = 0.0
        for section in sections {
            headers.append((section.day, y, section.ids.count))
            y += Self.headerHeight
            for (i, id) in section.ids.enumerated() {
                let frame = CGRect(x: Double(i % n) * (cw + Self.spacing), y: y + Double(i / n) * (ch + Self.spacing), width: cw, height: ch)
                cards[id] = frame
                order.append((id, frame))
            }
            let rows = (section.ids.count + n - 1) / n
            y += Double(rows) * (ch + Self.spacing) - Self.spacing + Self.sectionGap
        }
        self.width = width
        self.columns = n
        card = CGSize(width: cw, height: ch)
        self.headers = headers
        self.cards = cards
        self.order = order
        height = max(0, y)
    }

    /// The cards overlapping `range` (of the content's height), in order.
    func cards(in range: ClosedRange<Double>) -> ArraySlice<(id: String, frame: CGRect)> {
        // The first whose bottom reaches the range (rows only go down), then on while they start within it.
        var low = 0, high = order.count
        while low < high {
            let mid = (low + high) / 2
            if order[mid].frame.maxY < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < order.count, order[end].frame.minY <= range.upperBound { end += 1 }
        return order[low ..< end]
    }

    /// The offset that puts a card's row in the middle of a view `height` tall (as near as the ends allow).
    func centring(_ id: String, view height: Double) -> Double? {
        guard let frame = cards[id] else { return nil }
        return clamp(frame.midY - height / 2, view: height)
    }

    /// An offset kept within the content.
    func clamp(_ offset: Double, view height: Double) -> Double {
        min(max(0, offset), max(0, self.height - height))
    }
}

/// The panel opening or closing, under way: where each card was drawn as it began (on screen, from the layout
/// before it and the scroll then, or, begun part way through another, where that one had them).
struct GridFlip {
    let before: EventGridLayout
    let beforeOffset: Double
    var cards: [String: CGPoint] = [:]
    var headers: [Date: Double] = [:]
    /// The scroll it put the grid at.
    let offset: Double
    /// The phase it runs from (to the grid's), and when.
    let start: Double
    let began: Date

    /// Where a card was on screen as it began.
    func card(_ id: String) -> CGPoint? {
        cards[id] ?? before.cards[id].map { CGPoint(x: $0.minX, y: $0.minY - beforeOffset) }
    }

    func header(_ day: Date) -> Double? {
        headers[day] ?? before.headers.first { $0.day == day }.map { $0.y - beforeOffset }
    }
}

/// Draws a card (or header) part way from where it was to where it goes, by the grid's phase: a transform, not a
/// layout, so a move costs a frame nothing but this.
struct FlipPlacement: GeometryEffect {
    var phase: Double
    /// Where the phase is going (the move's end), and where it began.
    let target: Double
    let start: Double
    let from: CGPoint
    let to: CGPoint

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = target > start ? min(max((phase - start) / (target - start), 0), 1) : 1
        return ProjectionTransform(CGAffineTransform(translationX: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p))
    }
}

/// The chosen card's outline, part way from where the card was to where it goes (and from its size to its new
/// one), by the grid's phase, as the card itself is drawn.
struct SelectionRing: Shape {
    var phase: Double
    let target: Double
    let start: Double
    let from: CGRect
    let to: CGRect

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = target > start ? min(max((phase - start) / (target - start), 0), 1) : 1
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        let r = CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY), width: mix(from.width, to.width), height: mix(from.height, to.height))
        return RoundedRectangle(cornerRadius: 14, style: .continuous).path(in: r)
    }
}

/// A move of the grid asked for from outside: a card's row to the middle (if it isn't wholly in view, unless
/// `always`), or the top.
struct GridScroll: Equatable {
    enum Kind: Equatable {
        case centre(String, always: Bool)
        case top
        /// The events changing wholesale (a search answered, or let go): `change` made while the grid's faded out,
        /// and shown at the top (or, not `top`, with the card that was at the top still there, if it is).
        case swap(top: Bool)
    }

    var kind: Kind
    var animated = true
    /// A swap's change.
    var change: (@MainActor () -> Void)?
    var id = UUID()

    static func == (a: GridScroll, b: GridScroll) -> Bool { a.id == b.id }
}

struct EventGrid: View {
    let sections: [EventGridLayout.Section]
    let events: [String: TimelineEvent]
    /// The grid's width now, and how much narrower the panel makes it.
    let width: Double
    let columns: Int
    let panelOpen: Bool
    /// How far down the filters' bar over the grid's top reaches, and how tall the strip at its bottom is (under the
    /// window's edge's glass): the grid scrolls on under both, its cards in view only between them.
    var topInset = 0.0
    var bottomInset = 0.0
    let panelWidth: Double
    /// The card the panel's opening or closing centres (the chosen one, or the one that was).
    let focus: String?
    let selected: String?
    let fresh: Set<String>
    @Binding var request: GridScroll?
    let name: (String) -> String
    /// A section's title, by its day (a day's own; or, for a search's best matches, theirs).
    var title: (Date) -> String = { EventsView.dayTitle($0) }
    let choose: (TimelineEvent) -> Void
    let open: (TimelineEvent) -> Void
    let delete: (TimelineEvent) -> Void
    /// The cards on screen, told as they change.
    let onVisible: (Set<String>) -> Void
    /// Whether it's at the top (new events slide in there; scrolled down, they're added without moving the view).
    let onTop: (Bool) -> Void
    /// Whether anything's scrolled under the bar above it, and whether any card or day is in the strip at its
    /// bottom.
    var onScrolled: (Bool) -> Void = { _ in }
    var onUnderBottom: (Bool) -> Void = { _ in }

    /// The animation the panel opens and closes with, the cards moving with it (the spring's own, too, to tell where
    /// they are part way).
    static let panelSpring = Spring(duration: 0.4, bounce: 0)
    static let panelAnimation = Animation.spring(panelSpring)
    /// The springy scroll a card's row is brought to the middle with.
    static let bring = Animation.spring(duration: 0.5, bounce: 0.2)
    /// Further than this many screens, a card's brought there by a jump (the grid fading out and in) rather than a
    /// scroll: scrolling through days of cards made and read every one on the way (each new card's picture read and
    /// decoded as it came), which stuttered, and the rail's outline restarted with every day that passed.
    static let farJump = 2.0
    /// A far jump lands this far short of where it's going (on the side it came from) and scrolls the rest as it
    /// fades in, so it's seen to arrive from that way.
    static let jumpLead = 180.0
    /// That last of the way: slow, easing to a stop (a hint of where it came from, not a scroll to follow).
    static let jumpArrives = Animation.timingCurve(0.25, 0.6, 0.3, 1, duration: 0.9)
    /// Scrolled faster than this many screens a second (the scroller dragged, or a long fling), for a few moments
    /// running, the cards are plain blocks, dimmed, and the day and hour they're at is shown over them; slower than
    /// the second, the cards are shown again (their pictures read first).
    static let scrubStarts = 8.0
    static let scrubEnds = 2.5

    @State private var position = ScrollPosition(edge: .top)
    /// What the scroll view says of itself, as it says it; everything the grid works out from it goes through
    /// `metrics` (with the grid's own room for the bars), so there's one account of where things are.
    @State private var reading = GridScrollReading()
    var metrics: GridMetrics { GridMetrics(reading: reading, topRoom: topInset, bottomRoom: bottomInset) }
    /// How far down the cards are scrolled (from their top, as the layout counts), and the height between the bars,
    /// where cards are in view.
    var offset: Double { metrics.offset }
    var viewHeight: Double { metrics.visibleHeight }
    /// Cards also made through a move (those on screen before it and after), so none is let go mid-move.
    @State private var keep: Set<String> = []
    /// The panel's move under way, and the phase moves run by (up one a move, animated).
    @State private var flip: GridFlip?
    @State private var phase = 0.0
    /// Whether the panel was open, as the grid was last laid out (it differs the moment it opens or closes).
    @State private var laidOutOpen: Bool?
    /// Scroll bars always shown (a mouse, or the setting): the scroller takes room beside the cards.
    @State private var scrollerTakesRoom = NSScroller.preferredScrollerStyle == .legacy
    @State private var told: Set<String> = []
    @State private var toldTop = true
    @State private var toldScrolled = false
    @State private var toldUnder = false
    @State private var cache = LayoutCache()
    /// A far jump under way (its id; a newer one takes over), the grid faded out while it goes, and whether it's been
    /// waiting long enough for its pictures to say so.
    @State private var jump: UUID?
    @State private var veiled = false
    @State private var loading = false
    /// A swap's change made, waiting on the events it changed to land.
    @State private var swapping: Swapping?
    /// Scrolling fast: the cards dimmed, the day and hour over them.
    @State private var scrubbing = false
    @State private var speed = Speedometer()

    var layout: EventGridLayout { cache.layout(sections: sections, width: width - gutter, columns: columns) }

    var body: some View {
        let layout = layout
        let margin = self.margin
        let made = layout.cards(in: (offset - margin) ... (offset + viewHeight + margin))
        let madeIDs = Set(made.map(\.id))
        let extra = also(margin).subtracting(madeIDs).compactMap { id in layout.cards[id].map { (id: id, frame: $0) } }
        let pinned = layout.headers.lastIndex { $0.y <= offset + 0.5 }
        ScrollView {
            ZStack(alignment: .topLeading) {
                ForEach(layout.headers.indices.filter { i in
                    let y = layout.headers[i].y
                    return y + EventGridLayout.headerHeight >= offset - margin && y <= offset + viewHeight + margin
                }, id: \.self) { i in
                    let h = layout.headers[i]
                    header(h.day, count: h.count, pinned: false)
                        .frame(width: layout.width, height: EventGridLayout.headerHeight, alignment: .bottomLeading)
                        // The pinned one is drawn over the grid instead (below).
                        .opacity(i == pinned && offset > h.y + 0.5 ? 0 : 1)
                        .modifier(headerPlacement(h))
                }
                ForEach(Array(made) + extra, id: \.id) { item in
                    if let event = events[item.id] {
                        Group {
                            if scrubbing {
                                // Scrolling fast: a plain block where the card goes (each card made on the way,
                                // with its picture, words and all, stuttered), the cards again once it slows.
                                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.5))
                            } else {
                                EventCard(event: event, camera: name(event.camera), selected: selected == item.id,
                                          fresh: fresh.contains(item.id),
                                          choose: { choose(event) }, open: { open(event) }, delete: { delete(event) })
                                    // (Drawn again only when it changes: its actions, new each time, otherwise made
                                    // every card's body run again with every frame the grid scrolled.)
                                    .equatable()
                            }
                        }
                            .frame(width: item.frame.width, height: item.frame.height)
                            .modifier(cardPlacement(item))
                            // New ones grow in; any other made (scrolled near, or through a move) is simply there. Gone,
                            // they shrink away (deleted, filtered out; those let go far off screen, unseen). Either about
                            // the card's middle, where it's drawn (its frame's at the corner, the card moved from there).
                            .transition(.asymmetric(insertion: fresh.contains(item.id) ? Self.appear(item.frame) : .identity,
                                                    removal: Self.appear(item.frame)))
                    }
                }
            }
            // The chosen card's outline, over it: drawn by the grid, moving and resizing with the card as one (the
            // card's own outline went to its new size before the card did).
            // Closing, it stays on the card that was chosen through the move, fading as the panel goes.
            .overlay(alignment: .topLeading) {
                if let ringed = selected ?? focus, let frame = layout.cards[ringed] {
                    SelectionRing(phase: phase, target: phase, start: flip?.start ?? phase,
                                  from: flip.flatMap { f in
                                      f.card(ringed).map { CGRect(x: $0.x, y: $0.y + f.offset, width: f.before.card.width, height: f.before.card.height) }
                                  } ?? frame,
                                  to: frame)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .opacity(selected == nil ? 0 : 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: layout.width, height: layout.height, alignment: .topLeading)
            // Scrolling fast: nothing hovered, nor its help shown, as the cards fly under the pointer.
            .allowsHitTesting(!scrubbing)
            // Faded out while a far jump goes, and in again where it lands; dimmed scrolling fast (the days' headers
            // too, under the day and hour shown).
            .opacity(veiled ? 0 : scrubbing ? 0.5 : 1)
            // Room for the filters' bar above and a strip below (both drawn over the grid by the Events view, over
            // glass): the cards scroll on under them. (Padding, not bars of the scroll view's: under a bar of its
            // own, the system lays a band of its own when the pointer's over it, the grid's width only.)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .padding(.trailing, gutter > 0 ? Self.scrollerGap : 0)
        }
        .contentMargins(.top, topInset, for: .scrollIndicators)
        .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
        // (The system's own edge effect blurs too little to see, and not at all under the filters: off, so it doesn't
        // add to the glass the Events view lays over both edges, the window's width. Still needed? Capture the
        // edges with scripts/capture-window.swift with it on and off, and compare.)
        .scrollEdgeEffectHidden(true, for: [.top, .bottom])
        // (Its scroller, if it takes room, a gap short of the panel.)
        .padding(.trailing, gutter > 0 ? Self.scrollerGap : 0)
        .scrollPosition($position)
        // Waiting on a far jump's pictures, past a moment: said, in the middle of the room between the bars.
        .overlay {
            if loading {
                ProgressView().controlSize(.small)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)
                    .transition(.opacity)
            }
        }
        // Scrolling fast: where it's got to, in the middle.
        .overlay {
            if scrubbing, let event = middle(layout) {
                ScrubLabel(day: title(Calendar.current.startOfDay(for: event.start)), hour: event.start)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .allowsHitTesting(false)
            }
        }
        .onScrollGeometryChange(for: GridScrollReading.self) { g in
            GridScrollReading(contentOffset: g.contentOffset.y, insetTop: g.contentInsets.top, containerHeight: g.containerSize.height)
        } action: { _, now in
            let first = viewHeight == 0
            reading = now
            track()
            let measured = viewHeight > 0
            if laidOutOpen == nil { laidOutOpen = panelOpen }
            tell()
            // A move asked before it knew its height (coming back with an event open): now.
            if first, measured, let request {
                self.request = nil
                perform(request)
            }
        }
        // The day at the top, pinned over the grid, pushed up by the next as it arrives.
        .overlay(alignment: .topLeading) {
            if let pinned, offset > layout.headers[pinned].y + 0.5 {
                let next = pinned + 1 < layout.headers.count ? layout.headers[pinned + 1].y : .infinity
                header(layout.headers[pinned].day, count: layout.headers[pinned].count, pinned: true)
                    .frame(height: EventGridLayout.headerHeight, alignment: .bottomLeading)
                    .offset(y: metrics.pinnedHeaderY(nextHeaderAt: next, headerHeight: EventGridLayout.headerHeight))
            }
        }
        .clipped()
        .onChange(of: panelOpen) { _, open in panelChanged(open: open) }
        .onChange(of: request) { _, request in
            guard let request else { return }
            self.request = nil
            perform(request)
        }
        .onChange(of: sections) { old, _ in
            eventsChanged(from: old)
            // (What's on screen, and in the strips, may be other cards now, though nothing scrolled.)
            tell()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerTakesRoom = NSScroller.preferredScrollerStyle == .legacy
        }
    }

    func header(_ day: Date, count: Int, pinned: Bool) -> some View {
        HStack(spacing: 8) {
            // Frosted glass, so it reads over the pictures scrolling under it; lifted off them by a shadow.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title(day)).font(.title3.weight(.bold))
                Text(count == 1 ? "1 event" : "\(count) events")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
            // Scrolled down from the newest: the way back, beside the pinned day.
            if pinned, offset > 120 {
                Button {
                    request = GridScroll(kind: .top)
                } label: {
                    Label("Now", systemImage: "arrow.up")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                .help("Back to the newest events")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: offset > 120)
        .padding(.bottom, 8)
    }

    // MARK: Moves

    /// The cards on screen (below the pinned header), told when they change; and whether it's at the top.
    func tell() {
        // (Not before it has a height worth the name: the range below would run backwards.)
        guard viewHeight > EventGridLayout.headerHeight else { return }
        let cards = Set(layout.cards(in: (offset + EventGridLayout.headerHeight) ... (offset + viewHeight)).map(\.id))
        if cards != told {
            told = cards
            onVisible(cards)
            // The pictures of the cards a few pages either way, read ahead.
            EventPictures.prefetch(layout.cards(in: (offset - 3 * viewHeight) ... (offset + 4 * viewHeight))
                .compactMap { events[$0.id]?.snapshot })
        }
        let top = offset < 40
        if top != toldTop {
            toldTop = top
            onTop(top)
        }
        let scrolled = offset > 1
        if scrolled != toldScrolled {
            toldScrolled = scrolled
            onScrolled(scrolled)
        }
        let strip = metrics.bottomStrip
        let under = !layout.cards(in: strip).isEmpty
            || layout.headers.contains { $0.y + EventGridLayout.headerHeight >= strip.lowerBound && $0.y <= strip.upperBound }
        if under != toldUnder {
            toldUnder = under
            onUnderBottom(under)
        }


    }

    /// Whether a card is wholly in view, below the pinned header.
    func wholly(_ id: String) -> Bool {
        guard let frame = layout.cards[id] else { return false }
        return frame.minY >= offset + EventGridLayout.headerHeight - 4 && frame.maxY <= offset + viewHeight + 1
    }

    /// A card coming or going: scaled about its middle as drawn, fading.
    static func appear(_ frame: CGRect) -> AnyTransition {
        .scale(scale: 0.85, anchor: UnitPoint(x: (frame.minX + frame.width / 2) / max(frame.width, 1),
                                               y: (frame.minY + frame.height / 2) / max(frame.height, 1)))
            .combined(with: .opacity)
    }

    /// Cards made besides those near the screen: those kept through a move, and, the moment the panel's opened or
    /// closed (its move not begun), those on screen before.
    func also(_ margin: Double) -> Set<String> {
        guard let laidOutOpen, laidOutOpen != panelOpen else { return keep }
        let before = laidOut(sections, width: width + (panelOpen ? panelWidth : -panelWidth))
        return keep.union(before.cards(in: (offset - margin) ... (offset + viewHeight + margin)).map(\.id))
    }

    /// The cards made: those within this of the screen, either way. Fewer through a move: every card made moves,
    /// and reshapes (its words wrapped again) each frame of it, seen or not; half a screen's room is enough for
    /// those coming on from just off it.
    var margin: Double { flip != nil ? moveMargin : max(600, viewHeight * 1.5) }
    var moveMargin: Double { max(300, viewHeight * 0.5) }

    /// The panel opened or closed (the width's already the new one): the focused card's row goes to the middle (or,
    /// with none, the top card stays put), the cards reshaping as they move. A focused card far from what's on screen
    /// (scrolled away from while the panel was open) is gone to with it: the cards on screen reshape where they are as
    /// the grid fades out, and it fades in there (a far jump, as from the rail), the panel moving all the while. Moved there with the panel,
    /// every card on screen flew thousands of points, and those around it were made and read on the way.
    func panelChanged(open: Bool) {
        laidOutOpen = open
        guard viewHeight > 0 else { return }
        let before = laidOut(sections, width: width + (open ? panelWidth : -panelWidth))
        guard let focus, let centred = layout.centring(focus, view: viewHeight) else {
            return move(from: before, to: anchored(from: before))
        }
        let here = anchored(from: before)
        if abs(centred - here) > Self.farJump * max(viewHeight, 1) {
            // Both at once: the cards on screen reshaping as the panel goes, while they fade out; then, unseen,
            // there (the move let go), faded in as the panel finishes.
            move(from: before, to: here)
            jump(to: centred)
        } else {
            move(from: before, to: centred)
        }
    }

    /// Events came or went: they make room, or close up, as they move. Scrolled down, what's on screen stays where
    /// it is (the scroll moving by as much as the cards above it did); at the top, new ones come in there.
    func eventsChanged(from old: [EventGridLayout.Section]) {
        guard viewHeight > EventGridLayout.headerHeight else { return }
        let before = laidOut(old, width: width)
        // Changed under a swap's veil: there at once, the pictures there read before it's shown.
        if let swap = swapping {
            swapping = nil
            let target = swap.top ? 0 : anchored(from: before)
            land(at: target)
            return swap.landed(pictures(around: target))
        }
        move(from: before, to: offset > 40 ? anchored(from: before) : layout.clamp(offset, view: viewHeight))
    }

    /// The scroll that keeps the top card on screen (one that's still there) where it is, laid out as now.
    func anchored(from before: EventGridLayout) -> Double {
        let on = before.cards(in: (offset + EventGridLayout.headerHeight) ... (offset + max(viewHeight, EventGridLayout.headerHeight)))
        guard let first = on.first(where: { layout.cards[$0.id] != nil }), let now = layout.cards[first.id] else {
            return layout.clamp(offset, view: viewHeight)
        }
        return layout.clamp(offset + (now.minY - first.frame.minY), view: viewHeight)
    }

    /// From one layout to this one: the scroll put at once at `target`, and every card (and header) drawn moving
    /// from where it was on screen to where it now goes, one animation (the panel's). Begun part way through
    /// another, it moves them on from where that one had them.
    func move(from before: EventGridLayout, to target: Double, then after: (@MainActor () -> Void)? = nil) {
        let near = moveMargin
        let drawn = before.cards(in: (offset - near) ... (offset + viewHeight + near))
        let now = Date()
        var cards: [String: CGPoint] = [:], headers: [Date: Double] = [:]
        var start = phase
        if let flip {
            // Where the one under way has them now (its spring, so far): this one starts there.
            let p = Self.panelSpring.value(target: 1.0, time: now.timeIntervalSince(flip.began))
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
            for item in drawn {
                guard let was = flip.card(item.id) else { continue }
                cards[item.id] = CGPoint(x: mix(was.x, item.frame.minX), y: mix(was.y, item.frame.minY - offset))
            }
            for h in before.headers {
                guard let was = flip.header(h.day) else { continue }
                headers[h.day] = mix(was, h.y - offset)
            }
            start = mix(flip.start, phase)
        }
        keep = Set(drawn.map(\.id)).union(layout.cards(in: (target - near) ... (target + viewHeight + near)).map(\.id))
        // At once (no animation): the scroll, and where each card starts from.
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) {
            flip = GridFlip(before: before, beforeOffset: offset, cards: cards, headers: headers, offset: target, start: start, began: now)
            if abs(target - offset) > 0.5 { scroll(to: target) }
            reading.contentOffset = metrics.contentOffset(showing: target)
        }
        withAnimation(Self.panelAnimation) {
            phase += 1
        } completion: {
            guard flip?.began == now else { return }
            flip = nil
            keep = []
            after?()
        }
    }

    /// Where a card's drawn: part way from where it was to where it goes, mid-move; where it goes, else.
    func cardPlacement(_ item: (id: String, frame: CGRect)) -> FlipPlacement {
        FlipPlacement(phase: phase, target: phase, start: flip?.start ?? phase,
                      from: flip.flatMap { f in f.card(item.id).map { CGPoint(x: $0.x, y: $0.y + f.offset) } } ?? item.frame.origin,
                      to: item.frame.origin)
    }

    func headerPlacement(_ h: (day: Date, y: Double, count: Int)) -> FlipPlacement {
        FlipPlacement(phase: phase, target: phase, start: flip?.start ?? phase,
                      from: CGPoint(x: 0, y: flip.flatMap { f in f.header(h.day).map { $0 + f.offset } } ?? h.y),
                      to: CGPoint(x: 0, y: h.y))
    }

    /// Scrolled so the cards' `y` is at the top of the room between the bars.
    func scroll(to y: Double) {
        speed.steered()
        position.scrollTo(y: metrics.contentOffset(showing: y))
    }

    /// There at once, no move under way, and the grid told so now (the scroll view says where it is only when that
    /// changes, and the cards made are those near where the grid thinks it is: left to it, a scroll that changed
    /// nothing it measures left the grid making cards somewhere else, none on screen until it was scrolled).
    func land(at target: Double) {
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) {
            flip = nil
            keep = []
            scroll(to: target)
            reading.contentOffset = metrics.contentOffset(showing: target)
        }
    }

    /// The pictures of the cards about a screen either side of `y`.
    func pictures(around y: Double) -> [URL] {
        layout.cards(in: (y - viewHeight) ... (y + 2 * viewHeight)).compactMap { events[$0.id]?.snapshot }
    }

    func perform(_ request: GridScroll) {
        // (A far jump under way gives way to this: shown again at once.)
        if jump != nil {
            jump = nil
            swapping = nil
            veiled = false
            loading = false
        }
        switch request.kind {
        case .top:
            if request.animated {
                speed.steered()
                withAnimation(Self.bring) { position.scrollTo(edge: .top) }
            } else {
                land(at: 0)
            }
        case let .swap(top):
            swap(request.change ?? {}, top: top)
        case let .centre(id, always):
            guard always || !wholly(id), let target = layout.centring(id, view: viewHeight) else { return }
            if request.animated, abs(target - offset) > Self.farJump * max(viewHeight, 1) {
                jump(to: target)
            } else if request.animated {
                withAnimation(Self.bring) { scroll(to: target) }
            } else {
                scroll(to: target)
            }
        }
    }

    /// Far away: the grid fades out while the pictures where it's going are read (in the background), is there at
    /// once (a little short of it), and fades in again when they're ready, scrolling the last of the way. The rail
    /// follows where the grid is.
    func jump(to target: Double) {
        let from = layout.clamp(target + (target > offset ? -Self.jumpLead : Self.jumpLead), view: viewHeight)
        veil(reading: pictures(around: target)) { current, landed in
            guard current else { return }
            land(at: from)
            landed([])
        } shown: {
            withAnimation(Self.jumpArrives) { scroll(to: target) }
        }
    }

    /// The events changing wholesale (a search's answer): faded out, changed, shown at once where they go (see
    /// `eventsChanged`), faded in. Rather than every card flying from where it was to where it is in the answer.
    func swap(_ change: @escaping @MainActor () -> Void, top: Bool) {
        veil { current, landed in
            // (Made even if another's taken over: the change is the events', not only the grid's.)
            guard current else { return change() }
            let swap = Swapping(top: top, landed: landed)
            swapping = swap
            change()
            // Nothing the grid shows changed (the same cards): shown again where it is.
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                if swapping === swap {
                    swapping = nil
                    landed([])
                }
            }
        }
    }

    /// Faded out; `land` then, unseen (told whether this is still the latest, and given what to call once it's
    /// landed, with the pictures it lands on, to be read); faded in once it's landed and those, and `reading`, are
    /// read, or after half a second whatever (the rest coming as they're read; past a fifth, a spinner says so);
    /// `shown` as it fades in.
    func veil(reading early: [URL] = [],
              land: @escaping @MainActor (_ current: Bool, _ landed: @escaping @MainActor ([URL]) -> Void) -> Void,
              shown: (@MainActor () -> Void)? = nil) {
        let id = UUID()
        jump = id
        final class Progress: @unchecked Sendable { var landed = false, reads = 0, shown = false }
        let progress = Progress()
        func showIfReady(waitedEnough: Bool = false) {
            guard jump == id, progress.landed, progress.reads == 0 || waitedEnough, !progress.shown else { return }
            progress.shown = true
            withAnimation(.easeOut(duration: 0.2)) {
                veiled = false
                loading = false
            }
            jump = nil
            shown?()
        }
        func read(_ urls: [URL]) {
            guard !urls.isEmpty else { return }
            progress.reads += 1
            EventPictures.prefetch(urls) {
                progress.reads -= 1
                showIfReady()
            }
        }
        read(early)
        withAnimation(.easeIn(duration: 0.12)) { veiled = true } completion: {
            land(jump == id) { urls in
                read(urls)
                progress.landed = true
                showIfReady()
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    if jump == id, !progress.shown { withAnimation(.easeOut(duration: 0.15)) { loading = true } }
                    try? await Task.sleep(for: .milliseconds(300))
                    showIfReady(waitedEnough: true)
                }
            }
        }
    }

    /// The scroll's speed, as it goes: fast enough for long enough, the cards dim (`scrubbing`); slower again, or
    /// still a moment, the pictures where it's stopped are read and they're shown again. The grid's own scrolls
    /// (a move, a jump, a card brought to the middle) don't count.
    func track() {
        let now = CACurrentMediaTime(), y = offset, s = speed
        defer { s.last = (y, now) }
        guard let last = s.last, now > last.time, now > s.steeredUntil, jump == nil, flip == nil, viewHeight > 0 else {
            s.speed = 0
            s.fast = 0
            return
        }
        let screens = abs(y - last.offset) / (now - last.time) / viewHeight
        s.speed = s.speed * 0.5 + screens * 0.5
        s.fast = s.speed > Self.scrubStarts ? s.fast + 1 : 0
        if !scrubbing {
            guard s.fast >= 4 else { return }
            withAnimation(.easeOut(duration: 0.15)) { scrubbing = true }
        }
        if s.speed >= Self.scrubEnds {
            s.settling = nil
            // Still a moment (the scroller held where it is): as slowed.
            s.beat += 1
            let beat = s.beat
            Task {
                try? await Task.sleep(for: .milliseconds(160))
                if speed.beat == beat { settle() }
            }
        } else {
            settle()
        }
    }

    func settle() {
        guard scrubbing, speed.settling == nil else { return }
        let token = UUID()
        speed.settling = token
        func show() {
            guard speed.settling == token, scrubbing else { return }
            speed.settling = nil
            withAnimation(.easeOut(duration: 0.2)) { scrubbing = false }
        }
        EventPictures.prefetch(pictures(around: offset)) { show() }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            show()
        }
    }

    /// The event at the middle of the screen (the nearest card to it).
    func middle(_ layout: EventGridLayout) -> TimelineEvent? {
        let mid = offset + viewHeight / 2
        let near = layout.cards(in: (mid - viewHeight / 2) ... (mid + viewHeight / 2))
        return near.min { abs($0.frame.midY - mid) < abs($1.frame.midY - mid) }.flatMap { events[$0.id] }
    }

    /// Laid out at a width the grid's been given (less the scroller's gutter, if it takes room).
    func laidOut(_ sections: [EventGridLayout.Section], width: Double) -> EventGridLayout {
        EventGridLayout(sections: sections, width: width - gutter, columns: columns)
    }

    /// Room for a scroller that takes it (scroll bars always shown), and a little either side of it, so the cards
    /// don't run under it nor it against the panel.
    var gutter: Double { scrollerTakesRoom ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 2 * Self.scrollerGap : 0 }
    static let scrollerGap = 6.0
}

/// What the grid's scroll view says of itself: its offset, the inset at its top, its height.
/// A swap's change made: where to show it, and what to call once it's there.
@MainActor final class Swapping {
    let top: Bool
    let landed: @MainActor ([URL]) -> Void
    init(top: Bool, landed: @escaping @MainActor ([URL]) -> Void) {
        self.top = top
        self.landed = landed
    }
}

/// How fast the grid's being scrolled (kept out of the view's state: it changes every frame, and nothing's drawn
/// from it).
@MainActor final class Speedometer {
    var last: (offset: Double, time: Double)?
    /// Screens a second, smoothed; and how many readings running it's been fast.
    var speed = 0.0
    var fast = 0
    /// The grid scrolling itself until then.
    var steeredUntil = 0.0
    /// Moved since (a newer one, the last); the pictures being read where it slowed.
    var beat = 0
    var settling: UUID?

    func steered() { steeredUntil = CACurrentMediaTime() + 0.7 }
}

/// Scrolling fast: the day and hour the grid's at, over it.
struct ScrubLabel: View {
    let day: String
    let hour: Date

    var body: some View {
        VStack(spacing: 2) {
            Text(day).font(.title2.weight(.semibold))
            Text(hour.formatted(.dateTime.hour())).font(.title3).foregroundStyle(.secondary).monospacedDigit()
        }
        .lineLimit(1)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct GridScrollReading: Equatable {
    var contentOffset = 0.0
    var insetTop = 0.0
    var containerHeight = 0.0
}

/// Where things are in the grid: from what its scroll view says, and the grid's own room at its top (for the
/// filters' bar, drawn over it) and bottom (the strip under the glass at the window's edge). The one account of it:
/// the scroll offsets, the height in view, where the pinned day goes.
///
/// As macOS 26 has it (measured; not documented): the scroll view's inset at its top counts the window's toolbar,
/// though the grid's frame is below the toolbar, and nothing of the grid's own room (that's padding in its
/// content). Its offset counts from under that inset: at the top, it's minus the inset. So the inset's what the
/// offset's measured from, but not what the height in view is less: that's the grid's own room. The tests hold
/// these figures; if a macOS changes them, they say so.
struct GridMetrics: Equatable {
    var reading: GridScrollReading
    /// The grid's room above its cards and below them.
    var topRoom: Double
    var bottomRoom: Double

    /// How far down the cards are scrolled, from their top (as the layout counts).
    var offset: Double { reading.contentOffset + reading.insetTop }
    /// The height between the room above and below, where cards are in view.
    var visibleHeight: Double { max(0, reading.containerHeight - topRoom - bottomRoom) }

    /// The scroll view's offset that has the cards' `y` at the top of the height in view.
    func contentOffset(showing y: Double) -> Double { y - reading.insetTop }

    /// Where the pinned day's header goes in the grid's frame: just under the room above, pushed up by the next
    /// day's as it arrives (`next`, its place in the layout).
    func pinnedHeaderY(nextHeaderAt next: Double, headerHeight: Double) -> Double {
        topRoom + min(0, next - offset - headerHeight)
    }

    /// The layout's stretch under the room below (the glass at the window's edge).
    var bottomStrip: ClosedRange<Double> { (offset + visibleHeight) ... (offset + visibleHeight + bottomRoom) }
}

/// The last layout, kept while its inputs are the same (the grid's body runs each frame of a scroll).
final class LayoutCache {
    private var key: (sections: [EventGridLayout.Section], width: Double, columns: Int)?
    private var last: EventGridLayout?

    func layout(sections: [EventGridLayout.Section], width: Double, columns: Int) -> EventGridLayout {
        if let key, let last, key.width == width, key.columns == columns, key.sections == sections { return last }
        let made = EventGridLayout(sections: sections, width: width, columns: columns)
        key = (sections, width, columns)
        last = made
        return made
    }
}
