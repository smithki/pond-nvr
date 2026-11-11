// Test scenes: short clips, each with what it should make ("a parked car through a night: nothing"; "a courier:
// a person, 0:04 to 0:19, then a package"), replayed through what the recorder runs (WatchPipeline) and scored for
// what was missed and what was made that shouldn't have been. A scene is a folder: its clip, and scene.json:
//
//     { "name": "Parked car through a night", "about": "…", "clip": "clip.mp4",
//       "expect": [ { "kind": "person", "from": 4, "to": 19 } ], "zones": [ … ] }
//
// "expect" empty: it should make nothing. Times are seconds into the clip. Kinds are detection's (a bike's a vehicle
// there, as a zone takes it). The demo's made-up scenes are shared (in the repository, as how they're made); public
// datasets' are downloaded; an owner's own stay on their Mac (development.md: How detection changes are judged).
import Detection
import Foundation
import PondCore

public struct TestScene: Codable, Sendable, Equatable {
    public struct Expected: Codable, Sendable, Equatable {
        public var kind: String
        /// Seconds into the clip.
        public var from: Double
        public var to: Double

        public init(kind: String, from: Double, to: Double) {
            self.kind = kind
            self.from = from
            self.to = to
        }
    }

    /// Where a scene of an owner's own came from: one of their events, said (or taken) to be nothing or real.
    public struct Source: Codable, Sendable, Equatable {
        public enum Label: String, Codable, Sendable {
            /// Said not to be anything: passes if no event's made of it, or one's made and quieted.
            case nothing
            /// Real (said to be something, or seen and kept): passes if it's made, and not quieted.
            case real
        }

        /// The event's id.
        public var event: String
        public var label: Label
        public var camera: String
        public var category: DetectedCategory
        public var eventStart: Date
        public var box: Detection.Box?
        /// Its picture's embedding (for quieting by likeness), kept here so the scene outlasts the event.
        public var embedding: [Float]?

        public init(event: String, label: Label, camera: String, category: DetectedCategory, eventStart: Date,
                    box: Detection.Box?, embedding: [Float]?) {
            self.event = event
            self.label = label
            self.camera = camera
            self.category = category
            self.eventStart = eventStart
            self.box = box
            self.embedding = embedding
        }
    }

    public var name: String
    public var about: String?
    /// The clip, beside scene.json.
    public var clip: String
    public var expect: [Expected]
    public var zones: [Config.Zone]?
    /// When the clip begins (for the time of day: a learnt rule's night or day).
    public var start: Date?
    public var source: Source?

    public init(name: String, about: String? = nil, clip: String = "clip.mp4", expect: [Expected], zones: [Config.Zone]? = nil,
                start: Date? = nil, source: Source? = nil) {
        self.name = name
        self.about = about
        self.clip = clip
        self.expect = expect
        self.zones = zones
        self.start = start
        self.source = source
    }

    /// A scene folder's scene.json.
    public static func read(folder: String) throws -> TestScene {
        try JSONDecoder().decode(TestScene.self, from: Data(contentsOf: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("scene.json"))))
    }
}

/// An event a replay made, in the clip's seconds.
public struct MadeEvent: Sendable, Equatable {
    public var kind: String
    public var from: Double
    public var to: Double
    /// Its subject, as detection had it (for judging it as the app would).
    public var category: DetectedCategory?
    public var box: Detection.Box?

    public init(kind: String, from: Double, to: Double, category: DetectedCategory? = nil, box: Detection.Box? = nil) {
        self.kind = kind
        self.from = from
        self.to = to
        self.category = category
        self.box = box
    }

    public init(_ event: CameraEvent, clipStart: Date) {
        self.init(kind: event.category.zoneCategory, from: event.start.timeIntervalSince(clipStart),
                  to: event.end.timeIntervalSince(clipStart), category: event.category, box: event.box)
    }
}

/// How a scene went: what it should have made against what it did.
public struct SceneScore: Sendable, Equatable {
    /// Expected, and made.
    public var hits: Int
    /// Expected, and not made.
    public var misses: Int
    /// Made, and not expected (nothing of its kind then).
    public var falseEvents: Int
    /// Made as more than one where one was expected (each past the first): not wrong, but untidy.
    public var splits: Int

    /// An expected one is made by an event of its kind overlapping it, with this much to spare either side.
    public static let slack: Double = 2

    public static func score(expected: [TestScene.Expected], made: [MadeEvent]) -> SceneScore {
        func overlaps(_ e: TestScene.Expected, _ m: MadeEvent) -> Bool {
            e.kind == m.kind && m.from <= e.to + slack && m.to >= e.from - slack
        }
        var hits = 0, misses = 0, splits = 0
        var used = Set<Int>()
        for e in expected {
            let matching = made.indices.filter { overlaps(e, made[$0]) }
            if matching.isEmpty { misses += 1 } else { hits += 1; splits += matching.filter { !used.contains($0) }.count - 1 }
            used.formUnion(matching)
        }
        return SceneScore(hits: hits, misses: misses, falseEvents: made.count - used.count, splits: max(0, splits))
    }

    public static func + (a: SceneScore, b: SceneScore) -> SceneScore {
        SceneScore(hits: a.hits + b.hits, misses: a.misses + b.misses, falseEvents: a.falseEvents + b.falseEvents, splits: a.splits + b.splits)
    }

    public static let zero = SceneScore(hits: 0, misses: 0, falseEvents: 0, splits: 0)
}

/// A scene's pictures replayed through the pipeline: the events it makes, in the clip's seconds.
public struct SceneReplay {
    public var pipeline: WatchPipeline
    public let start: Date
    private var made: [String: CameraEvent] = [:]

    public init(scene: TestScene) {
        pipeline = WatchPipeline(camera: scene.source?.camera ?? "scene", rules: ZoneRules(scene.zones ?? []))
        start = scene.start ?? Date(timeIntervalSince1970: 0)
    }

    /// One picture, `seconds` into the clip: its motion grid, and the model's answer (given what moves).
    public mutating func picture(at seconds: Double, cells: () -> [Float], detect: (MotionMask) -> [Detection]?) {
        guard let out = pipeline.look(at: start.addingTimeInterval(seconds), cells: cells, detect: detect) else { return }
        keep(out.changes)
        for event in out.left { made[event.id] = event }
    }

    /// The end of the clip: what's going on ends, and what was made.
    public mutating func finish() -> [MadeEvent] {
        keep(pipeline.finish())
        return made.values.sorted { $0.start < $1.start }.map { MadeEvent($0, clipStart: start) }
    }

    private mutating func keep(_ changes: [EventBuilder.Change]) {
        for change in changes {
            switch change {
            case let .began(e), let .better(e), let .ended(e), let .resumed(e): made[e.id] = e
            }
        }
    }
}
