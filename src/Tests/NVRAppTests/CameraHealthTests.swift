import Foundation
import Testing
@testable import NVRApp

@Suite struct CameraHealthTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func aNewCameraIsStartingNotMissing() {
        let added = now.addingTimeInterval(-60)
        let health = CameraHealth.of(live: nil, lastRecorded: nil, recordingAsOf: now, startedRecording: added)
        #expect(health == .startingToRecord)
        #expect(!health.isProblem)
        #expect(health.showsBadge)
    }

    @Test func stillNothingAfterAWhileIsAProblem() {
        let added = now.addingTimeInterval(-CameraHealth.firstRecordingWithin - 1)
        #expect(CameraHealth.of(live: nil, lastRecorded: nil, recordingAsOf: now, startedRecording: added) == .notRecording(since: nil))
        #expect(CameraHealth.of(live: nil, lastRecorded: nil, recordingAsOf: now) == .notRecording(since: nil))
    }

    @Test func onceRecordedItIsJustOK() {
        let added = now.addingTimeInterval(-90)
        #expect(CameraHealth.of(live: nil, lastRecorded: now.addingTimeInterval(-10), recordingAsOf: now, startedRecording: added) == .ok)
    }
}
