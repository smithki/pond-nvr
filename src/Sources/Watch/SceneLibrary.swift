// An owner's own test scenes (with beta and test features on: they take room, and keep clips past event retention),
// made from their events on their Mac and never anywhere else (development.md: Footage
// stays private): each one an event's clip and what it was. "Nothing": said not to be anything. "Real": said to be
// something, or seen in Events and kept a day without being dismissed. Kept a few dozen of each per camera (the
// oldest let go), in a Scenes folder beside the Pond database they came from (a demo's beside its own), a folder each; `pond advanced scenes` replays them through the
// build and says whether it would have made and quieted them as their owner wanted, each judged by what was learnt
// from all the rest (never from itself). The app fills it; nothing else reads it.
import Detection
import Foundation
import PondCore

public struct SceneLibrary: Sendable {
    public let folder: String
    /// At most this many of each label, per camera.
    public static let perKind = 40
    /// Fewer than this of a label, per camera, and what it says isn't to be relied on.
    public static let enough = 20

    public init(folder: String) { self.folder = folder }

    /// The library of a Pond's database: its Scenes folder, beside it.
    public init(beside database: String) {
        folder = ((database as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Scenes")
    }

    /// Kept: the event's clip (copied from the events folder) and what it was. False if it has no clip yet, or the
    /// copy couldn't be made.
    @discardableResult
    public func add(_ kept: EventStore.Kept, label: TestScene.Source.Label, embedding: [Float]?, eventsFolder: String,
                    now: Date = Date()) -> Bool {
        let e = kept.event
        guard let clip = kept.clip, !clip.isEmpty, let clipStart = kept.clipStart else { return false }
        let fm = FileManager.default
        let from = (eventsFolder as NSString).appendingPathComponent(clip)
        let here = (folder as NSString).appendingPathComponent(e.id)
        guard fm.fileExists(atPath: from) else { return false }
        try? fm.removeItem(atPath: here)
        do {
            try fm.createDirectory(atPath: here, withIntermediateDirectories: true)
            try fm.copyItem(atPath: from, toPath: (here as NSString).appendingPathComponent("clip.mp4"))
        } catch { return false }
        let expect = label == .real
            ? [TestScene.Expected(kind: e.category.zoneCategory, from: e.start.timeIntervalSince(clipStart), to: e.end.timeIntervalSince(clipStart))]
            : []
        let when = e.start.formatted(date: .abbreviated, time: .shortened)
        let scene = TestScene(name: "\(e.camera): \(e.category.rawValue), \(when) (\(label.rawValue))",
                              expect: expect, start: clipStart,
                              source: .init(event: e.id, label: label, camera: e.camera, category: e.category, eventStart: e.start,
                                            box: e.box, embedding: embedding))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(scene) else { return false }
        do { try data.write(to: URL(fileURLWithPath: (here as NSString).appendingPathComponent("scene.json"))) } catch { return false }
        trim(camera: e.camera, label: label)
        return true
    }

    /// Whether an event's in the library already.
    public func has(_ event: String) -> Bool {
        FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent("\(event)/scene.json"))
    }

    /// How many there are, and the room they take.
    public func size() -> (scenes: Int, bytes: Int64) {
        let fm = FileManager.default
        var bytes: Int64 = 0
        if let walk = fm.enumerator(atPath: folder) {
            for case let path as String in walk {
                bytes += ((try? fm.attributesOfItem(atPath: (folder as NSString).appendingPathComponent(path)))?[.size] as? Int64) ?? 0
            }
        }
        return (scenes().count, bytes)
    }

    /// Every one let go.
    public func removeAll() { try? FileManager.default.removeItem(atPath: folder) }

    /// Let go: these events' scenes.
    public func remove(_ events: [String]) {
        for id in events { try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(id)) }
    }

    /// Every scene, with its folder.
    public func scenes() -> [(folder: String, scene: TestScene)] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted().compactMap { name in
            let path = (folder as NSString).appendingPathComponent(name)
            return (try? TestScene.read(folder: path)).map { (path, $0) }
        }
    }

    /// A camera's scenes of a label, no more than perKind: the oldest let go.
    func trim(camera: String, label: TestScene.Source.Label) {
        let these = scenes().filter { $0.scene.source?.camera == camera && $0.scene.source?.label == label }
            .sorted { ($0.scene.source?.eventStart ?? .distantPast) < ($1.scene.source?.eventStart ?? .distantPast) }
        for old in these.dropLast(Self.perKind) { try? FileManager.default.removeItem(atPath: old.folder) }
    }
}

/// How an owner's scene went, through this build: made and quieted as they'd want, or not.
public enum OwnSceneResult: Sendable, Equatable {
    case passed
    /// Real, and not made (detection missed it).
    case missed
    /// Real, made, and quieted (hidden, though it mattered).
    case hidden
    /// Nothing, and made and shown (a false alarm again).
    case shown

    /// A replay's events judged as the app would: by what was learnt from every other thing said (never this one's).
    public static func judge(_ scene: TestScene, made: [MadeEvent], feedback: [EventFeedback], calendar: Calendar = .current) -> OwnSceneResult? {
        guard let source = scene.source else { return nil }
        let judge = EventJudge(feedback: feedback.filter { $0.id != source.event }, calendar: calendar)
        let start = scene.start ?? source.eventStart
        let window = (from: source.eventStart.timeIntervalSince(start) - SceneScore.slack,
                      to: (scene.expect.first?.to ?? source.eventStart.timeIntervalSince(start)) + SceneScore.slack)
        // What was made of it: of its kind, about when it was.
        let ofIt = made.filter { $0.kind == source.category.zoneCategory && $0.from <= window.to && $0.to >= window.from }
        let shown = ofIt.filter { m in
            judge.judge(id: UUID().uuidString, camera: source.camera, category: m.category ?? source.category,
                        start: start.addingTimeInterval(m.from), box: m.box ?? source.box, embedding: source.embedding,
                        calendar: calendar) == nil
        }
        switch source.label {
        case .nothing: return shown.isEmpty ? .passed : .shown
        case .real: return ofIt.isEmpty ? .missed : shown.isEmpty ? .hidden : .passed
        }
    }
}
