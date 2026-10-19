import Foundation
import Testing
@testable import NVRApp

/// Opt-in, against a running recorder: POND_PROBE_BASE=<recordings folder> POND_PROBE_CAMERA=<id> swift test --filter
/// RealLiveEdgeProbe. Watches the bar's live end for 75 s (across a new file each minute): never back, never past now.
@MainActor
@Suite struct RealLiveEdgeProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POND_PROBE_BASE"] != nil
        && ProcessInfo.processInfo.environment["POND_PROBE_CAMERA"] != nil))
    func watchARealMinuteChange() async throws {
        let base = ProcessInfo.processInfo.environment["POND_PROBE_BASE"]!
        let camera = ProcessInfo.processInfo.environment["POND_PROBE_CAMERA"]!
        let timeline = TimelineModel()
        await timeline.load(base: base, cameras: [camera])
        var last: Date?
        var backwards = 0, ahead = 0, gaps = 0, files = Set<String>()
        for _ in 0 ..< 150 {
            await timeline.refreshLive()
            let now = Date()
            if let edge = timeline.liveEdge(of: camera, now: now) {
                if let last, edge < last.addingTimeInterval(-0.05) { backwards += 1; print("back by", last.timeIntervalSince(edge)) }
                if edge > now { ahead += 1 }
                last = edge
                print(String(format: "lag %.2f s", now.timeIntervalSince(edge)), timeline.live[camera]!.path.split(separator: "/").last!)
            }
            if let ranges = timeline.coverage[camera], let tail = ranges.last, ranges.count > 1,
               tail.lowerBound.timeIntervalSince(ranges[ranges.count - 2].upperBound) < 120 { gaps += 1 }
            if let p = timeline.live[camera]?.path { files.insert(p) }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("files", files.count, "backwards", backwards, "ahead", ahead, "recent gaps", gaps)
        #expect(backwards == 0 && ahead == 0)
    }
}
