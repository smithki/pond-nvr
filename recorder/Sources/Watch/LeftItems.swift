// Things left behind: an item (a bag, a suitcase, an umbrella; whatever the model calls one) that is put down
// and stays. It's watched for from when it's first seen where something moved (being put down); if it's still
// there a while later, in the same place, with nobody holding it, it's an event of its own. One already there
// (never seen arriving) is never one, nor one carried past or picked up again. Once told, it isn't again while
// it stays. Packages come later, with a model that knows them; this works with whatever items the model finds.
import Detection
import Foundation

public struct LeftItems: Sendable {
    public let camera: String
    /// Still there this long after it was put down: left.
    public var leftAfter: TimeInterval = 30
    /// Looked for again this often while one is waiting (nothing need move for it to be still there).
    public var lookEvery: TimeInterval = 5
    /// Unseen this long while waiting: taken away again.
    public var goneAfter: TimeInterval = 12
    /// A left item unseen this long is forgotten (it can be left again).
    public var forgetAfter: TimeInterval = 600
    /// The same place: boxes overlapping this much.
    public var samePlace = 0.4

    struct Item: Sendable {
        var label: String
        var box: Detection.Box
        var arrived: Date
        var lastSeen: Date
        var confidence: Double
        var zones: Set<String>
    }

    private var waiting: [Item] = []
    private var left: [Item] = []

    public init(camera: String) { self.camera = camera }

    /// Whether an item is waiting to be seen again (so the model is to be run though nothing moves).
    public var isWaiting: Bool { !waiting.isEmpty }

    /// One picture's findings: its items (each with the zones it's in, and whether something moved there), and
    /// the people in it. Returns the items now left.
    public mutating func update(_ items: [(detection: Detection, zones: Set<String>, moved: Bool)], people: [Detection],
                                at time: Date) -> [CameraEvent] {
        for (d, zones, moved) in items {
            if let i = left.firstIndex(where: { $0.box.overlap(d.box) >= samePlace }) {
                left[i].lastSeen = time
            } else if let i = waiting.firstIndex(where: { $0.box.overlap(d.box) >= samePlace }) {
                waiting[i].lastSeen = time
                waiting[i].box = d.box
                if d.confidence > waiting[i].confidence {
                    waiting[i].confidence = d.confidence
                    waiting[i].label = d.label
                }
                waiting[i].zones.formUnion(zones)
            } else if moved {
                waiting.append(Item(label: d.label, box: d.box, arrived: time, lastSeen: time, confidence: d.confidence, zones: zones))
            }
        }
        waiting.removeAll { time.timeIntervalSince($0.lastSeen) > goneAfter }
        left.removeAll { time.timeIntervalSince($0.lastSeen) > forgetAfter }
        var out: [CameraEvent] = []
        waiting.removeAll { item in
            // Seen just now, there long enough, and not in someone's hands (nobody standing over it).
            guard item.lastSeen == time, time.timeIntervalSince(item.arrived) >= leftAfter,
                  !people.contains(where: { $0.box.overlap(item.box) > 0 || Self.covers($0.box, item.box) }) else { return false }
            left.append(item)
            out.append(CameraEvent(camera: camera, start: item.arrived, end: time, category: .item, labels: [item.label: 1],
                                   confidence: item.confidence, box: item.box, zones: item.zones.sorted()))
            return true
        }
        return out
    }

    /// Whether `outer` holds the middle of `inner` (a bag on someone's back sits inside their box).
    static func covers(_ outer: Detection.Box, _ inner: Detection.Box) -> Bool {
        let x = inner.x + inner.width / 2, y = inner.y + inner.height / 2
        return x >= outer.x && x <= outer.x + outer.width && y >= outer.y && y <= outer.y + outer.height
    }
}
