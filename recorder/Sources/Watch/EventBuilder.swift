// A camera's events, from its tracks. An event begins when something that matters (a person, vehicle, animal or
// package) has been seen moving, more than once. It goes on while that's in view, moving or not (the watcher
// keeps looking every few seconds while something is followed): a dog that walks in and lies down is one event.
// It ends when nothing has been seen for a while, or when what's there has been still for a couple of minutes
// (a car that parked). If the same thing (its track, never lost) moves again later, or the same kind of thing
// moves again soon after, the event takes up again rather than a new one beginning. What it was is its surest
// category (a person before a vehicle before an animal, then a package), what else was seen with it (the most
// at once), and its best picture: the surest sighting of that.
import Detection
import Foundation

/// An event, as it's kept.
public struct CameraEvent: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var camera: String
    public var start: Date
    public var end: Date
    /// What it was (its most important category seen).
    public var category: DetectedCategory
    /// Everything seen in it, by the model's labels: the most of each in one picture.
    public var labels: [String: Int]
    public var confidence: Double
    /// Its picture, relative to the events folder ("events/<camera>/<date>/<time>-<id>.jpg"); nil until saved.
    public var snapshot: String?
    /// Where its subject was in the picture.
    public var box: Detection.Box?
    /// A sentence about it (later: the on-device model's).
    public var summary: String?
    /// The watched zones it was in (by their ids).
    public var zones: [String] = []

    public var seconds: Double { end.timeIntervalSince(start) }

    public init(id: String = UUID().uuidString, camera: String, start: Date, end: Date, category: DetectedCategory,
                labels: [String: Int] = [:], confidence: Double = 0, snapshot: String? = nil, box: Detection.Box? = nil,
                summary: String? = nil, zones: [String] = []) {
        self.id = id
        self.camera = camera
        self.start = start
        self.end = end
        self.category = category
        self.labels = labels
        self.confidence = confidence
        self.snapshot = snapshot
        self.box = box
        self.summary = summary
        self.zones = zones
    }
}

extension CameraEvent {
    /// What was seen, counted, most first: "2 people and a dog".
    public static func words(_ labels: [String: Int]) -> String {
        guard !labels.isEmpty else { return "something" }
        let parts = labels.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { label, n in
            n == 1 ? ("aeiou".contains(label.first ?? "x") ? "an " : "a ") + label : "\(n) \(plural(label))"
        }
        return join(parts)
    }

    public static func plural(_ word: String) -> String {
        switch word {
        case "person": "people"
        case "sheep", "deer": word
        default: word.hasSuffix("s") || word.hasSuffix("sh") || word.hasSuffix("ch") ? word + "es" : word + "s"
        }
    }

    public static func join(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }
}

public struct EventBuilder: Sendable {
    public let camera: String
    /// Nothing seen this long, an event ends.
    public var endAfter: TimeInterval = 10
    /// Everything still this long (in view, not moving), an event ends.
    public var stillEnd: TimeInterval = 120
    /// The same kind of thing moving again this soon after an event ended takes it up again.
    public var resumeWithin: TimeInterval = 30
    /// Seen this many times (moving) before an event begins: one sighting may be a mistake.
    public var minimumSightings = 2
    /// The categories that make events, the first the most telling: a bike moving has someone on it, so an
    /// event with both is a bike's (a cyclist), not just a person's.
    public static let important: [DetectedCategory] = [.bike, .person, .vehicle, .animal, .package]

    public private(set) var current: CameraEvent?
    /// The most of each label seen at once in the current event, and of each category (the model's words can
    /// change for one thing; the category's count is what's true).
    private var peak: [String: Int] = [:]
    private var peakByCategory: [DetectedCategory: Int] = [:]
    /// Each label's confidence summed over the event, and its category.
    private var votes: [String: (category: DetectedCategory, weight: Double)] = [:]
    /// The tracks in the current event (or the last, once ended).
    private var tracks: Set<Int> = []
    private var lastSeen: Date?
    private var lastMoved: Date?
    /// The last event, after it ended, while it may be taken up again.
    private var ended: (event: CameraEvent, kept: ([String: Int], [DetectedCategory: Int], [String: (category: DetectedCategory, weight: Double)]))?

    public init(camera: String) { self.camera = camera }

    public enum Change: Sendable, Equatable {
        case began(CameraEvent)
        /// Its best picture so far is this sighting (the caller keeps the frame).
        case better(CameraEvent)
        case ended(CameraEvent)
        /// An event that had ended, taken up again (the same thing moving again): it's ongoing once more.
        case resumed(CameraEvent)
    }

    /// A picture's tracks taken in (from the tracker); what changed.
    public mutating func update(_ sightings: [(track: Track, best: Bool)], at time: Date) -> [Change] {
        var changes: [Change] = []
        // What counts: something that matters, seen more than once, and moving lately (a car parked since before
        // isn't part of anything, however long it's in view).
        let counting = sightings.filter {
            Self.important.contains($0.track.category) && $0.track.seen >= minimumSightings
                && $0.track.lastMoved.map { time.timeIntervalSince($0) <= stillEnd } == true
        }
        let moving = counting.filter { $0.track.lastMoved == time }
        // What keeps an event going: its kind, or a more telling one (cars passing while someone's at the door are
        // in the event, but don't keep it going once they've gone).
        if let event = current {
            let keeping = counting.filter { Self.rank($0.track.category) <= Self.rank(event.category) }
            if !keeping.isEmpty { lastSeen = time }
            if keeping.contains(where: { $0.track.lastMoved == time }) { lastMoved = time }
        }
        changes += quiet(at: time)
        guard !counting.isEmpty else { return changes }
        if current == nil {
            // Only something moving begins (or takes up) an event; what's merely still in view doesn't.
            guard !moving.isEmpty else { return changes }
            if let (event, kept) = ended, Self.resumes(event, tracks: tracks, by: moving, at: time, within: resumeWithin) {
                current = event
                (peak, peakByCategory, votes) = kept
                ended = nil
                lastSeen = time
                lastMoved = time
                changes.append(.resumed(event))
            } else {
                let first = moving.max { Self.rank($0.track.category) > Self.rank($1.track.category) }!
                // (From when what began it set off: when it was first seen, or, parked a while, when it went again.)
                current = CameraEvent(camera: camera, start: first.track.activeSince ?? first.track.firstSeen, end: time,
                                      category: first.track.category,
                                      confidence: first.track.bestConfidence, box: first.track.box)
                peak = [:]
                peakByCategory = [:]
                votes = [:]
                tracks = []
                ended = nil
                lastSeen = time
                lastMoved = time
                changes.append(.began(current!))
            }
        }
        guard var event = current else { return changes }
        // (It runs as long as what keeps it going is seen.)
        event.end = max(event.end, lastSeen ?? time)
        var better = false
        // How many of each at once (one person found as two tracks for a moment counts once at most moments).
        for (label, n) in counting.reduce(into: [String: Int](), { $0[$1.track.label, default: 0] += 1 }) {
            peak[label] = max(peak[label] ?? 0, n)
        }
        for (category, n) in counting.reduce(into: [DetectedCategory: Int](), { $0[$1.track.category, default: 0] += 1 }) {
            peakByCategory[category] = max(peakByCategory[category] ?? 0, n)
        }
        for s in counting {
            votes[s.track.label, default: (s.track.category, 0)].weight += s.track.bestConfidence
            tracks.insert(s.track.id)
            // A more important category takes over; within one, a surer sighting is the better picture.
            if Self.rank(s.track.category) < Self.rank(event.category)
                || (s.track.category == event.category && s.best && s.track.bestConfidence >= event.confidence) {
                event.category = s.track.category
                event.confidence = s.track.bestConfidence
                event.box = s.track.box
                better = true
            }
        }
        event.labels = Self.labels(peak: peak, peakByCategory: peakByCategory, votes: votes)
        event.zones = Array(Set(event.zones).union(counting.flatMap(\.track.zones))).sorted()
        current = event
        if better { changes.append(.better(event)) }
        return changes
    }

    /// Whether something moving takes up the event that ended: one of its own tracks (followed all along), or
    /// the same kind of thing soon after it ended.
    static func resumes(_ event: CameraEvent, tracks: Set<Int>, by moving: [(track: Track, best: Bool)], at time: Date,
                        within: TimeInterval) -> Bool {
        if moving.contains(where: { tracks.contains($0.track.id) }) { return true }
        // The same kind soon after: someone, or an animal, lost from view a moment. Not vehicles (a street's traffic
        // is car after car, each its own).
        guard event.category != .vehicle else { return false }
        return time.timeIntervalSince(event.end) <= within && moving.contains { $0.track.category == event.category }
    }

    /// Time passing (a picture with nothing in it, or none looked at): the current event ends if nothing has been
    /// seen for a while, or nothing has moved for longer.
    public mutating func quiet(at time: Date) -> [Change] {
        guard current != nil else { return [] }
        let unseen = lastSeen.map { time.timeIntervalSince($0) > endAfter } ?? true
        let still = lastMoved.map { time.timeIntervalSince($0) > stillEnd } ?? false
        guard unseen || still else { return [] }
        return finish()
    }

    /// The current event ended (the camera stopped, or quiet).
    public mutating func finish() -> [Change] {
        guard let event = current else { return [] }
        current = nil
        ended = (event, (peak, peakByCategory, votes))
        peak = [:]
        return [.ended(event)]
    }

    /// What was seen, by the model's words, never more of a category than were seen at once: one cat, called
    /// a dog for a moment, is "a cat" (the word it was given most surely), not "a cat and a dog".
    static func labels(peak: [String: Int], peakByCategory: [DetectedCategory: Int],
                       votes: [String: (category: DetectedCategory, weight: Double)]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (category, most) in peakByCategory {
            var left = most
            let words = peak.keys.filter { votes[$0]?.category == category }.sorted { (votes[$0]?.weight ?? 0) > (votes[$1]?.weight ?? 0) }
            for word in words where left > 0 {
                let n = min(peak[word] ?? 0, left)
                if n > 0 { out[word] = n }
                left -= n
            }
        }
        return out
    }

    static func rank(_ category: DetectedCategory) -> Int { important.firstIndex(of: category) ?? important.count }
}
