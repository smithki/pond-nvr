import Foundation
import Testing
@testable import PondApp

@MainActor
@Suite struct TimelineLiveTests {
    func timeline() -> TimelineModel {
        let t = TimelineModel()
        t.camera = "porch"
        return t
    }

    @Test func goingLivePutsThePlayheadAtThePresent() {
        let t = timeline()
        t.goLive()
        #expect(t.isLive)
        #expect(!t.playing)
        #expect(abs((t.playhead ?? .distantPast).timeIntervalSinceNow) < 2)
        #expect(Calendar.current.isDateInToday(t.day))
    }

    @Test func nothingLiveWithoutACamera() {
        let t = TimelineModel()
        t.goLive()
        #expect(!t.isLive)
    }

    @Test func seekingLeavesLive() async {
        let t = timeline()
        t.goLive()
        await t.seek(to: Date().addingTimeInterval(-3600))
        #expect(!t.isLive)
    }

    @Test func anotherCameraStaysLive() async {
        let t = timeline()
        t.goLive()
        await t.select(camera: "door")
        #expect(t.isLive)
        #expect(t.camera == "door")
    }

    @Test func anotherDayLeavesLive() async {
        let t = timeline()
        t.goLive()
        await t.show(day: Date().addingTimeInterval(-86400 * 2))
        #expect(!t.isLive)
    }
}

@MainActor
@Suite struct TimelineLiveViewTests {
    @Test func theViewMovesWithThePresent() throws {
        let t = TimelineModel()
        t.camera = "porch"
        t.zoom = .hour
        t.goLive()
        let now = try #require(t.playhead)
        let v = t.visible
        #expect(abs(v.upperBound.timeIntervalSince(v.lowerBound) - 3600) < 0.001)
        #expect(abs(now.timeIntervalSince(v.lowerBound) - 3600 * TimelineModel.liveAt) < 0.001)
    }
}

@MainActor
@Suite struct OngoingRecordingTests {
    @Test func whatIsBeingRecordedRunsFromTheBarsEndToNow() async throws {
        let root = NSTemporaryDirectory() + "pond-ongoing-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Being written: begun 20 s ago, last written a second ago.
        let start = Date().addingTimeInterval(-20).rounded()
        _ = try LiveEdgeTests.write(root, start, partial: true, modified: Date().addingTimeInterval(-1))
        let t = TimelineModel()
        await t.load(base: root, cameras: ["porch"])
        await t.refreshLive()
        let now = Date()
        let edge = try #require(t.liveEdge(of: "porch", now: now))
        #expect(t.recordingNow(of: "porch", now: now) == edge ... now || edge == now)
    }

    @Test func notAfterRecordingStopped() async throws {
        let root = NSTemporaryDirectory() + "pond-stopped-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A segment last written ten minutes ago (left by a recorder that stopped): not being recorded now.
        let start = Date().addingTimeInterval(-700).rounded()
        _ = try LiveEdgeTests.write(root, start, partial: true, modified: Date().addingTimeInterval(-600))
        let t = TimelineModel()
        await t.load(base: root, cameras: ["porch"])
        await t.refreshLive()
        #expect(t.recordingNow(of: "porch", now: Date()) == nil)
        #expect(t.recordingNow(of: "none", now: Date()) == nil)
    }
}

@MainActor
@Suite struct LiveSpeedTests {
    @Test func liveIsRealTime() {
        let t = TimelineModel()
        t.camera = "porch"
        t.rate = 4
        t.goLive()
        #expect(t.rate == 1)
        #expect(t.nearPresent)
    }

    @Test func farFromThePresentAnySpeed() async {
        let t = TimelineModel()
        t.camera = "porch"
        await t.seek(to: Date().addingTimeInterval(-3600))
        #expect(!t.nearPresent)
    }
}

/// The newest segment's file is shorter than its nominal minute (cut early, or still being written): playing
/// into the gap used to rebuild the same empty stretch over and over.
@MainActor
@Suite(.serialized) struct ShortSegmentTests {
    /// A 5 s H.264 clip, filed as the camera's latest segment, started 30 s ago.
    static func recordings() throws -> (base: String, start: Date) {
        let base = NSTemporaryDirectory() + "pond-short-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 30).rounded(.down))
        let day = DateFormatter()
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd/HH-mm-ss"
        let path = "\(base)/continuous/porch/\(day.string(from: start)).mp4"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A 5 s test pattern (ffmpeg testsrc2, 160×120 H.264), made once and kept with the tests.
        let clip = try #require(Bundle.module.url(forResource: "five-seconds", withExtension: "mp4", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: clip, to: URL(fileURLWithPath: path))
        return (base, start)
    }

    @Test func pausedPastTheFileStopsAtItsLastMoment() async throws {
        let (base, start) = try Self.recordings()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let t = TimelineModel()
        t.camera = "porch"
        await t.load(base: base, cameras: ["porch"])
        await t.seek(to: start.addingTimeInterval(20))
        let head = try #require(t.playhead)
        #expect(abs(head.timeIntervalSince(start) - 4.9) < 0.3)
        #expect(!t.isLive)
    }

    @Test func playingIntoTheGapStopsAtTheEnd() async throws {
        let (base, start) = try Self.recordings()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let t = TimelineModel()
        t.camera = "porch"
        await t.load(base: base, cameras: ["porch"])
        await t.seek(to: start.addingTimeInterval(1))
        t.play()
        #expect(t.playing)
        await t.seek(to: start.addingTimeInterval(20))
        // Live is only ever chosen: the recording ends, paused at its last moment.
        #expect(!t.isLive)
        #expect(!t.playing)
        let head = try #require(t.playhead)
        #expect(abs(head.timeIntervalSince(start) - 4.9) < 0.3)
    }
}

@MainActor
@Suite(.serialized) struct PlayingIntoLiveTests {
    /// The newest recording ended ten minutes ago: recording stopped, so playing past it stops there, not live.
    @Test func aStoppedRecordingDoesNotGoLive() async throws {
        let base = NSTemporaryDirectory() + "pond-behind-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 600).rounded(.down))
        let day = DateFormatter()
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd/HH-mm-ss"
        let path = "\(base)/continuous/porch/\(day.string(from: start)).mp4"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let clip = try #require(Bundle.module.url(forResource: "five-seconds", withExtension: "mp4", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: clip, to: URL(fileURLWithPath: path))
        let t = TimelineModel()
        t.camera = "porch"
        await t.load(base: base, cameras: ["porch"])
        await t.seek(to: start.addingTimeInterval(1))
        t.play()
        await t.seek(to: start.addingTimeInterval(20))
        #expect(!t.isLive)
        #expect(!t.playing)
    }
}
