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

/// A move of the grid asked for from outside: a card's row to the middle (if it isn't wholly in view, unless
/// `always`), or the top.
struct GridScroll: Equatable {
    enum Kind: Equatable {
        case centre(String, always: Bool)
        case top
    }

    var kind: Kind
    var animated = true
    var id = UUID()
}

struct EventGrid: View {
    let sections: [EventGridLayout.Section]
    let events: [String: TimelineEvent]
    /// The grid's width now, and how much narrower the panel makes it.
    let width: Double
    let columns: Int
    let panelOpen: Bool
    let panelWidth: Double
    /// The card the panel's opening or closing centres (the chosen one, or the one that was).
    let focus: String?
    let selected: String?
    let fresh: Set<String>
    @Binding var request: GridScroll?
    let name: (String) -> String
    let choose: (TimelineEvent) -> Void
    let open: (TimelineEvent) -> Void
    /// The cards on screen, told as they change.
    let onVisible: (Set<String>) -> Void
    /// Whether it's at the top (new events slide in there; scrolled down, they're added without moving the view).
    let onTop: (Bool) -> Void

    /// The animation the panel opens and closes with, the cards moving with it (the spring's own, too, to tell where
    /// they are part way).
    static let panelSpring = Spring(duration: 0.4, bounce: 0)
    static let panelAnimation = Animation.spring(panelSpring)
    /// The springy scroll a card's row is brought to the middle with.
    static let bring = Animation.spring(duration: 0.5, bounce: 0.2)

    @State private var position = ScrollPosition(edge: .top)
    @State private var offset = 0.0
    @State private var viewHeight = 0.0
    /// Cards also made through a move (those on screen before it and after), so none is let go mid-move.
    @State private var keep: Set<String> = []
    /// The panel's move under way, and the phase moves run by (up one a move, animated).
    @State private var flip: GridFlip?
    @State private var phase = 0.0
    /// Whether the panel was open, as the grid was last laid out (it differs the moment it opens or closes).
    @State private var laidOutOpen: Bool?
    @State private var told: Set<String> = []
    @State private var toldTop = true
    @State private var cache = LayoutCache()

    var layout: EventGridLayout { cache.layout(sections: sections, width: width, columns: columns) }

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
                        .modifier(FlipPlacement(phase: phase, target: phase, start: flip?.start ?? phase,
                                                from: CGPoint(x: 0, y: flip.flatMap { f in f.header(h.day).map { $0 + f.offset } } ?? h.y),
                                                to: CGPoint(x: 0, y: h.y)))
                }
                ForEach(Array(made) + extra, id: \.id) { item in
                    if let event = events[item.id] {
                        EventCard(event: event, camera: name(event.camera), selected: selected == item.id,
                                  fresh: fresh.contains(item.id),
                                  choose: { choose(event) }, open: { open(event) })
                            .frame(width: item.frame.width, height: item.frame.height)
                            .modifier(FlipPlacement(phase: phase, target: phase, start: flip?.start ?? phase,
                                                    from: flip.flatMap { f in f.card(item.id).map { CGPoint(x: $0.x, y: $0.y + f.offset) } } ?? item.frame.origin,
                                                    to: item.frame.origin))
                            // New ones grow in; any other made (scrolled near, or through a move) is simply there.
                            .transition(fresh.contains(item.id) ? .scale(scale: 0.92).combined(with: .opacity) : .identity)
                    }
                }
            }
            .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y } action: { _, y in
            offset = y
            tell()
        }
        .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
            let first = viewHeight == 0
            viewHeight = height
            if laidOutOpen == nil { laidOutOpen = panelOpen }
            tell()
            // A move asked before it knew its height (coming back with an event open): now.
            if first, let request {
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
                    .offset(y: min(0, next - offset - EventGridLayout.headerHeight))
            }
        }
        .clipped()
        .onChange(of: panelOpen) { _, open in panelChanged(open: open) }
        .onChange(of: request) { _, request in
            guard let request else { return }
            self.request = nil
            perform(request)
        }
        .onChange(of: sections) { old, new in kept(from: old, to: new) }
    }

    func header(_ day: Date, count: Int, pinned: Bool) -> some View {
        HStack(spacing: 8) {
            // Frosted glass, so it reads over the pictures scrolling under it; lifted off them by a shadow.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(EventsView.dayTitle(day)).font(.title3.weight(.bold))
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
    }

    /// Whether a card is wholly in view, below the pinned header.
    func wholly(_ id: String) -> Bool {
        guard let frame = layout.cards[id] else { return false }
        return frame.minY >= offset + EventGridLayout.headerHeight - 4 && frame.maxY <= offset + viewHeight + 1
    }

    /// Cards made besides those near the screen: those kept through a move, and, the moment the panel's opened or
    /// closed (its move not begun), those on screen before.
    func also(_ margin: Double) -> Set<String> {
        guard let laidOutOpen, laidOutOpen != panelOpen else { return keep }
        let before = EventGridLayout(sections: sections, width: width + (panelOpen ? panelWidth : -panelWidth), columns: columns)
        return keep.union(before.cards(in: (offset - margin) ... (offset + viewHeight + margin)).map(\.id))
    }

    /// The cards made: those within this of the screen, either way.
    var margin: Double { max(600, viewHeight * 1.5) }

    /// The panel opened or closed (the width's already the new one): the scroll is put at once where the focused
    /// card's row is in the middle (or, with none, where the top card stays put), and every card is drawn moving
    /// from where it was on screen to where it now goes, one animation with the panel's. Begun part way through
    /// another, it moves them on from where that one had them.
    func panelChanged(open: Bool) {
        laidOutOpen = open
        guard viewHeight > 0 else { return }
        let before = EventGridLayout(sections: sections, width: width + (open ? panelWidth : -panelWidth), columns: columns)
        let drawn = before.cards(in: (offset - margin) ... (offset + viewHeight + margin))
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
        let target: Double
        if let focus, let centred = layout.centring(focus, view: viewHeight) {
            target = centred
        } else if let first = before.cards(in: offset ... (offset + viewHeight)).first, let after = layout.cards[first.id] {
            target = layout.clamp(after.minY - (first.frame.minY - offset), view: viewHeight)
        } else {
            target = layout.clamp(offset, view: viewHeight)
        }
        keep = Set(drawn.map(\.id)).union(layout.cards(in: (target - margin) ... (target + viewHeight + margin)).map(\.id))
        // At once (no animation): the scroll, and where each card starts from.
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) {
            flip = GridFlip(before: before, beforeOffset: offset, cards: cards, headers: headers, offset: target, start: start, began: now)
            position.scrollTo(y: target)
            offset = target
        }
        withAnimation(Self.panelAnimation) {
            phase += 1
        } completion: {
            guard flip?.began == now else { return }
            flip = nil
            keep = []
        }
    }

    func perform(_ request: GridScroll) {
        switch request.kind {
        case .top:
            withAnimation(request.animated ? Self.bring : nil) { position.scrollTo(y: 0) }
        case let .centre(id, always):
            guard always || !wholly(id), let target = layout.centring(id, view: viewHeight) else { return }
            if request.animated {
                withAnimation(Self.bring) { position.scrollTo(y: target) }
            } else {
                position.scrollTo(y: target)
            }
        }
    }

    /// Events came or went: scrolled down, what's on screen is kept where it is (the scroll moved by as much as the
    /// cards above it did); at the top, they slide in.
    func kept(from old: [EventGridLayout.Section], to new: [EventGridLayout.Section]) {
        guard offset > 40, viewHeight > EventGridLayout.headerHeight else { return }
        let before = EventGridLayout(sections: old, width: width, columns: columns)
        guard let first = before.cards(in: (offset + EventGridLayout.headerHeight) ... (offset + viewHeight)).first,
              let now = layout.cards[first.id] else { return }
        position.scrollTo(y: layout.clamp(offset + (now.minY - first.frame.minY), view: viewHeight))
    }
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
