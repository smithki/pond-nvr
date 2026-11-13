// The Events grid's motion, as state: what's moving and why, kept apart from the view that draws it, so how one
// motion gives way to another is in one place, and tested (GridMotionTests). The view asks this what to do and
// does it (animating, scrolling); this never draws, scrolls or waits.
//
// What can be under way at once:
//  - one move of the cards: a `flip` (events came or went: each card from where it was to where it goes) or a
//    `reshape` (the panel opened or closed: the grid zoomed from its old width to its new). A new one replaces it;
//    landing (being put somewhere at once) ends it.
//  - one veil: the grid faded out while it's put somewhere far (a far jump) or its events change wholesale (a
//    swap). A request for anything else gives it up.
//  - clicks held while a far jump settles; events come meanwhile held back until it has.
import Foundation

struct GridMotion {
    // MARK: The cards' move

    enum Move {
        case flip(GridFlip)
        case reshape(GridReshape)

        var began: Date {
            switch self {
            case let .flip(f): f.began
            case let .reshape(r): r.began
            }
        }
    }

    private(set) var move: Move?
    var flip: GridFlip? { if case let .flip(f) = move { f } else { nil } }
    var reshaping: GridReshape? { if case let .reshape(r) = move { r } else { nil } }
    /// The phase the move under way runs from (the grid's own, still).
    func start(else phase: Double) -> Double {
        switch move {
        case let .flip(f)?: f.start
        case let .reshape(r)?: r.start
        case nil: phase
        }
    }

    /// A move begun, in place of any under way.
    mutating func begin(_ move: Move) { self.move = move }

    /// A move's animation done: ended if it's still the one under way (not one begun since), and whether it was.
    @discardableResult
    mutating func ended(began: Date) -> Bool {
        guard move?.began == began else { return false }
        move = nil
        return true
    }

    /// Put somewhere at once: no move under way.
    mutating func land() { move = nil }

    // MARK: The panel, as last laid out

    /// Whether the panel was open, and where the grid began in the view (beside the rail, or not), as the grid was
    /// last laid out. They differ from what's asked for the moment the panel opens or closes, before its move.
    private(set) var laidOutOpen: Bool?
    private(set) var laidOutLeading: Double?

    /// The moment between: the panel opened or closed, its move not begun.
    func between(panelOpen: Bool) -> Bool { laidOutOpen != nil && laidOutOpen != panelOpen }

    /// How far the grid's moved over in the view since it was laid out, that moment (the rail gone or come).
    func shift(panelOpen: Bool, leading: Double) -> Double {
        between(panelOpen: panelOpen) ? (laidOutLeading ?? leading) - leading : 0
    }

    /// First measured: as it is.
    mutating func measured(panelOpen: Bool, leading: Double) {
        if laidOutOpen == nil { laidOutOpen = panelOpen }
        if laidOutLeading == nil { laidOutLeading = leading }
    }

    /// Moved over otherwise (the window resized): as it is, unless the panel's move is to come.
    mutating func moved(to leading: Double, panelOpen: Bool) {
        if laidOutOpen == panelOpen { laidOutLeading = leading }
    }

    /// The panel opened or closed: laid out as it is now; how far the grid moved over (its move to begin from there).
    mutating func panelChanged(open: Bool, leading: Double) -> Double {
        let shift = (laidOutLeading ?? leading) - leading
        laidOutOpen = open
        laidOutLeading = leading
        return shift
    }

    // MARK: The panel's move, planned

    enum PanelPlan: Equatable {
        /// The cards reshape where they're going (the chosen card's row to the middle; or the top card kept).
        case reshape(to: Double)
        /// The chosen card far from what's on screen: the cards reshape where they are, then a far jump to it.
        case reshapeThenJump(here: Double, to: Double)
    }

    /// Where the panel's move goes: `centred`, the chosen card's row in the middle (if there's one); `here`, the
    /// top card on screen kept.
    static func panelPlan(centred: Double?, here: Double, view: Double) -> PanelPlan {
        guard let centred else { return .reshape(to: here) }
        return abs(centred - here) > farPanel * max(view, 1) ? .reshapeThenJump(here: here, to: centred) : .reshape(to: centred)
    }

    /// Further than this many screens from the card, the panel's move is followed by a far jump.
    static let farPanel = 1.0
    /// Further than this many screens, a scroll's a far jump instead.
    static let farJump = 2.0

    static func isFar(from offset: Double, to target: Double, view: Double) -> Bool {
        abs(target - offset) > farJump * max(view, 1)
    }

    // MARK: The veil (a far jump, or a swap)

    /// The veil under way (its id; a newer one takes over).
    private(set) var veil: UUID?
    /// A swap's (or a jump's) change made, waiting on its events to land.
    var swapping: Swapping?

    mutating func beginVeil() -> UUID {
        let id = UUID()
        veil = id
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { veil == id }

    /// Shown again: done, if it's still the one under way.
    @discardableResult
    mutating func endVeil(_ id: UUID) -> Bool {
        guard veil == id else { return false }
        veil = nil
        return true
    }

    /// Something else asked for: any veil under way given up (and whether there was one, to be shown again at once).
    mutating func interrupt() -> Bool {
        guard veil != nil else { return false }
        veil = nil
        swapping = nil
        settling = false
        return true
    }

    /// A swap's events came: it's there to land (once).
    mutating func takeSwap() -> Swapping? {
        defer { swapping = nil }
        return swapping
    }

    // MARK: Clicks, and events come meanwhile

    /// A far jump settling: the cards not clicked, and events come held back, till it's done (or a few seconds pass).
    private(set) var settling = false
    private var settleBy = 0.0
    private(set) var waiting: [EventGridLayout.Section]?

    /// Held from now (`now`, a clock in seconds): the sections shown kept, those come meanwhile waiting.
    mutating func holdClicks(now: Double, showing sections: [EventGridLayout.Section]) {
        settling = true
        if waiting == nil { waiting = sections }
        settleBy = now + Self.settleFor
    }

    /// Settled (or given up on, its time up).
    mutating func settled() { settling = false }
    mutating func timedOut(now: Double) { if now >= settleBy { settling = false } }
    static let settleFor = 3.0

    /// Events came while a far jump was under way: held (the sections drawn kept as they were).
    mutating func hold(_ was: [EventGridLayout.Section]) { if waiting == nil { waiting = was } }

    /// Those held, taken (to move from, with those come now).
    mutating func takeWaiting() -> [EventGridLayout.Section]? {
        defer { waiting = nil }
        return waiting
    }

    /// Once settled, those come meanwhile let in: the sections they move from, if any changed.
    mutating func letIn(now sections: [EventGridLayout.Section]) -> [EventGridLayout.Section]? {
        guard !settling, veil == nil, let was = waiting else { return nil }
        waiting = nil
        return was == sections ? nil : was
    }

    /// Whether events coming now wait (a far jump under way), or move in now.
    var holdsEvents: Bool { swapping == nil && (settling || veil != nil) }

    /// Whether the cards are clicked: not scrolling fast, nor a far jump settling, nor early in a move (each card's
    /// hover answered every move of the pointer as they went by); nearly still (`progress` of the way), they are.
    func clickable(scrubbing: Bool, progress: Double) -> Bool {
        !scrubbing && !settling && (move == nil || progress >= Self.clickableAfter)
    }

    static let clickableAfter = 0.6

    /// The scroller hidden while the grid reshapes (the scroll's put where it ends at once).
    var scrollerHidden: Bool { reshaping != nil }

    // MARK: A window's resize

    /// The card kept where it is through a resize: the top card on screen, and how far down the view, as it began.
    private(set) var resizeAnchor: (id: String, y: Double)?

    /// A step of a resize: the card to keep where it is (taken as the resize begins, from `here`, where it is then;
    /// the same card, at the same height, every step after).
    mutating func resizing(from here: @autoclosure () -> (id: String, y: Double)?) -> (id: String, y: Double)? {
        if resizeAnchor == nil { resizeAnchor = here() }
        return resizeAnchor
    }

    /// Done resizing: the next begins afresh.
    mutating func resized() { resizeAnchor = nil }

    // MARK: Before a search

    /// Where it was before a search: the top card on screen, and how far down the view it was.
    var remembered: (id: String, y: Double)?
}
