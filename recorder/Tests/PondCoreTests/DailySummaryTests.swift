import Foundation
import Testing
@testable import PondCore

@Suite struct DailySummaryTests {
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    static let since = Date(timeIntervalSince1970: 1_800_000_000)   // the day before, at the summary's hour
    static let until = since.addingTimeInterval(86400)
    static func at(_ hours: Double) -> Date { since.addingTimeInterval(hours * 3600) }
    static let cameras: [(id: String, name: String)] = [("door", "Front Door"), ("yard", "Yard"), ("office", "Office")]

    func summary(_ gaps: [String: [RecordingGap]], privateNow: Set<String> = []) -> DailySummary {
        DailySummary.make(cameras: Self.cameras, gaps: gaps, privateNow: privateNow, since: Self.since, until: Self.until, calendar: Self.calendar)
    }

    @Test func noGapsIsAllWell() {
        let s = summary([:])
        #expect(s.allWell && s.title == "All well")
        #expect(s.body.hasSuffix(": 3 cameras, no gaps."))
        #expect(s.body.contains("yesterday"))
    }

    @Test func aPrivateCameraIsSaidNotCounted() {
        let s = summary([:], privateNow: ["office"])
        #expect(s.body.hasSuffix("2 cameras, no gaps. (Office is private)"))
        // Nor its gaps.
        #expect(summary(["office": [RecordingGap(range: Self.at(1) ... Self.at(2), reason: .unreachable)]], privateNow: ["office"]).allWell)
    }

    @Test func oneCamerasGap() {
        let s = summary(["yard": [RecordingGap(range: Self.at(1) ... Self.at(2), reason: .unreachable)]])
        #expect(!s.allWell && s.title == "Not everything was recorded")
        #expect(s.body.hasPrefix("Yard not recorded ") && s.body.hasSuffix(": the camera didn\u{2019}t answer."))
    }

    @Test func aGapEveryCameraHadIsSaidOnce() {
        let gap = { (shift: Double) in RecordingGap(range: Self.at(3 + shift) ... Self.at(5), reason: .macAsleep) }
        let s = summary(["door": [gap(0)], "yard": [gap(0.01)], "office": [gap(0.02)]])
        #expect(s.body.hasPrefix("Nothing recorded ") && s.body.hasSuffix(": this Mac was asleep."))
        #expect(!s.body.contains("\n"))
    }

    @Test func twoOfThreeAreNamed() {
        let gap = RecordingGap(range: Self.at(3) ... Self.at(4), reason: .storage("the recordings drive was full"))
        #expect(summary(["door": [gap], "yard": [gap]]).body.hasPrefix("Front Door and Yard not recorded"))
    }

    @Test func manyAreCounted() {
        let gaps = (0 ..< 5).map { RecordingGap(range: Self.at(Double($0) * 2) ... Self.at(Double($0) * 2 + 1), reason: .videoStopped) }
        let s = summary(["door": gaps])
        #expect(s.body.split(separator: "\n").count == 4)
        #expect(s.body.hasSuffix("And 2 more: the doctor has them all."))
        #expect(s.title == "Not everything was recorded (5 h of gaps)")
    }

    @Test func gapsOutsideThePeriodArentCounted() {
        #expect(summary(["door": [RecordingGap(range: Self.since.addingTimeInterval(-7200) ... Self.since.addingTimeInterval(-3600),
                                               reason: .unreachable)]]).allWell)
    }
}
