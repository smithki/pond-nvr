// What happens in front of a demo camera: visits (a person up the path, a car into the driveway, a cat across the
// lawn, a courier with a box), made up from the scenario, the camera and the time alone, so the same moment always
// looks the same (in its recording, live, and from another Pond). Where each thing is at a moment is what the
// scene draws and what detection is told it found: the drawing and the boxes agree by construction.
import Detection
import Foundation
import NVRCore

/// What can come by.
enum Visitor: String, CaseIterable, Sendable {
    case person, courier, car, cyclist, cat, dog, deer

    /// Its height, against a person's at the same distance; and its width against its height.
    var height: Double {
        switch self {
        case .person, .courier, .cyclist: 1
        case .car: 0.62
        case .cat: 0.2
        case .dog: 0.32
        case .deer: 0.85
        }
    }

    var aspect: Double {
        switch self {
        case .person, .courier: 0.38
        case .cyclist: 0.7
        case .car: 2.6
        case .cat: 1.5
        case .dog: 1.5
        case .deer: 1.2
        }
    }

    /// How long a visit lasts (seconds), for one that stops and for one that passes.
    func length(stops: Bool, _ rng: inout DemoRandom) -> Double {
        switch self {
        case .person, .courier: stops ? rng.uniform(30, 70) : rng.uniform(12, 20)
        case .car: stops ? rng.uniform(25, 45) : rng.uniform(6, 10)
        case .cyclist: rng.uniform(6, 10)
        case .cat, .dog: rng.uniform(25, 80)
        case .deer: rng.uniform(40, 90)
        }
    }

    /// As a detection model names it.
    var detected: (label: String, category: DetectedCategory) {
        switch self {
        case .person, .courier: ("person", .person)
        case .car: ("car", .vehicle)
        case .cyclist: ("bicycle", .bike)
        case .cat: ("cat", .animal)
        case .dog: ("dog", .animal)
        case .deer: ("deer", .animal)
        }
    }
}

/// A way across a scene: where feet (or wheels) are, how big a person is there, where it goes and where it stops.
struct Lane: Sendable {
    /// The ground's height in the frame (from the top), and a person's height there, as fractions of the frame's.
    var y: Double
    var scale: Double
    var from: Double
    var to: Double
    /// Where a visit stops for a while (a door, a parking place); nil: it passes.
    var stop: Double?
    var visitors: [(Visitor, Int)]
    /// A doorbell's button is here: someone who stops may ring it.
    var rings = false
    /// The lane's weight among the scene's.
    var weight = 1
}

/// One visit: who, along which lane, when, for how long; which way it goes; its colour.
struct Visit: Sendable {
    var visitor: Visitor
    var lane: Int
    var start: Date
    var length: Double
    var leftward: Bool
    var hue: Double
    var rings: Bool
    /// A courier's box, left at the stop (until taken in).
    var leavesBox: Bool

    var end: Date { start.addingTimeInterval(length) }

    /// Where it is (its feet's x) at `t`, and whether it's moving.
    func position(on lane: Lane, at t: Date) -> (x: Double, moving: Bool)? {
        let p = t.timeIntervalSince(start) / length
        guard p >= 0, p <= 1 else { return nil }
        let (a, b) = leftward ? (lane.to, lane.from) : (lane.from, lane.to)
        guard let stop = lane.stop else { return (a + (b - a) * p, true) }
        // In to the stop, a pause there, then back out the way it came.
        switch p {
        case ..<0.35: return (a + (stop - a) * (p / 0.35), true)
        case ..<0.65: return (stop, false)
        default: return (stop + (a - stop) * ((p - 0.65) / 0.35), true)
        }
    }

    /// When a stopping visitor reaches the stop.
    var arrives: Date { start.addingTimeInterval(length * 0.35) }
}

/// Something in the picture: what, and where (fractions of the scene, from the top left).
struct Figure: Sendable {
    var visitor: Visitor?
    var x: Double, y: Double, width: Double, height: Double
    var moving: Bool
    var leftward: Bool
    var hue: Double
    /// A box left on the ground (no visitor).
    var isBox: Bool { visitor == nil }
    /// Seconds into its visit (for walking legs, turning wheels).
    var phase: Double
    /// A courier still carrying the box.
    var carrying = false
}

enum DemoScript {
    /// Visits are made up ten minutes at a time.
    static let block: TimeInterval = 600

    static func lanes(_ scene: Demo.Scene) -> [Lane] {
        switch scene {
        case .frontDoor, .porch:
            [Lane(y: 0.97, scale: 0.78, from: -0.25, to: 0.52, stop: 0.52, visitors: [(.person, 6), (.courier, 3)], rings: true, weight: 3),
             Lane(y: 0.45, scale: 0.13, from: -0.1, to: 1.1, stop: nil, visitors: [(.person, 3), (.car, 4), (.cyclist, 1), (.dog, 1)], weight: 4)]
        case .driveway:
            [Lane(y: 0.9, scale: 0.42, from: 1.35, to: 0.45, stop: 0.45, visitors: [(.car, 1)], weight: 2),
             Lane(y: 0.82, scale: 0.4, from: -0.15, to: 0.3, stop: 0.3, visitors: [(.person, 3), (.courier, 1)], weight: 2),
             Lane(y: 0.44, scale: 0.12, from: -0.1, to: 1.1, stop: nil, visitors: [(.car, 5), (.person, 2), (.cyclist, 1)], weight: 4)]
        case .backyard, .shed:
            [Lane(y: 0.82, scale: 0.42, from: -0.15, to: 1.15, stop: nil, visitors: [(.cat, 3), (.dog, 2), (.deer, 1)], weight: 3),
             Lane(y: 0.72, scale: 0.36, from: 1.15, to: 0.62, stop: 0.62, visitors: [(.person, 2), (.deer, 1)], weight: 1)]
        case .garage:
            [Lane(y: 0.92, scale: 0.5, from: 1.4, to: 0.5, stop: 0.5, visitors: [(.car, 1)], weight: 1),
             Lane(y: 0.9, scale: 0.55, from: -0.15, to: 0.7, stop: 0.7, visitors: [(.person, 3)], weight: 2)]
        case .livingRoom:
            [Lane(y: 0.9, scale: 0.7, from: -0.2, to: 1.2, stop: nil, visitors: [(.person, 2), (.cat, 3), (.dog, 1)], weight: 1)]
        case .sideGate:
            [Lane(y: 0.95, scale: 0.75, from: 1.2, to: 0.35, stop: 0.35, visitors: [(.person, 2), (.cat, 2)], weight: 1)]
        case .street:
            [Lane(y: 0.7, scale: 0.3, from: -0.2, to: 1.2, stop: nil, visitors: [(.car, 6), (.cyclist, 2)], weight: 3),
             Lane(y: 0.86, scale: 0.42, from: -0.15, to: 1.15, stop: nil, visitors: [(.person, 4), (.dog, 1)], weight: 2)]
        case .dock:
            [Lane(y: 0.9, scale: 0.55, from: -0.15, to: 0.6, stop: 0.6, visitors: [(.person, 3), (.dog, 1)], weight: 1),
             Lane(y: 0.62, scale: 0.2, from: -0.1, to: 1.1, stop: nil, visitors: [(.deer, 1), (.person, 1)], weight: 1)]
        }
    }

    /// The visits of one ten-minute block.
    static func visits(scenario: String, camera: String, scene: Demo.Scene, busyness: Double, block index: Int64) -> [Visit] {
        let lanes = lanes(scene)
        guard !lanes.isEmpty else { return [] }
        var rng = DemoRandom(seed: "\(scenario)/\(camera)/\(index)")
        let start = Date(timeIntervalSince1970: Double(index) * block)
        // Quieter at night (fewer by a third between 23:00 and 06:00).
        let hour = Calendar.current.component(.hour, from: start)
        let rate = busyness * (hour >= 23 || hour < 6 ? 0.33 : 1) / 6
        var count = 0
        while rng.uniform(0, 1) < rate / Double(count + 1) * 1.6, count < 6 { count += 1 }
        var out: [Visit] = []
        for _ in 0 ..< count {
            let laneIndex = rng.pick(lanes.indices.map { ($0, lanes[$0].weight) })
            let lane = lanes[laneIndex]
            let visitor = rng.pick(lane.visitors)
            let length = visitor.length(stops: lane.stop != nil, &rng)
            let at = start.addingTimeInterval(rng.uniform(0, block - 20))
            // Not two at once in a lane (they'd walk through each other).
            guard !out.contains(where: { $0.lane == laneIndex && $0.start < at.addingTimeInterval(length) && at < $0.end }) else { continue }
            let stops = lane.stop != nil
            out.append(Visit(visitor: visitor, lane: laneIndex, start: at, length: length,
                             leftward: !stops && rng.uniform(0, 1) < 0.5, hue: rng.uniform(0, 1),
                             rings: lane.rings && (visitor == .courier || rng.uniform(0, 1) < 0.4),
                             leavesBox: visitor == .courier && lane.stop != nil))
        }
        return out
    }

    /// How long a courier's box stays at the door.
    static let boxStays: TimeInterval = 20 * 60

    /// Every visit that could matter at `t` (in its block, the one before, and those whose boxes may still be there).
    static func visits(scenario: String, camera: Demo.Camera, busyness: Double, around t: Date) -> [Visit] {
        let index = Int64((t.timeIntervalSince1970 / block).rounded(.down))
        let back = Int64(boxStays / block) + 1
        return (index - back ... index).flatMap {
            visits(scenario: scenario, camera: camera.id, scene: camera.scene, busyness: busyness, block: $0)
        }
    }

    /// What's in the scene at `t`: the visitors there now, and boxes left.
    static func figures(scenario: String, camera: Demo.Camera, busyness: Double, at t: Date) -> [Figure] {
        let lanes = lanes(camera.scene)
        var out: [Figure] = []
        for visit in visits(scenario: scenario, camera: camera, busyness: busyness, around: t) {
            let lane = lanes[visit.lane]
            if visit.leavesBox, let stop = lane.stop, t >= visit.arrives.addingTimeInterval(visit.length * 0.15),
               t < visit.arrives.addingTimeInterval(boxStays) {
                let side = lane.scale * 0.16
                out.append(Figure(visitor: nil, x: stop + lane.scale * 0.22, y: lane.y - side, width: side * 1.3, height: side,
                                  moving: false, leftward: false, hue: 0.08, phase: 0))
            }
            guard let (x, moving) = visit.position(on: lane, at: t) else { continue }
            let height = lane.scale * visit.visitor.height
            let width = height * visit.visitor.aspect
            // A stopped visitor's facing is where it'll go next.
            let leaving = t > visit.start.addingTimeInterval(visit.length * 0.5)
            let leftward = lane.stop == nil ? visit.leftward : leaving == (lane.from < lane.to)
            out.append(Figure(visitor: visit.visitor, x: x - width / 2, y: lane.y - height, width: width, height: height,
                              moving: moving, leftward: leftward, hue: visit.hue, phase: t.timeIntervalSince(visit.start),
                              carrying: visit.leavesBox && t < visit.arrives.addingTimeInterval(visit.length * 0.15)))
        }
        // Far ones first, so near ones are drawn over them.
        return out.sorted { $0.y + $0.height < $1.y + $1.height }
    }

    /// The doorbell's presses between two moments.
    static func rings(scenario: String, camera: Demo.Camera, busyness: Double, from a: Date, to b: Date) -> [Date] {
        visits(scenario: scenario, camera: camera, busyness: busyness, around: b)
            .filter(\.rings).map { $0.arrives.addingTimeInterval(2) }.filter { $0 > a && $0 <= b }
    }
}

/// A small deterministic random generator (SplitMix64), seeded from words.
struct DemoRandom {
    var state: UInt64

    init(seed: String) {
        // FNV-1a.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        state = hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(next() >> 11) / Double(1 << 53)
    }

    mutating func pick<T>(_ weighted: [(T, Int)]) -> T {
        let total = weighted.reduce(0) { $0 + $1.1 }
        var n = Int(next() % UInt64(max(1, total)))
        for (value, weight) in weighted {
            if n < weight { return value }
            n -= weight
        }
        return weighted[0].0
    }
}
