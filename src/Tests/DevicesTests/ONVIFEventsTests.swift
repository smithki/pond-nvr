import Foundation
import Testing
@testable import Devices

/// ONVIF events, as a Reolink doorbell sent them while someone walked past and pressed its button.
@Suite struct ONVIFEventsTests {
    static func event(_ op: String, _ topic: String, _ data: [String: String], source: [String: String] = [:]) -> ONVIFEvent {
        ONVIFEvent(topic: "tns1:" + topic, operation: op, source: source, data: data)
    }

    static let walkPast: [ONVIFEvent] = [
        event("Initialized", "RuleEngine/CellMotionDetector/Motion", ["IsMotion": "false"], source: ["Source": "000"]),
        event("Initialized", "RuleEngine/MyRuleDetector/PeopleDetect", ["State": "false"], source: ["Source": "000"]),
        event("Initialized", "VideoSource/MotionAlarm", ["State": "false"]),
        event("Initialized", "RuleEngine/MyRuleDetector/Visitor", ["State": "false"], source: ["Source": "000"]),
        event("Initialized", "RuleEngine/MyRuleDetector/Package", ["State": "false"]),
        event("Changed", "RuleEngine/MyRuleDetector/PeopleDetect", ["State": "true"]),
        event("Changed", "RuleEngine/MyRuleDetector/VehicleDetect", ["State": "true"]),
        event("Changed", "RuleEngine/MyRuleDetector/Visitor", ["State": "true"]),
        event("Changed", "RuleEngine/MyRuleDetector/VehicleDetect", ["State": "false"]),
        event("Changed", "RuleEngine/CellMotionDetector/Motion", ["IsMotion": "true"], source: ["Source": "000"]),
        event("Changed", "VideoSource/MotionAlarm", ["State": "true"]),
        event("Changed", "RuleEngine/MyRuleDetector/PeopleDetect", ["State": "false"]),
        event("Changed", "RuleEngine/CellMotionDetector/Motion", ["IsMotion": "false"], source: ["Source": "000"]),
        event("Changed", "VideoSource/MotionAlarm", ["State": "false"]),
    ]

    @Test func motionWhileAnyDetectorIsOnAndAPressOnce() {
        var tracker = ONVIFEventTracker()
        var motion: [Bool] = [], presses = 0
        for e in Self.walkPast {
            let change = tracker.take(e)
            if let m = change.motion { motion.append(m) }
            if change.pressed { presses += 1 }
        }
        #expect(motion == [true, false])
        #expect(presses == 1)
    }

    @Test func eachPressCountsEvenWithoutAnOffBetween() {
        var tracker = ONVIFEventTracker()
        let press = Self.event("Changed", "RuleEngine/MyRuleDetector/Visitor", ["State": "true"])
        let start = Date()
        #expect(tracker.take(press, at: start).pressed)
        #expect(!tracker.take(press, at: start.addingTimeInterval(1)).pressed)   // the same press, told again
        #expect(tracker.take(press, at: start.addingTimeInterval(20)).pressed)
    }

    @Test func kinds() {
        #expect(Self.event("", "RuleEngine/MyRuleDetector/Package", [:]).kind == .other)
        #expect(Self.event("", "RuleEngine/MyRuleDetector/FaceDetect", [:]).kind == .other)
        #expect(Self.event("", "RuleEngine/MyRuleDetector/DogCatDetect", [:]).kind == .motion)
        #expect(Self.event("", "RuleEngine/MyRuleDetector/Visitor", [:]).kind == .doorbell)
        #expect(Self.event("", "VideoSource/MotionAlarm", [:]).kind == .motion)
    }
}
