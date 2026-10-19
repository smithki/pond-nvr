// What's found in a camera's pictures, followed from one to the next: each detection matched to the track it
// overlaps most (the same category, enough overlap), else a new track. A track that isn't seen for a while is
// let go. So one person walking past is one track, however many pictures they're in.
import Detection
import Foundation

public struct Track: Sendable, Equatable {
    public let id: Int
    public let category: DetectedCategory
    public var label: String
    public var box: Detection.Box
    public let firstSeen: Date
    public var lastSeen: Date
    /// Times seen (pictures it was found in).
    public var seen: Int
    /// Seen where something moved, at least once: it's live, not a parked car.
    public var moved: Bool
    /// When it was last seen where something moved.
    public var lastMoved: Date?
    public var bestConfidence: Double
    /// The watched zones it has been in.
    public var zones: Set<String> = []
    /// What the model has called it, each word with its confidence summed: `label` is the most (a cat the model
    /// sometimes calls a dog stays a cat).
    public var votes: [String: Double] = [:]
}

/// One thing found twice in a picture let go: an end-to-end model (no suppression of its own) can find a person
/// whole and again in part (their top half above a lamp), as two boxes of the same kind, one mostly inside the
/// other. The surer of the two is kept.
public enum Duplicates {
    /// Of the smaller box, this much inside the larger: the same thing.
    public static let inside = 0.6

    public static func merged(_ detections: [Detection]) -> [Detection] {
        var kept: [Detection] = []
        for d in detections.sorted(by: { $0.confidence > $1.confidence }) {
            if !kept.contains(where: { $0.category == d.category && Self.sameThing($0.box, d.box) }) { kept.append(d) }
        }
        return kept
    }

    static func sameThing(_ a: Detection.Box, _ b: Detection.Box) -> Bool {
        let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        guard w > 0, h > 0 else { return false }
        return w * h / max(1e-9, min(a.area, b.area)) >= inside
    }
}

public struct Tracker: Sendable {
    /// Overlap (intersection over union) for a detection to continue a track.
    public var minimumOverlap: Double = 0.2
    /// Unseen this long, a track is let go (longer than the watcher's looks while nothing moves).
    public var forgetAfter: TimeInterval = 5
    public private(set) var tracks: [Track] = []
    private var nextID = 1

    public init() {}

    /// Whether anything that makes events is being followed (so the watcher keeps looking though nothing moves).
    public func following(_ categories: [DetectedCategory]) -> Bool { tracks.contains { categories.contains($0.category) } }

    /// This picture's detections taken in (each with the watched zones it's in); returns the tracks they continued
    /// or started, and whether each is the track's surest sighting so far (for its event's picture).
    public mutating func update(_ detections: [Detection], mask: MotionMask, at time: Date,
                                zones: (Detection) -> Set<String> = { _ in [] }) -> [(track: Track, best: Bool)] {
        tracks.removeAll { time.timeIntervalSince($0.lastSeen) > forgetAfter }
        var used = Set<Int>()
        var out: [(Track, Bool)] = []
        for d in detections.sorted(by: { $0.confidence > $1.confidence }) {
            let moved = mask.overlaps((d.box.x, d.box.y, d.box.width, d.box.height))
            let match = tracks.indices
                .filter { !used.contains($0) && tracks[$0].category == d.category }
                .map { ($0, tracks[$0].box.overlap(d.box)) }
                .filter { $0.1 >= minimumOverlap }
                .max { $0.1 < $1.1 }
            if let (i, _) = match {
                used.insert(i)
                let best = d.confidence > tracks[i].bestConfidence
                tracks[i].box = d.box
                tracks[i].votes[d.label, default: 0] += d.confidence
                tracks[i].label = tracks[i].votes.max { $0.value < $1.value }?.key ?? d.label
                tracks[i].lastSeen = time
                tracks[i].seen += 1
                tracks[i].moved = tracks[i].moved || moved
                if moved { tracks[i].lastMoved = time }
                if best { tracks[i].bestConfidence = d.confidence }
                tracks[i].zones.formUnion(zones(d))
                out.append((tracks[i], best))
            } else {
                let track = Track(id: nextID, category: d.category, label: d.label, box: d.box, firstSeen: time, lastSeen: time,
                                  seen: 1, moved: moved, lastMoved: moved ? time : nil, bestConfidence: d.confidence,
                                  zones: zones(d), votes: [d.label: d.confidence])
                nextID += 1
                tracks.append(track)
                used.insert(tracks.count - 1)
                out.append((track, true))
            }
        }
        return out
    }
}
