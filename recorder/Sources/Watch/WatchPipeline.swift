// What watching a camera decides, picture by picture: whether to look (pictures a fifth of a second apart),
// what moves (the motion gate), whether to ask the model (while something moves, a couple of seconds after, and
// now and then while something's followed or put down), what counts by the zones, how it's followed (the tracker),
// and the events that makes (the event builder) and things left behind. The camera's watcher runs it on its live
// pictures; test scenes run it on a recording's, so what they measure is what the recorder does.
import Detection
import Foundation

public struct WatchPipeline: Sendable {
    /// Motion looked for this often.
    public static let lookEvery: TimeInterval = 0.2
    /// The model run at most this often, while something moves.
    public static let detectEvery: TimeInterval = 0.25
    /// And for this long after it stops.
    public static let detectAfterMotion: TimeInterval = 2
    /// While something is followed but nothing moves, the model looks this often (to know it's still there).
    public static let presenceLookEvery: TimeInterval = 2

    public let rules: ZoneRules
    public private(set) var gate = MotionGate()
    public private(set) var tracker = Tracker()
    public private(set) var builder: EventBuilder
    public private(set) var leftItems: LeftItems
    private var lastLook = Date.distantPast, lastDetect = Date.distantPast, lastMotion = Date.distantPast

    public init(camera: String, rules: ZoneRules) {
        self.rules = rules
        builder = EventBuilder(camera: camera)
        leftItems = LeftItems(camera: camera)
        restart()
    }

    /// Afresh for a new connection: motion learnt again from the first pictures (what's followed, and events going on,
    /// are kept).
    public mutating func restart() {
        gate = MotionGate()
        gate.ignored = rules.ignoredCells(columns: gate.columns, rows: gate.rows)
        lastLook = .distantPast
        lastDetect = .distantPast
        lastMotion = .distantPast
    }

    /// What one picture came to.
    public struct Outcome: Sendable {
        public var changes: [EventBuilder.Change] = []
        /// What moved in it.
        public var mask: MotionMask?
        /// Whether the model looked at it (and answered).
        public var looked = false
        /// Looked at by the model: what it found, what of that counted (with its zones), and how they were followed.
        public var found: [Detection] = []
        public var counted: [(detection: Detection, zones: Set<String>)] = []
        public var sightings: [(track: Track, best: Bool)] = []
        /// Things left behind, each an event of its own.
        public var left: [CameraEvent] = []
    }

    /// Whether something's followed, or an event's going on (a closer look's priority).
    public var following: Bool { tracker.following(EventBuilder.important) }

    /// A picture, taken at `now`: nil if it's too soon after the last to look at. `cells` is its motion grid
    /// (MotionGate.cells), asked for only if it's looked at; `detect` asks the model (given what moves), nil if it
    /// couldn't.
    public mutating func look(at now: Date, cells: () -> [Float], detect: (MotionMask) -> [Detection]?) -> Outcome? {
        guard now.timeIntervalSince(lastLook) >= Self.lookEvery else { return nil }
        lastLook = now
        var out = Outcome()
        let mask = gate.moving(cells())
        out.mask = mask
        if mask.isMoving { lastMotion = now }
        let moving = now.timeIntervalSince(lastMotion) <= Self.detectAfterMotion
        // While something is followed (a dog lying down), or put down and waiting to be seen again, the model looks
        // now and then though nothing moves: so it's known to be still there.
        let present = tracker.following(EventBuilder.important) || builder.current != nil
        let checking = (present && now.timeIntervalSince(lastDetect) >= Self.presenceLookEvery)
            || (leftItems.isWaiting && now.timeIntervalSince(lastDetect) >= leftItems.lookEvery)
        guard moving || checking else {
            out.changes = builder.quiet(at: now)
            return out
        }
        guard checking || now.timeIntervalSince(lastDetect) >= Self.detectEvery else { return out }
        lastDetect = now
        guard let found = detect(mask) else { return out }
        out.looked = true
        out.found = found
        // What counts by the zones, with the zones it's in.
        let counted = found.compactMap { d in rules.zones(for: d).map { (detection: d, zones: $0) } }
        out.counted = counted
        out.sightings = tracker.update(counted.map(\.detection), mask: mask, at: now) { d in
            counted.first { $0.detection == d }?.zones ?? []
        }
        out.changes = builder.update(out.sightings, at: now)
        let items = counted.filter { $0.detection.category == .item }
            .map { (detection: $0.detection, zones: $0.zones, moved: mask.overlaps(($0.detection.box.x, $0.detection.box.y, $0.detection.box.width, $0.detection.box.height))) }
        out.left = leftItems.update(items, people: found.filter { $0.category == .person }, at: now)
        return out
    }

    /// Nothing to look at for a while (no pictures): events that have gone quiet end.
    public mutating func quiet(at now: Date) -> [EventBuilder.Change] { builder.quiet(at: now) }

    /// The end of the pictures: whatever's going on ends.
    public mutating func finish() -> [EventBuilder.Change] { builder.finish() }
}
