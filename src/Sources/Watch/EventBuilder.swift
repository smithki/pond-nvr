// A camera's events, from its tracks: an event begins when something that matters (a person, vehicle, animal or
// package) has been seen moving, more than once; it goes on while any such track is seen; it ends when none has
// been for a few seconds. What it was is its surest category (a person before a vehicle before an animal, then a
// package), what else was seen with it, and its best picture: the surest sighting of that.
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
    /// Everything seen in it, by the model's labels: how many tracks of each.
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
    /// Quiet this long, an event ends.
    public var endAfter: TimeInterval = 6
    /// Seen this many times (moving) before an event begins: one sighting may be a mistake.
    public var minimumSightings = 2
    /// The categories that make events.
    public static let important: [DetectedCategory] = [.person, .vehicle, .animal, .package]

    public private(set) var current: CameraEvent?
    /// The tracks in the current event.
    private var tracks: Set<Int> = []
    private var labelsByTrack: [Int: String] = [:]
    private var lastSeen: Date?

    public init(camera: String) { self.camera = camera }

    public enum Change: Sendable, Equatable {
        case began(CameraEvent)
        /// Its best picture so far is this sighting (the caller keeps the frame).
        case better(CameraEvent)
        case ended(CameraEvent)
    }

    /// A picture's tracks taken in (from the tracker); what changed.
    public mutating func update(_ sightings: [(track: Track, best: Bool)], at time: Date) -> [Change] {
        var changes: [Change] = []
        let counting = sightings.filter { Self.important.contains($0.track.category) && $0.track.moved && $0.track.seen >= minimumSightings }
        if let last = lastSeen, current != nil, counting.isEmpty, time.timeIntervalSince(last) > endAfter {
            changes.append(contentsOf: finish())
        }
        guard !counting.isEmpty else { return changes }
        lastSeen = time
        if current == nil {
            let first = counting.max { Self.rank($0.track.category) > Self.rank($1.track.category) }!
            current = CameraEvent(camera: camera, start: first.track.firstSeen, end: time, category: first.track.category,
                                  confidence: first.track.bestConfidence, box: first.track.box)
            tracks = []
            labelsByTrack = [:]
            changes.append(.began(current!))
        }
        guard var event = current else { return changes }
        event.end = time
        var better = false
        for s in counting {
            tracks.insert(s.track.id)
            labelsByTrack[s.track.id] = s.track.label
            // A more important category takes over; within one, a surer sighting is the better picture.
            if Self.rank(s.track.category) < Self.rank(event.category)
                || (s.track.category == event.category && s.best && s.track.bestConfidence >= event.confidence) {
                event.category = s.track.category
                event.confidence = s.track.bestConfidence
                event.box = s.track.box
                better = true
            }
        }
        event.labels = labelsByTrack.values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        event.zones = Array(Set(event.zones).union(counting.flatMap(\.track.zones))).sorted()
        current = event
        if better { changes.append(.better(event)) }
        return changes
    }

    /// No picture this time (nothing moved): the current event ends if it's been quiet long enough.
    public mutating func quiet(at time: Date) -> [Change] {
        guard current != nil, let last = lastSeen, time.timeIntervalSince(last) > endAfter else { return [] }
        return finish()
    }

    /// The current event ended (the camera stopped, or quiet).
    public mutating func finish() -> [Change] {
        guard let event = current else { return [] }
        current = nil
        tracks = []
        labelsByTrack = [:]
        return [.ended(event)]
    }

    static func rank(_ category: DetectedCategory) -> Int { important.firstIndex(of: category) ?? important.count }
}
