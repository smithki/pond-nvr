// Events on the timeline. Detection (phase 5) will supply them; until then, POND_MOCK_EVENTS=1 makes up a
// plausible day of them over what was recorded, to try the timeline with.
import Foundation
import SwiftUI

struct TimelineEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case person, vehicle, animal, package, motion

        var id: String { rawValue }

        var title: String {
            switch self {
            case .person: "Person"
            case .vehicle: "Vehicle"
            case .animal: "Animal"
            case .package: "Package"
            case .motion: "Motion"
            }
        }

        var symbol: String {
            switch self {
            case .person: "figure.walk"
            case .vehicle: "car.fill"
            case .animal: "pawprint.fill"
            case .package: "shippingbox.fill"
            case .motion: "dot.radiowaves.left.and.right"
            }
        }

        var color: Color {
            switch self {
            case .person: .blue
            case .vehicle: .orange
            case .animal: .green
            case .package: .yellow
            case .motion: .gray
            }
        }
    }

    var id: Int
    var camera: String
    var kind: Kind
    var start: Date
    var end: Date
    /// What the description model would say about it.
    var summary: String

    var seconds: Double { end.timeIntervalSince(start) }
}

enum MockEvents {
    static var enabled: Bool { ProcessInfo.processInfo.environment["POND_MOCK_EVENTS"] == "1" }

    /// Events scattered over each camera's recorded stretches, the same every time for the same day.
    static func make(coverage: [String: [ClosedRange<Date>]], day: Date) -> [TimelineEvent] {
        var out: [TimelineEvent] = []
        for camera in coverage.keys.sorted() {
            var rng = Generator(seed: UInt64(day.timeIntervalSince1970) &+ UInt64(camera.unicodeScalars.reduce(0) { $0 &* 31 &+ UInt64($1.value) }))
            for range in coverage[camera] ?? [] {
                var t = range.lowerBound.addingTimeInterval(rng.uniform(60, 600))
                while t < range.upperBound.addingTimeInterval(-30) {
                    let kind = rng.pick([(.person, 30), (.vehicle, 18), (.animal, 10), (.package, 4), (.motion, 38)] as [(TimelineEvent.Kind, Int)])
                    let length = kind == .motion ? rng.uniform(5, 25) : rng.uniform(10, 95)
                    let end = min(t.addingTimeInterval(length), range.upperBound)
                    out.append(TimelineEvent(id: out.count, camera: camera, kind: kind, start: t, end: end,
                                             summary: summary(kind, &rng)))
                    t = end.addingTimeInterval(rng.uniform(90, 1100))
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func summary(_ kind: TimelineEvent.Kind, _ rng: inout Generator) -> String {
        let options: [String]
        switch kind {
        case .person: options = ["A person walks up the path and leaves.", "A person in a dark jacket crosses the yard.",
                                  "Two people stop at the door, then leave.", "A neighbour walks a dog past."]
        case .vehicle: options = ["A white van pulls into the driveway.", "A car passes on the street.",
                                  "A delivery truck stops in front of the house.", "A grey SUV backs out of the driveway."]
        case .animal: options = ["A cat crosses the lawn.", "A dog sniffs around the porch.", "A deer walks along the fence."]
        case .package: options = ["A courier leaves a box at the door.", "A package is picked up from the porch."]
        case .motion: options = ["Movement in the trees.", "Headlights sweep across the frame.", "Shadows move as clouds pass."]
        }
        return options[Int(rng.next() % UInt64(options.count))]
    }

    /// A small deterministic random generator (SplitMix64).
    struct Generator {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func uniform(_ low: Double, _ high: Double) -> Double {
            low + Double(next() % 1_000_000) / 1_000_000 * (high - low)
        }

        mutating func pick<T>(_ weighted: [(T, Int)]) -> T {
            var n = Int(next() % UInt64(weighted.reduce(0) { $0 + $1.1 }))
            for (value, weight) in weighted {
                if n < weight { return value }
                n -= weight
            }
            return weighted[0].0
        }
    }
}
