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
    public var bestConfidence: Double
    /// The watched zones it has been in.
    public var zones: Set<String> = []
}

public struct Tracker: Sendable {
    /// Overlap (intersection over union) for a detection to continue a track.
    public var minimumOverlap: Double = 0.2
    /// Unseen this long, a track is let go.
    public var forgetAfter: TimeInterval = 3
    public private(set) var tracks: [Track] = []
    private var nextID = 1

    public init() {}

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
                tracks[i].label = d.label
                tracks[i].lastSeen = time
                tracks[i].seen += 1
                tracks[i].moved = tracks[i].moved || moved
                if best { tracks[i].bestConfidence = d.confidence }
                tracks[i].zones.formUnion(zones(d))
                out.append((tracks[i], best))
            } else {
                let track = Track(id: nextID, category: d.category, label: d.label, box: d.box, firstSeen: time, lastSeen: time,
                                  seen: 1, moved: moved, bestConfidence: d.confidence, zones: zones(d))
                nextID += 1
                tracks.append(track)
                used.insert(tracks.count - 1)
                out.append((track, true))
            }
        }
        return out
    }
}
