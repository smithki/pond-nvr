import Foundation
import NVRCore
import Testing
@testable import NVRApp

@Suite struct RecordingTextTests {
    let camera = Config.Camera.reolink(id: "porch", name: "Porch", host: "192.168.1.30", username: "admin")
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func status(_ edit: (inout HomeKitStatus.Recording) -> Void) -> HomeKitStatus.Recording {
        var r = HomeKitStatus.Recording()
        edit(&r)
        return r
    }

    @Test func eachStateInPlainWords() {
        #expect(RecordingText(status { _ in }, camera: camera, now: now).title == "Recording off in the Home app")
        #expect(RecordingText(status { $0.on = true }, camera: camera, now: now).title == "Waiting for your home hub")
        let ready = RecordingText(status { $0.on = true; $0.chosen = true; $0.sound = true }, camera: camera, now: now)
        #expect(ready.title == "Recording motion, with sound" && !ready.attention)
        #expect(ready.detail.hasPrefix("No recordings yet"))
        let blind = RecordingText(status { $0.on = true; $0.chosen = true; $0.motion = false }, camera: camera, now: now)
        #expect(blind.title == "Won\u{2019}t record" && blind.attention)
    }

    @Test func theLastClipAndProblemsAreSaid() {
        let clip = HomeKitStatus.Recording.Clip(at: now.addingTimeInterval(-60), seconds: 16, bytes: 5_300_000)
        let done = RecordingText(status { $0.on = true; $0.chosen = true; $0.lastClip = clip }, camera: camera, now: now)
        #expect(done.detail.hasPrefix("Last recording at "))
        #expect(done.detail.contains("16 s"))
        let cut = RecordingText(status { $0.on = true; $0.chosen = true; $0.problem = .init(.cutShort) }, camera: camera, now: now)
        #expect(cut.title == "A recording failed" && cut.attention)
        let now2 = RecordingText(status { $0.on = true; $0.chosen = true; $0.recording = true }, camera: camera, now: now)
        #expect(now2.title == "Recording now")
    }
}
