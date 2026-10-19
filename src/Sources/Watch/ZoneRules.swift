// A camera's zones, applied: where motion counts (not in an ignored zone), and whether something found counts:
// not in an ignored zone (where it stands, or most of it: a person on a TV is cut off at the screen's edge, so
// where it "stands" can be just outside the zone drawn round the screen), and, once the camera has watched zones,
// standing in one that takes its kind (the bottom middle of its box: someone's feet, a car's wheels). No zones:
// the whole picture counts.
import Detection
import Foundation
import NVRCore

public struct ZoneRules: Sendable {
    public let zones: [Config.Zone]
    private let ignored: [Config.Zone]
    private let watched: [Config.Zone]

    public init(_ zones: [Config.Zone]) {
        self.zones = zones
        ignored = zones.filter(\.isIgnored)
        watched = zones.filter { !$0.isIgnored }
    }

    public var isEmpty: Bool { zones.isEmpty }

    /// Where something in this box stands.
    public static func anchor(_ box: Detection.Box) -> (x: Double, y: Double) {
        (box.x + box.width / 2, min(1, box.y + box.height))
    }

    /// The watched zones a detection is in (empty for a camera with none); nil if it doesn't count.
    public func zones(for detection: Detection) -> Set<String>? {
        let (x, y) = Self.anchor(detection.box)
        if ignored.contains(where: { $0.contains(x: x, y: y) || Self.share(of: detection.box, in: $0) >= Self.mostly }) { return nil }
        guard !watched.isEmpty else { return [] }
        let inside = watched.filter { $0.contains(x: x, y: y) && $0.takes(detection.category.zoneCategory) }
        return inside.isEmpty ? nil : Set(inside.map(\.id))
    }

    /// In an ignored zone when this much of it is: a person on a screen is nearly all inside the zone round it;
    /// someone standing in front of the screen, their head before it and their feet on the floor below, much less.
    static let mostly = 0.75

    /// How much of a box is in a zone (sampled on a 6×6 grid).
    static func share(of box: Detection.Box, in zone: Config.Zone) -> Double {
        let n = 6
        var inside = 0
        for i in 0 ..< n {
            for j in 0 ..< n where zone.contains(x: box.x + (Double(i) + 0.5) / Double(n) * box.width,
                                                y: box.y + (Double(j) + 0.5) / Double(n) * box.height) {
                inside += 1
            }
        }
        return Double(inside) / Double(n * n)
    }

    /// The grid cells (row by row) whose middle is in an ignored zone: motion there doesn't count.
    public func ignoredCells(columns: Int, rows: Int) -> Set<Int> {
        guard !ignored.isEmpty else { return [] }
        var out = Set<Int>()
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let x = (Double(column) + 0.5) / Double(columns), y = (Double(row) + 0.5) / Double(rows)
                if ignored.contains(where: { $0.contains(x: x, y: y) }) { out.insert(row * columns + column) }
            }
        }
        return out
    }
}
