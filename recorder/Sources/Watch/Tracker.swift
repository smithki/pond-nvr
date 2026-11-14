// What's found in a camera's pictures, followed from one to the next: each detection matched to the track it
// overlaps most (the same category, enough overlap), else a new track. A track that isn't seen for a while is
// let go. So one person walking past is one track, however many pictures they're in.
// A track moves when it's where the picture changed and it has itself moved: its box gone a tenth of its size from
// where it last moved, or grown or shrunk by a sixth (coming nearer, going away). The picture changing over it
// alone isn't enough: at night a parked car's picture flickers all the time (the camera's noise, its infrared,
// passing headlights), and it kept an event going for hours while it never went anywhere.
// A thing that's stayed put a while is parked, and then only going somewhere counts: its box (where it steadily is,
// the middle of its last few) gone half its size, or half as big again or smaller. A detector's box round a parked car
// at night is far from steady (a sixth wider or narrower from one look to the next, now and then only half of it
// found), and each flicker, moving it by the rule above, took up its event again: one parked car, one event all
// night. Pulling away, it's gone half its size in a moment.
// And a parked thing lost from sight a moment (headlights over it, someone in front) and found again is still parked:
// where it was is remembered a while, and the same kind found there again takes up being parked rather than
// beginning as something new (found again as new, it began a new event, there, for hours).
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
    /// Where it was when it last moved (or was first seen): moving is going far enough from here.
    public var settled: Detection.Box
    /// Its last few boxes, the newest last: where it steadily is is their middle (`Tracker.steady`).
    public var recent: [Detection.Box] = []
    /// Where it steadily was when it last really went somewhere (by its steady box, not each one), and when.
    public var steadyFrom: Detection.Box? = nil
    public var reallyMoved: Date? = nil
    /// Still long enough to be parked: only going somewhere moves it now.
    public var parked = false
    /// Since when it's been on the move: first seen, or, parked, since it set off again (an event it begins starts
    /// then, not when it was first seen, maybe an hour before, sitting there).
    public var activeSince: Date? = nil
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
    /// Moving: its middle this far (of its size) from where it last moved, or its size changed by this much.
    public var movedBy: Double = 0.1
    public var resizedBy: Double = 1.0 / 6
    /// Unseen this long, a track is let go (longer than the watcher's looks while nothing moves).
    public var forgetAfter: TimeInterval = 5
    /// Its steady box not gone anywhere this long (by the rule for moving), a track's parked.
    public var parkAfter: TimeInterval = 60
    /// Parked, moving is its steady box going this far (of its size), or its size changing by this much.
    public var parkedMovedBy: Double = 0.5
    public var parkedResizedBy: Double = 0.5
    /// Boxes in where a thing steadily is: to tell it's parked, and, parked, whether it's gone.
    public var steadyOver = 9
    public var parkedSteadyOver = 5
    /// A parked track lost from sight: where it was, remembered this long, for it to be found there again.
    public var rememberParked: TimeInterval = 1800
    /// Where parked things were when they were lost from sight, and till when they're remembered.
    public private(set) var parkedSpots: [(category: DetectedCategory, box: Detection.Box, until: Date)] = []
    public private(set) var tracks: [Track] = []
    private var nextID = 1

    public init() {}

    /// Whether anything that makes events is being followed (so the watcher keeps looking though nothing moves).
    public func following(_ categories: [DetectedCategory]) -> Bool { tracks.contains { categories.contains($0.category) } }

    /// This picture's detections taken in (each with the watched zones it's in); returns the tracks they continued
    /// or started, and whether each is the track's surest sighting so far (for its event's picture).
    public mutating func update(_ detections: [Detection], mask: MotionMask, at time: Date,
                                zones: (Detection) -> Set<String> = { _ in [] }) -> [(track: Track, best: Bool)] {
        // (Parked ones let go remembered, where they were; those long gone forgotten.)
        for track in tracks where track.parked && time.timeIntervalSince(track.lastSeen) > forgetAfter {
            parkedSpots.append((track.category, track.settled, time.addingTimeInterval(rememberParked)))
        }
        tracks.removeAll { time.timeIntervalSince($0.lastSeen) > forgetAfter }
        parkedSpots.removeAll { $0.until < time }
        var used = Set<Int>()
        var out: [(Track, Bool)] = []
        for d in detections.sorted(by: { $0.confidence > $1.confidence }) {
            let changed = mask.overlaps((d.box.x, d.box.y, d.box.width, d.box.height))
            let match = tracks.indices
                .filter { !used.contains($0) && tracks[$0].category == d.category }
                .map { ($0, tracks[$0].box.overlap(d.box)) }
                .filter { $0.1 >= minimumOverlap }
                .max { $0.1 < $1.1 }
            if let (i, _) = match {
                used.insert(i)
                tracks[i].recent.append(d.box)
                if tracks[i].recent.count > steadyOver { tracks[i].recent.removeFirst() }
                let moved: Bool
                if !tracks[i].parked {
                    // (Where the picture changed, and gone somewhere itself.)
                    moved = changed && Self.went(from: tracks[i].settled, to: d.box, by: movedBy, resized: resizedBy)
                    if moved { tracks[i].settled = d.box }
                    // Really gone anywhere lately (where it steadily is, not one box)? Not for a while: parked.
                    let steady = Self.steady(tracks[i].recent)
                    if Self.went(from: tracks[i].steadyFrom ?? steady, to: steady, by: movedBy, resized: resizedBy) {
                        tracks[i].steadyFrom = steady
                        tracks[i].reallyMoved = time
                    }
                    if time.timeIntervalSince(tracks[i].reallyMoved ?? time) > parkAfter {
                        tracks[i].parked = true
                        tracks[i].settled = Self.steady(Array(tracks[i].recent.suffix(parkedSteadyOver)))
                    }
                } else {
                    // Parked: only going somewhere, where it steadily is, half its size or more.
                    let steady = Self.steady(Array(tracks[i].recent.suffix(parkedSteadyOver)))
                    moved = changed && Self.went(from: tracks[i].settled, to: steady, by: parkedMovedBy, resized: parkedResizedBy)
                    if moved {
                        tracks[i].parked = false
                        tracks[i].activeSince = time
                        tracks[i].settled = d.box
                        tracks[i].steadyFrom = steady
                        tracks[i].reallyMoved = time
                    }
                }
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
            } else if let spot = parkedSpots.firstIndex(where: { $0.category == d.category && Duplicates.sameThing($0.box, d.box) }) {
                // Where a parked one was lost: it, found again, still parked (not something new, moving).
                let was = parkedSpots.remove(at: spot).box
                let track = Track(id: nextID, category: d.category, label: d.label, box: d.box, firstSeen: time, lastSeen: time,
                                  seen: 1, moved: false, lastMoved: nil, settled: was, recent: [d.box], steadyFrom: was,
                                  reallyMoved: time, parked: true, bestConfidence: d.confidence, zones: zones(d),
                                  votes: [d.label: d.confidence])
                nextID += 1
                tracks.append(track)
                used.insert(tracks.count - 1)
                out.append((track, true))
            } else {
                let track = Track(id: nextID, category: d.category, label: d.label, box: d.box, firstSeen: time, lastSeen: time,
                                  seen: 1, moved: changed, lastMoved: changed ? time : nil, settled: d.box, recent: [d.box],
                                  steadyFrom: d.box, reallyMoved: time, bestConfidence: d.confidence, zones: zones(d),
                                  votes: [d.label: d.confidence])
                nextID += 1
                tracks.append(track)
                used.insert(tracks.count - 1)
                out.append((track, true))
            }
        }
        return out
    }

    /// Where a thing steadily is, from its last few boxes: each side's median (one flicker, or one found in part,
    /// moves it nowhere; a few in a row, going somewhere, do).
    static func steady(_ boxes: [Detection.Box]) -> Detection.Box {
        guard boxes.count > 2 else { return boxes.last ?? Detection.Box(x: 0, y: 0, width: 0, height: 0) }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let n = sorted.count
            return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }
        return Detection.Box(x: median(boxes.map(\.x)), y: median(boxes.map(\.y)),
                             width: median(boxes.map(\.width)), height: median(boxes.map(\.height)))
    }

    /// Whether a box has gone from where it was: its middle by `by` of its size (the larger side), or its size by
    /// `resized` (either way).
    static func went(from a: Detection.Box, to b: Detection.Box, by: Double, resized: Double) -> Bool {
        let size = max(a.width, a.height, 1e-6)
        let dx = (b.x + b.width / 2) - (a.x + a.width / 2), dy = (b.y + b.height / 2) - (a.y + a.height / 2)
        if (dx * dx + dy * dy).squareRoot() > by * size { return true }
        let ratio = b.area / max(a.area, 1e-9)
        return ratio > 1 + resized || ratio < 1 / (1 + resized)
    }
}
