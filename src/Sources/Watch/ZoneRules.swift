// A camera's zones, applied: where motion counts (not in an ignored zone), and whether something found counts,
// by where it stands (the bottom middle of its box: someone's feet, a car's wheels): not in an ignored zone, and,
// once the camera has watched zones, in one of them that takes its kind. No zones: the whole picture counts.
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
        if ignored.contains(where: { $0.contains(x: x, y: y) }) { return nil }
        guard !watched.isEmpty else { return [] }
        let inside = watched.filter { $0.contains(x: x, y: y) && $0.takes(detection.category.rawValue) }
        return inside.isEmpty ? nil : Set(inside.map(\.id))
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
