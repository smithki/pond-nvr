// The Events grid's layout and what it's told: every card the same size, so where each one goes is arithmetic
// (columns, a card's width and height, a header a day), and every place is known exactly, before a change and
// after. Drawn by `EventGridAppKit` (cards in layers, in an NSScrollView) in the Events page's AppKit surface
// (`EventsShell`); its motions are worked out from the measures and curves here.
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
    /// Every card's frame, by id: worked out when asked, from its section and place in it (each one's, worked out
    /// and kept for each width, was tens of milliseconds with many events: the panel's first frame, and every
    /// step of a window being resized).
    let cards: Frames
    let height: Double

    /// Where each card is: its section, and its place in it (the same whatever the width: worked out once for the
    /// sections, and shared by their layouts at every width).
    final class Places: @unchecked Sendable {
        let of: [String: (section: Int, index: Int)]
        init(_ sections: [Section]) {
            var of: [String: (section: Int, index: Int)] = [:]
            of.reserveCapacity(sections.reduce(0) { $0 + $1.ids.count })
            for (s, section) in sections.enumerated() {
                for (i, id) in section.ids.enumerated() where of[id] == nil { of[id] = (s, i) }
            }
            self.of = of
        }
    }

    /// A section's cards: their ids, and where its first row starts.
    struct Block {
        let ids: [String]
        let top: Double
        var rows: Int
    }

    struct Frames {
        let blocks: [Block]
        let places: Places
        let columns: Int
        let card: CGSize

        var pitch: Double { card.height + EventGridLayout.spacing }

        func frame(_ i: Int, in block: Block) -> CGRect {
            CGRect(x: Double(i % columns) * (card.width + EventGridLayout.spacing), y: block.top + Double(i / columns) * pitch,
                   width: card.width, height: card.height)
        }

        subscript(id: String) -> CGRect? {
            guard let place = places.of[id], blocks.indices.contains(place.section) else { return nil }
            let block = blocks[place.section]
            guard block.ids.indices.contains(place.index), block.ids[place.index] == id else { return nil }
            return frame(place.index, in: block)
        }
    }

    init(sections: [Section], width: Double, columns: Int, places: Places? = nil) {
        let n = max(1, columns)
        let cw = max(120, (width - Self.spacing * Double(n - 1)) / Double(n))
        // A card: its picture (16:9, the card less its padding), its words below.
        let ch = Self.pad + (cw - 2 * Self.pad) * 9 / 16 + Self.pad + Self.textHeight + Self.pad
        var headers: [(day: Date, y: Double, count: Int)] = []
        var blocks: [Block] = []
        var y = 0.0
        for section in sections {
            headers.append((section.day, y, section.ids.count))
            y += Self.headerHeight
            let rows = (section.ids.count + n - 1) / n
            blocks.append(Block(ids: section.ids, top: y, rows: rows))
            y += Double(rows) * (ch + Self.spacing) - Self.spacing + Self.sectionGap
        }
        self.width = width
        self.columns = n
        card = CGSize(width: cw, height: ch)
        self.headers = headers
        cards = Frames(blocks: blocks, places: places ?? Places(sections), columns: n, card: CGSize(width: cw, height: ch))
        height = max(0, y)
    }

    /// The cards overlapping `range` (of the content's height), in order.
    func cards(in range: ClosedRange<Double>) -> [(id: String, frame: CGRect)] {
        var found: [(id: String, frame: CGRect)] = []
        let pitch = cards.pitch
        for block in cards.blocks where block.rows > 0 {
            let bottom = block.top + Double(block.rows) * pitch - EventGridLayout.spacing
            guard bottom >= range.lowerBound, block.top <= range.upperBound else { continue }
            // The first row whose bottom reaches the range, to the last that starts within it.
            let first = max(0, Int(((range.lowerBound - block.top - card.height) / pitch).rounded(.up)))
            let last = min(block.rows - 1, Int(((range.upperBound - block.top) / pitch).rounded(.down)))
            guard first <= last else { continue }
            for i in (first * columns) ..< min(block.ids.count, (last + 1) * columns) {
                found.append((block.ids[i], cards.frame(i, in: block)))
            }
        }
        return found
    }

    /// The offset that puts a card's row in the middle of a view `height` tall (as near as the ends allow).
    func centring(_ id: String, view height: Double) -> Double? {
        guard let frame = cards[id] else { return nil }
        return clamp(frame.midY - height / 2, view: height)
    }

    /// The least scroll from `offset` that has the card `margin` clear of the edges (`top` more at the top, for the
    /// day pinned there); nil if it is already.
    func revealing(_ id: String, offset: Double, view height: Double, top: Double, margin: Double) -> Double? {
        guard let frame = cards[id] else { return nil }
        if frame.minY < offset + top + margin { return clamp(frame.minY - top - margin, view: height) }
        if frame.maxY > offset + height - margin { return clamp(frame.maxY + margin - height, view: height) }
        return nil
    }

    /// An offset kept within the content.
    func clamp(_ offset: Double, view height: Double) -> Double {
        min(max(0, offset), max(0, self.height - height))
    }
}

/// The zoom's fades, as the grid's width changes (the panel opening or closing, the rail going or coming): the cards
/// as they were under the cards as they are now, which fade in over them, both zooming from the old width to the
/// new; then the old go (see `GridZoom`).
enum GridReshape {
    /// How much of the new is shown at `p`, and of the old: a crossfade through most of the move, the new coming in
    /// over the old a little ahead of it going, so a card over itself never dims. (Quicker, the old gone by half
    /// way, there was no ghosting of the old cards round the new ones' edges, but the cards seemed to jump from
    /// one grid to the other.)
    static func new(_ p: Double) -> Double { ease(p / 0.85) }
    static func old(_ p: Double) -> Double { 1 - ease((p - 0.15) / 0.85) }
    /// The cards softened as they go, most half way, sharp again as they land: motion blur, of a sort, so the two
    /// grids blend. (Light: blurring the whole grid each frame costs the graphics chip.)
    static func blur(_ p: Double) -> Double { 2 * sin(.pi * min(max(p, 0), 1)) }
    static func ease(_ t: Double) -> Double { let t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }
}

/// Newest first or best match: a search's answer's order, a capsule of two, the one shown lit. Best match only
/// when the question asked how things looked (else there's no order but time's).
struct OrderSwitch: View {
    let bestMatch: Bool
    let canRank: Bool
    /// Narrow: symbols, not words.
    let compact: Bool
    let height: Double
    let choose: (Bool) -> Void
    @Namespace private var lit

    var body: some View {
        HStack(spacing: 2) {
            segment(false, title: "Newest", symbol: "clock")
                .help("Newest first, by day")
            segment(true, title: "Best Match", symbol: "sparkles")
                .help(canRank ? "The best matches first" : "Best Match orders by how things looked: ask for that, like \u{201C}a man in a red jacket\u{201D}")
        }
        .padding(4)
        .frame(height: height)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .animation(.snappy(duration: 0.25), value: bestMatch)
    }

    func segment(_ best: Bool, title: String, symbol: String) -> some View {
        let on = best == bestMatch
        return Button {
            // (Best match greyed when it can't be: its help, why, still shown on hover, which `.disabled` stops.)
            if !on, canRank || !best { choose(best) }
        } label: {
            Group {
                if compact { Image(systemName: symbol) } else { Text(title) }
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(on ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background {
                if on { Capsule().fill(.fill.secondary).matchedGeometryEffect(id: "lit", in: lit) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(best && !canRank ? 0.4 : 1)
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
    var change: GridChange?
    /// A swap's: where the grid is kept before it (into a search), or gone back to after (out of one).
    var remember = false
    var restore = false
    var id = UUID()

    static func == (a: GridScroll, b: GridScroll) -> Bool { a.id == b.id }
}

/// What the grid shows, and what it does: given it by the Events view (`EventsView.makeGrid`); and its measures
/// and curves.
struct EventGrid {
    let sections: [EventGridLayout.Section]
    let events: [String: TimelineEvent]
    /// The grid's width now, and how much narrower the panel makes it.
    let width: Double
    let columns: Int
    let panelOpen: Bool
    /// Where the grid begins in the view (beside the rail, or not): when it changes with the panel, the cards'
    /// move begins from where they were on screen, not in the grid.
    var leading = 0.0
    /// How far down the filters' bar over the grid's top reaches, and how tall the strip at its bottom is (under the
    /// window's edge's glass): the grid scrolls on under both, its cards in view only between them.
    var topInset = 0.0
    var bottomInset = 0.0
    let panelWidth: Double
    /// The card the panel's opening or closing centres (the chosen one, or the one that was).
    let focus: String?
    let selected: String?
    let fresh: Set<String>
    /// Not seen yet (marked).
    var unseen: Set<String> = []
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
    /// Whether it's within a short scroll of the top (new events come in as they come; further down, they wait).
    var onNear: (Bool) -> Void = { _ in }
    /// New events waiting (not in the grid yet), for the Now button, and how they're let in: as it goes to the top.
    var newWaiting = 0
    var letIn: GridChange?
    /// Whether anything's scrolled under the bar above it, and whether any card or day is in the strip at its
    /// bottom.
    var onScrolled: (Bool) -> Void = { _ in }
    var onUnderBottom: (Bool) -> Void = { _ in }
    /// A search's answer by best match, not by time: each card says its day as well, and the way back up is to the
    /// top, not to now.
    var byBestMatch = false
    /// A search's answer shown: its order (newest first, or best match, when it can be), and the switch between
    /// them, floated over the grid's top right, level with the day's header.
    var order: GridOrder?
    struct GridOrder {
        let bestMatch: Bool
        let canRank: Bool
        let choose: (Bool) -> Void
    }

    /// Cards moving as events come and go: this spring (the cards a row as they were, each to its new place).
    static let panelSpring = Spring(duration: 0.5, bounce: 0)
    static let panelAnimation = Animation.spring(panelSpring)
    /// The panel opening or closing: the grid's zoom, the panel's slide and the rail's, one move, this long, on the
    /// `.smooth` curve (`EventsShell`, `GridHostView.zoomSpring`).
    static let reshapeTakes = 0.4
    static let reshapeAnimation = Animation.smooth(duration: reshapeTakes)
    // (Further than `GridMotion.farJump` screens, a card's brought there by a jump (the grid fading out and in)
    // rather than a scroll: scrolling through days of cards made and read every one on the way, which stuttered,
    // and the rail's outline restarted with every day that passed. Closing the panel further than
    // `GridMotion.farPanel` from the card, every card flying that far as it reshaped was too much; a jump instead.)
    /// Closing the panel far from the card: the jump begun this far into the zoom.
    static let leaveAfterPanel = 0.65
    /// A far jump eases this far away the way it's going as it fades out, and lands this far short of where it's
    /// going and eases the rest as it fades in, so it's seen to leave and arrive that way.
    static let jumpLead = 180.0
    /// Leaving and arriving both, this long (shorter as the grid's ends shorten them).
    static let jumpTakes = 0.85
    /// How out of focus the grid goes as it fades out (a far jump, the events changing).
    static let veilBlur = 8.0
    /// Scrolled faster than this many screens a second (the scroller dragged, or a long fling), for a few moments
    /// running, the cards are plain blocks, dimmed, and the day and hour they're at is shown over them; slower than
    /// the second, the cards are shown again (their pictures read first).
    static let scrubStarts = 3.5
    static let scrubEnds = 2.0
    /// Room either side of a scroller that takes it (scroll bars always shown).
    static let scrollerGap = 6.0
}

/// What the grid's scroll view says of itself: its offset, the inset at its top, its height.
/// The grid's width and how many cards a row: what a window's resize changes.
struct GridSize: Equatable {
    let width: Double
    let columns: Int
}

/// The events shown changed (a search, its order, those held back let in): made, and whether the grid's sections
/// changed with it.
typealias GridChange = @MainActor () -> Bool

/// A swap's change made: where to show it, and what to call once it's there.
@MainActor final class Swapping {
    let top: Bool
    /// Where to land instead: a card, and how far down the view.
    var back: (id: String, y: Double)?
    let landed: @MainActor ([URL]) -> Void
    /// Drawn this far short of where it lands (a jump's lead-in to come).
    let drawnAt: Double?
    init(top: Bool, drawnAt: Double? = nil, landed: @escaping @MainActor ([URL]) -> Void) {
        self.top = top
        self.drawnAt = drawnAt
        self.landed = landed
    }
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

/// A far jump's ease: one ease-in-out along its leaving and its arriving together, cut where the one ends (by how
/// far each goes), each piece an animation of its own (a piece of a timing curve is one too: de Casteljau's split,
/// each half scaled to run from 0 to 1). So the speed it leaves at is the speed it arrives at.
enum JumpEase {
    static let curve = (x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0)

    struct Pieces {
        var leave: Animation?
        var leaveFor = 0.0
        var arrive: Animation?
        var arriveFor = 0.0
    }

    /// Either nil if it goes nowhere (under a point).
    static func split(leaving out: Double, arriving in_: Double, over total: Double) -> Pieces {
        let whole = Animation.timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: total)
        guard out + in_ >= 1 else { return Pieces() }
        if out < 1 { return Pieces(arrive: whole, arriveFor: total) }
        if in_ < 1 { return Pieces(leave: whole, leaveFor: total) }
        let (left, right, at) = cut(where: out / (out + in_))
        return Pieces(leave: .timingCurve(left.0, left.1, left.2, left.3, duration: total * at),
                      leaveFor: total * at,
                      arrive: .timingCurve(right.0, right.1, right.2, right.3, duration: total * (1 - at)),
                      arriveFor: total * (1 - at))
    }

    /// The curve cut where it's come `fraction` of the way: each half's control points (scaled to run from (0, 0)
    /// to (1, 1)), and when (of the whole time) the cut is.
    static func cut(where fraction: Double) -> (left: (Double, Double, Double, Double), right: (Double, Double, Double, Double), at: Double) {
        typealias P = (x: Double, y: Double)
        let p0: P = (0, 0), p1: P = (curve.x1, curve.y1), p2: P = (curve.x2, curve.y2), p3: P = (1, 1)
        func lerp(_ a: P, _ b: P, _ u: Double) -> P { (a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u) }
        func point(_ u: Double) -> P {
            let q0 = lerp(p0, p1, u), q1 = lerp(p1, p2, u), q2 = lerp(p2, p3, u)
            return lerp(lerp(q0, q1, u), lerp(q1, q2, u), u)
        }
        // The curve's parameter where it's come that far (its progress only grows with it).
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if point(mid).y < fraction { lo = mid } else { hi = mid }
        }
        let u = (lo + hi) / 2
        let q0 = lerp(p0, p1, u), q1 = lerp(p1, p2, u), q2 = lerp(p2, p3, u)
        let r0 = lerp(q0, q1, u), r1 = lerp(q1, q2, u), s = lerp(r0, r1, u)
        let left = (q0.x / s.x, q0.y / s.y, r0.x / s.x, r0.y / s.y)
        let right = ((r1.x - s.x) / (1 - s.x), (r1.y - s.y) / (1 - s.y), (q2.x - s.x) / (1 - s.x), (q2.y - s.y) / (1 - s.y))
        return (left, right, s.x)
    }
}

/// The last layout, kept while its inputs are the same (the grid's body runs each frame of a scroll).
final class LayoutCache {
    /// The last few (the panel opening or closing asks for the width before it as well as after).
    private var kept: [(sections: [EventGridLayout.Section], width: Double, columns: Int, layout: EventGridLayout)] = []
    /// Where each card is in the last two lists of sections laid out (the same at every width; two: as events
    /// change, the grid asks for the old and the new).
    private var places: [(sections: [EventGridLayout.Section], places: EventGridLayout.Places)] = []

    func layout(sections: [EventGridLayout.Section], width: Double, columns: Int) -> EventGridLayout {
        if let i = kept.firstIndex(where: { $0.width == width && $0.columns == columns && $0.sections == sections }) {
            if i != kept.count - 1 { kept.append(kept.remove(at: i)) }
            return kept[kept.count - 1].layout
        }
        let found: EventGridLayout.Places
        if let kept = places.first(where: { $0.sections == sections }) {
            found = kept.places
        } else {
            found = EventGridLayout.Places(sections)
            places.append((sections, found))
            if places.count > 2 { places.removeFirst() }
        }
        let made = EventGridLayout(sections: sections, width: width, columns: columns, places: found)
        kept.append((sections, width, columns, made))
        if kept.count > 4 { kept.removeFirst() }
        return made
    }

    /// One for a width passed through (a reshape's frames): made, not kept (its places shared).
    func passing(sections: [EventGridLayout.Section], width: Double, columns: Int) -> EventGridLayout {
        let found = places.first(where: { $0.sections == sections })?.places
        return EventGridLayout(sections: sections, width: width, columns: columns, places: found)
    }
}
