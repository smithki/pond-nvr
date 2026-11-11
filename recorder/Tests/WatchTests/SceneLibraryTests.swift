import Detection
import Foundation
import Testing
@testable import Watch

struct SceneLibraryTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    let car = Detection.Box(x: 0.6, y: 0.5, width: 0.2, height: 0.15)
    /// 1 a.m. on a November day.
    func night(_ day: Int) -> Date { utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 1))! }

    func scene(_ id: String, _ label: TestScene.Source.Label, day: Int = 9) -> TestScene {
        let start = night(day)
        return TestScene(name: id, expect: label == .real ? [.init(kind: "vehicle", from: 3, to: 13)] : [], start: start,
                         source: .init(event: id, label: label, camera: "drive", category: .vehicle, eventStart: start.addingTimeInterval(3),
                                       box: car, embedding: nil))
    }

    func dismissed(_ id: String, day: Int) -> EventFeedback {
        EventFeedback(id: id, camera: "drive", category: .vehicle, start: night(day), box: car, verdict: .nothing)
    }

    let made = [MadeEvent(kind: "vehicle", from: 3, to: 13, category: .vehicle, box: Detection.Box(x: 0.61, y: 0.5, width: 0.2, height: 0.15))]

    @Test func aDismissedSceneShouldComeBackQuietedOrNotAtAll() {
        // Three others dismissed there at night: a rule, which quiets it.
        let others = [dismissed("a", day: 1), dismissed("b", day: 2), dismissed("c", day: 3)]
        #expect(OwnSceneResult.judge(scene("s", .nothing), made: made, feedback: others, calendar: utc) == .passed)
        #expect(OwnSceneResult.judge(scene("s", .nothing), made: [], feedback: [], calendar: utc) == .passed)
        // Made again, and nothing to quiet it: shown again.
        #expect(OwnSceneResult.judge(scene("s", .nothing), made: made, feedback: [], calendar: utc) == .shown)
    }

    @Test func itsOwnDismissalNeverJudgesIt() {
        // Only it was dismissed: without its own, nothing quiets it; it's shown (and so fails, honestly).
        #expect(OwnSceneResult.judge(scene("s", .nothing), made: made, feedback: [dismissed("s", day: 9)], calendar: utc) == .shown)
    }

    @Test func aRealSceneMustBeMadeAndShown() {
        let rule = [dismissed("a", day: 1), dismissed("b", day: 2), dismissed("c", day: 3)]
        #expect(OwnSceneResult.judge(scene("r", .real), made: made, feedback: [], calendar: utc) == .passed)
        #expect(OwnSceneResult.judge(scene("r", .real), made: [], feedback: [], calendar: utc) == .missed)
        // A rule learnt from the others would hide it: that's what this check is for.
        #expect(OwnSceneResult.judge(scene("r", .real), made: made, feedback: rule, calendar: utc) == .hidden)
    }

    @Test func theLibraryKeepsAFewDozenOfEachAndLetsTheOldestGo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scenes-\(UUID().uuidString)").path
        let events = root + "/events"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: events, withIntermediateDirectories: true)
        try Data("not really a video".utf8).write(to: URL(fileURLWithPath: events + "/clip.mp4"))
        let library = SceneLibrary(folder: root + "/library")
        for i in 0 ..< SceneLibrary.perKind + 3 {
            let start = night(1).addingTimeInterval(Double(i) * 3600)
            let e = CameraEvent(id: "e\(i)", camera: "drive", start: start, end: start.addingTimeInterval(10), category: .vehicle, labels: ["car": 1], confidence: 0.8)
            #expect(library.add(EventStore.Kept(event: e, ongoing: false, clip: "clip.mp4", clipStart: start.addingTimeInterval(-3)),
                                label: .nothing, embedding: [0.1, 0.2], eventsFolder: events))
        }
        let kept = library.scenes()
        #expect(kept.count == SceneLibrary.perKind)
        #expect(!library.has("e0") && library.has("e\(SceneLibrary.perKind + 2)"))
        #expect(kept.first?.scene.source?.embedding == [0.1, 0.2] && kept.first?.scene.expect == [])
        // No clip yet: not kept.
        let e = CameraEvent(id: "x", camera: "drive", start: night(2), end: night(2), category: .vehicle, labels: [:], confidence: 0.5)
        #expect(!library.add(EventStore.Kept(event: e, ongoing: false), label: .real, embedding: nil, eventsFolder: events))
    }
}
