// Events on the timeline: what the service's detection kept (read from Pond's database), and when each camera
// was private (from its health). POND_MOCK_EVENTS=1 makes up a plausible day of events instead, to try the
// timeline with.
import Detection
import Foundation
import Health
import NVRCore
import SwiftUI
import Watch

struct TimelineEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case person, vehicle, bike, animal, package, item, ring, motion
        /// Not an event: a private stretch, as the hover card shows it.
        case privacy

        var id: String { rawValue }

        /// Which leads where several kinds are together (its colour and symbol first): a ring, someone, then
        /// what they came in, animals, and what was left.
        static let prominence: [Kind] = [.ring, .person, .bike, .vehicle, .animal, .package, .item, .motion, .privacy]
        var prominence: Int { Self.prominence.firstIndex(of: self) ?? Self.prominence.count }

        init(_ category: DetectedCategory) {
            switch category {
            case .person: self = .person
            case .vehicle: self = .vehicle
            case .bike: self = .bike
            case .animal: self = .animal
            case .package: self = .package
            case .item: self = .item
            case .ring: self = .ring
            case .other: self = .motion
            }
        }

        var title: String {
            switch self {
            case .person: "Person"
            case .vehicle: "Vehicle"
            case .bike: "Bike"
            case .animal: "Animal"
            case .package: "Package"
            case .item: "Left item"
            case .ring: "Doorbell"
            case .motion: "Motion"
            case .privacy: "Private"
            }
        }

        var symbol: String {
            switch self {
            case .person: "figure.walk"
            case .vehicle: "car.fill"
            case .bike: "bicycle"
            case .animal: "pawprint.fill"
            case .package: "shippingbox.fill"
            case .item: "bag.fill"
            case .ring: "bell.fill"
            case .motion: "dot.radiowaves.left.and.right"
            case .privacy: "eye.slash.fill"
            }
        }

        var color: Color {
            switch self {
            case .person: .blue
            case .vehicle: .orange
            case .bike: .mint
            case .animal: .green
            case .package: .brown
            case .item: .teal
            case .ring: .yellow
            case .motion: .gray
            case .privacy: .indigo
            }
        }
    }

    var id: String
    var camera: String
    var kind: Kind
    var start: Date
    var end: Date
    /// What happened, in a sentence.
    var summary: String
    /// Its picture, if it has one.
    var snapshot: URL?
    /// Still going on (as last read): drawn up to the present.
    var ongoing = false
    /// Where its subject was in its picture (fractions), for a box on it.
    var box: Detection.Box?
    /// How sure the model was of its subject, at best.
    var confidence: Double?
    /// What was seen in it, by the model's words: the most of each at once.
    var labels: [String: Int] = [:]
    /// The watched zones it was in, by name.
    var zones: [String] = []

    var seconds: Double { end.timeIntervalSince(start) }
}

/// One camera's events by start, with the longest's length: those in a stretch of time are found by search
/// (from as far back as the longest could start and still reach into it), not by looking at every one.
struct EventIndex: Sendable {
    let events: [TimelineEvent]
    let longest: TimeInterval

    init(_ events: [TimelineEvent]) {
        self.events = events.sorted { $0.start < $1.start }
        longest = events.map(\.seconds).max() ?? 0
    }

    /// Those overlapping `range`, by start.
    func overlapping(_ range: ClosedRange<Date>) -> [TimelineEvent] {
        let from = first { $0.start >= range.lowerBound.addingTimeInterval(-longest) }
        let to = first { $0.start > range.upperBound }
        return events[from ..< to].filter { $0.end > range.lowerBound }
    }

    /// The index of the first event that `isAfter` (they're in order of start).
    private func first(_ isAfter: (TimelineEvent) -> Bool) -> Int {
        var low = 0, high = events.count
        while low < high {
            let mid = (low + high) / 2
            if isAfter(events[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

/// Where the app reads events and private stretches from (the settings' database and events folder).
struct EventSource: Sendable {
    var database: String
    var eventsFolder: String
    /// Zone names, by "camera/zone".
    var zoneNames: [String: String] = [:]

    init(database: String, eventsFolder: String, zoneNames: [String: String] = [:]) {
        self.database = database
        self.eventsFolder = eventsFolder
        self.zoneNames = zoneNames
    }

    init?(config: Config?) {
        guard let config else { return nil }
        self.init(database: config.storage.databasePath, eventsFolder: config.storage.eventsPath,
                  zoneNames: Dictionary(config.cameras.flatMap { c in c.zones.map { ("\(c.id)/\($0.id)", $0.name) } },
                                        uniquingKeysWith: { a, _ in a }))
    }

    /// The events begun within `from`…`to`, oldest first; the one going on now ends now.
    func events(from: Date, to: Date, now: Date = Date()) -> [TimelineEvent] {
        guard FileManager.default.fileExists(atPath: database), let store = EventStore(path: database, readOnly: true) else { return [] }
        return store.events(since: from).filter { $0.event.start < to }.map { kept in
            let e = kept.event
            return TimelineEvent(id: e.id, camera: e.camera, kind: .init(e.category), start: e.start,
                                 end: kept.ongoing ? max(e.end, now) : max(e.end, e.start.addingTimeInterval(1)),
                                 summary: summary(e), snapshot: e.snapshot.map { URL(fileURLWithPath: (eventsFolder as NSString).appendingPathComponent($0)) },
                                 ongoing: kept.ongoing, box: e.box,
                                 confidence: e.category == .ring ? nil : e.confidence,
                                 labels: e.category == .ring ? [:] : e.labels,
                                 zones: e.zones.map { zoneNames["\(e.camera)/\($0)"] ?? $0 })
        }
    }

    /// Deleted, with their pictures (the recordings they were in, and what was found in them, are kept).
    func delete(_ ids: [String]) {
        guard FileManager.default.fileExists(atPath: database), let store = EventStore(path: database) else { return }
        for picture in store.delete(ids) {
            try? FileManager.default.removeItem(atPath: (eventsFolder as NSString).appendingPathComponent(picture))
        }
    }

    /// A camera's events and what was found in its pictures, all deleted (its pictures go with its folders).
    func deleteCamera(_ camera: String) {
        guard FileManager.default.fileExists(atPath: database), let store = EventStore(path: database) else { return }
        store.deleteCamera(camera)
    }

    /// What the service found in a camera's pictures within `from`…`to` (for boxes over the recording).
    func sightings(camera: String, from: Date, to: Date) -> [Sighting] {
        guard FileManager.default.fileExists(atPath: database), let store = EventStore(path: database, readOnly: true) else { return [] }
        return store.sightings(camera: camera, from: from, to: to)
    }

    /// When each camera was private within `from`…`to`.
    func privateSpans(from: Date, to: Date) -> [String: [ClosedRange<Date>]] {
        guard FileManager.default.fileExists(atPath: database), let store = HealthStore(path: database, readOnly: true) else { return [:] }
        return store.privateSpans(from: from, to: to)
    }

    /// "A person and a dog, in Path." "A backpack left." "Doorbell pressed."
    func summary(_ e: CameraEvent) -> String {
        if e.category == .ring { return "Doorbell pressed." }
        let things = Self.list(e.labels)
        if e.category == .item { return Self.sentence("\(things) left") }
        let zones = e.zones.map { zoneNames["\(e.camera)/\($0)"] ?? $0 }
        return Self.sentence(things + (zones.isEmpty ? "" : ", in " + Self.join(zones)))
    }

    static func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() + "." }

    static func list(_ labels: [String: Int]) -> String { CameraEvent.words(labels) }

    static func join(_ parts: [String]) -> String { CameraEvent.join(parts) }
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
                    out.append(TimelineEvent(id: "mock-\(out.count)", camera: camera, kind: kind, start: t, end: end,
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
        case .item: options = ["A backpack left.", "A suitcase left."]
        case .bike: options = ["A cyclist rides past.", "A bicycle is wheeled up the path."]
        case .ring: options = ["Doorbell pressed."]
        case .privacy: options = [""]
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
