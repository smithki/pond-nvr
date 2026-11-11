import Foundation
import Testing
@testable import PondCore

@Suite struct RecordingAlertTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func allRecordingIsClosed() {
        var alert = RecordingAlert()
        #expect(alert.check([("door", "Front Door", .recording), ("yard", "Yard", .excused)], now: Self.t0) == nil)
    }

    @Test func aCameraDownIsSaidOnlyAfterFiveMinutes() {
        var alert = RecordingAlert()
        let down: [(id: String, name: String, state: RecordingAlert.CameraState)] = [("door", "Front Door", .notRecording("no route"))]
        #expect(alert.check(down, now: Self.t0) == nil)
        #expect(alert.check(down, now: Self.t0.addingTimeInterval(240)) == nil)
        #expect(alert.check(down, now: Self.t0.addingTimeInterval(300)) == "Not recording Front Door (no route).")
        // Back: closed at once, and counted afresh next time.
        #expect(alert.check([("door", "Front Door", .recording)], now: Self.t0.addingTimeInterval(310)) == nil)
        #expect(alert.check(down, now: Self.t0.addingTimeInterval(320)) == nil)
    }

    @Test func severalCamerasAreCounted() {
        var alert = RecordingAlert()
        let down: [(id: String, name: String, state: RecordingAlert.CameraState)] = [
            ("door", "Front Door", .notRecording("no route")), ("yard", "Yard", .notRecording("connecting")),
        ]
        _ = alert.check(down, now: Self.t0)
        #expect(alert.check(down, now: Self.t0.addingTimeInterval(300)) == "Not recording 2 cameras: Front Door (no route), Yard (connecting).")
    }

    @Test func theDriveAfterAMinute() {
        var alert = RecordingAlert()
        let drive: [(id: String, name: String, state: RecordingAlert.CameraState)] = [("door", "Front Door", .driveUnusable)]
        #expect(alert.check(drive, now: Self.t0) == nil)
        #expect(alert.check(drive, now: Self.t0.addingTimeInterval(60))?.hasPrefix("The recordings drive") == true)
    }

    @Test func sleepIsSaidAtOnce() {
        var alert = RecordingAlert()
        #expect(alert.check([("door", "Front Door", .recording)], now: Self.t0, asleep: true)?.hasPrefix("This Mac is going to sleep") == true)
    }
}
