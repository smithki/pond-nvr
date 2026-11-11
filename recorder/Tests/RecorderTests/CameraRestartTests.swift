import Foundation
import Ingest
import PondCore
import Testing
@testable import Recorder

/// A camera that's there but whose video server keeps refusing connections is restarted through its controls, once
/// in a while, and only then.
@Suite struct CameraRestartTests {
    final class Asked: @unchecked Sendable {
        let lock = NSLock()
        var times: [Date] = []
        var count: Int { lock.withLock { times.count } }
    }

    /// A worker for a camera whose every connection fails with `error`, restarted after 1 s of refusals.
    func worker(failing error: RTSPError, privacy: PrivacyState, asked: Asked, every: TimeInterval = 60) throws -> CameraWorker {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("pond-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let camera = Config.Camera.reolink(id: "living-room", name: "Living Room", host: "192.0.2.1", username: "admin")
        let hub = StreamHub { _, _, _ throws(RTSPError) in throw error }
        return CameraWorker(camera: camera, password: "pw", recordingsRoot: root, log: PrintLog(), hub: hub, privacy: privacy,
                            restart: { _ in
                                asked.lock.withLock { asked.times.append(Date()) }
                                return "in a test"
                            }, restartAfter: 1, restartEvery: every)
    }

    @Test func refusedForAWhileIsRestartedOnce() async throws {
        let asked = Asked()
        let w = try worker(failing: .transport(.refused("192.0.2.1:554 refused the connection")), privacy: PrivacyState(), asked: asked)
        w.start()
        defer { w.stop(timeout: 3) }
        for _ in 0 ..< 100 where asked.count == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(asked.count == 1)
        // Not again soon after (once in `restartEvery`), however long it goes on.
        try await Task.sleep(for: .seconds(3))
        #expect(asked.count == 1)
    }

    @Test func noAnswerAtAllIsntRestarted() async throws {
        // Unreachable (no route, timed out): the network's, not its video server's; a restart wouldn't reach it.
        let asked = Asked()
        let w = try worker(failing: .transport(.unreachable("192.0.2.1:554 did not answer: Host is down")), privacy: PrivacyState(), asked: asked)
        w.start()
        defer { w.stop(timeout: 3) }
        try await Task.sleep(for: .seconds(3))
        #expect(asked.count == 0)
    }

    @Test func aPrivateCameraIsntRestarted() async throws {
        let asked = Asked()
        let privacy = PrivacyState()
        _ = privacy.set("living-room", private: true)
        let w = try worker(failing: .transport(.refused("refused")), privacy: privacy, asked: asked)
        w.start()
        defer { w.stop(timeout: 3) }
        try await Task.sleep(for: .seconds(3))
        #expect(asked.count == 0)
    }
}
