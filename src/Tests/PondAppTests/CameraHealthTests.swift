import Foundation
import Testing
@testable import PondApp

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

    @Test func aRestartAfterAGapIsStartingNotMissing() {
        // Recorded until an hour ago; the service started again a minute ago: its first minute isn't saved yet.
        let lastRecorded = now.addingTimeInterval(-3600), started = now.addingTimeInterval(-60)
        #expect(CameraHealth.of(live: nil, lastRecorded: lastRecorded, recordingAsOf: now, startedRecording: started) == .startingToRecord)
        // Still nothing new minutes later: a problem again.
        let later = now.addingTimeInterval(CameraHealth.firstRecordingWithin)
        #expect(CameraHealth.of(live: nil, lastRecorded: lastRecorded, recordingAsOf: later, startedRecording: started) == .notRecording(since: lastRecorded))
    }

    @Test func theServicesStartIsItsProcesss() throws {
        let mine = try #require(AppModel.processStart(getpid()))
        #expect(mine <= Date() && mine > Date().addingTimeInterval(-3600))
    }

    @Test func onceRecordedItIsJustOK() {
        let added = now.addingTimeInterval(-90)
        #expect(CameraHealth.of(live: nil, lastRecorded: now.addingTimeInterval(-10), recordingAsOf: now, startedRecording: added) == .ok)
    }
}
