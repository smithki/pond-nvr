import Detection
import Foundation
import Testing
@testable import Watch

struct FeedbackTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 1 a.m. or 1 p.m. on a day, plus some minutes.
    func at(night: Bool, day: Int = 1, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: night ? 1 : 13, minute: minute))!
    }

    let parked = Detection.Box(x: 0.6, y: 0.5, width: 0.2, height: 0.15)
    let elsewhere = Detection.Box(x: 0.1, y: 0.1, width: 0.2, height: 0.15)

    func said(_ id: String, _ verdict: EventFeedback.Verdict = .nothing, night: Bool = true, box: Detection.Box? = nil,
              category: DetectedCategory = .vehicle, embedding: [Float]? = nil) -> EventFeedback {
        EventFeedback(id: id, camera: "drive", category: category, start: at(night: night, day: Int(id.filter(\.isNumber)) ?? 1),
                      box: box ?? parked, verdict: verdict, embedding: embedding)
    }

    @Test func threeDismissedInOneSpotAtNightMakeARule() {
        let judge = EventJudge(feedback: [said("e1"), said("e2"), said("e3")], calendar: calendar)
        #expect(judge.rules.count == 1)
        #expect(judge.rules.first?.night == true && judge.rules.first?.from.count == 3)
        let nudged = Detection.Box(x: 0.62, y: 0.51, width: 0.21, height: 0.15)
        // Another vehicle there at night: quieted. By day, elsewhere, or a person there: not.
        #expect(judge.judge(id: "n", camera: "drive", category: .vehicle, start: at(night: true, day: 9), box: nudged,
                            embedding: nil, calendar: calendar) == .rule(judge.rules[0]))
        #expect(judge.judge(id: "n", camera: "drive", category: .vehicle, start: at(night: false, day: 9), box: nudged,
                            embedding: nil, calendar: calendar) == nil)
        #expect(judge.judge(id: "n", camera: "drive", category: .vehicle, start: at(night: true, day: 9), box: elsewhere,
                            embedding: nil, calendar: calendar) == nil)
        #expect(judge.judge(id: "n", camera: "drive", category: .person, start: at(night: true, day: 9), box: nudged,
                            embedding: nil, calendar: calendar) == nil)
    }

    @Test func twoMakeNoRuleAndSomethingThereUndoesOne() {
        #expect(EventJudge(feedback: [said("e1"), said("e2")], calendar: calendar).rules.isEmpty)
        let judge = EventJudge(feedback: [said("e1"), said("e2"), said("e3"), said("e4", .something)], calendar: calendar)
        #expect(judge.rules.isEmpty)
    }

    @Test func theOneDismissedIsQuietedAndOneSaidToBeSomethingIsnt() {
        let judge = EventJudge(feedback: [said("e1"), said("e2", .something)], calendar: calendar)
        #expect(judge.judge(id: "e1", camera: "drive", category: .vehicle, start: at(night: true), box: parked,
                            embedding: nil, calendar: calendar) == .dismissed)
        #expect(judge.judge(id: "e2", camera: "drive", category: .vehicle, start: at(night: true), box: parked,
                            embedding: nil, calendar: calendar) == nil)
    }

    @Test func aPictureLikeADismissedOneNearItsSpotIsQuieted() {
        let flag: [Float] = [1, 0, 0, 0.1], person: [Float] = [0, 1, 0, 0]
        let judge = EventJudge(feedback: [said("e1", category: .person, embedding: flag)], calendar: calendar)
        // Like it, near: quieted (any time of day). Unlike it, or like it elsewhere: not.
        #expect(judge.judge(id: "n", camera: "drive", category: .person, start: at(night: false, day: 9), box: parked,
                            embedding: [0.98, 0.05, 0, 0.1], calendar: calendar) == .likeness(1))
        #expect(judge.judge(id: "n", camera: "drive", category: .person, start: at(night: false, day: 9), box: parked,
                            embedding: person, calendar: calendar) == nil)
        #expect(judge.judge(id: "n", camera: "drive", category: .person, start: at(night: false, day: 9), box: elsewhere,
                            embedding: flag, calendar: calendar) == nil)
        // One like it said to be something: that outweighs it.
        let both = EventJudge(feedback: [said("e1", category: .person, embedding: flag),
                                         said("e2", .something, category: .person, embedding: flag)], calendar: calendar)
        #expect(both.judge(id: "n", camera: "drive", category: .person, start: at(night: false, day: 9), box: parked,
                           embedding: flag, calendar: calendar) == nil)
    }

    @Test func feedbackIsKeptWithTheEventsEmbeddingAndForgotten() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pond-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try #require(EventStore(path: path))
        store.understood("e1", .init(subject: [0.5, 0.5], embedder: "siglip"))
        store.record(said("e1"))
        store.record(said("e2", .something, box: elsewhere))
        let kept = store.feedback()
        #expect(kept.map(\.id) == ["e1", "e2"])
        #expect(kept[0].embedding == [0.5, 0.5] && kept[0].embedder == "siglip" && kept[0].box == parked)
        #expect(kept[1].verdict == .something)
        store.forgetFeedback(["e1"])
        #expect(store.feedback(camera: "drive").map(\.id) == ["e2"])
        store.forgetFeedback(camera: "drive")
        #expect(store.feedback().isEmpty)
    }
}
