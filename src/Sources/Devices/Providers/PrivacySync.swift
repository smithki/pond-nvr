// A Reolink camera's own privacy mode kept in step with Pond's, both ways, over its Baichuan connection: made
// private in Pond, the camera's mode follows (ControlServer, through its provider); turned on or off on the
// camera (the Reolink app), Pond follows. Connecting (or again), a camera Pond keeps private is made so: Pond's
// privacy was set while the camera couldn't be told.
//
// Its mode on, the camera is dark: no video, and no HTTP API, so its settings wait (PrivacyState's pending); off,
// it's waking (PrivacyState's waking) until its video flows again.
import Foundation
import NVRCore

public final class CameraPrivacySync: @unchecked Sendable {
    let privacy: PrivacyState
    let log: @Sendable (String) -> Void
    private let lock = NSLock()
    /// Connected (or again), its first privacy report not yet heard.
    private var fresh: Set<String> = []
    private var sessions: [String: BaichuanSession] = [:]

    public init(privacy: PrivacyState = .shared, log: @escaping @Sendable (String) -> Void) {
        self.privacy = privacy
        self.log = log
    }

    public func watch(_ camera: String, _ session: BaichuanSession) {
        lock.withLock { sessions[camera] = session }
        session.observe(BaichuanSession.Observer(
            privacy: { [self] on in heard(camera, on, from: session) },
            state: { [self] state in if state == .connected { _ = lock.withLock { fresh.insert(camera) } } }))
    }

    /// Its own privacy mode is on (as it last said): it sends no video, and can't be asked anything over HTTP.
    public func isDark(_ camera: String) -> Bool {
        lock.withLock { sessions[camera] }?.privacyMode == true
    }

    /// Made public now, how long it may take to start its video again: none unless it's dark.
    public func wakeTime(_ camera: String) -> TimeInterval? {
        isDark(camera) ? BaichuanPrivacy.wakeTime : nil
    }

    func heard(_ camera: String, _ on: Bool, from session: BaichuanSession) {
        let first = lock.withLock { fresh.remove(camera) != nil }
        // Its own mode is Pond's privacy now: not reported apart.
        privacy.cameraReports(camera, privacyMode: false)
        if first, !on, privacy.isPrivate(camera) {
            log("· \(camera): private in Pond; its privacy mode turned on to match")
            Thread.detachNewThread { _ = try? session.setPrivacyMode(true) }
            return
        }
        // Turned off on the camera: it starts its video again, which takes a while.
        if privacy.set(camera, private: on, wakingFor: on ? nil : BaichuanPrivacy.wakeTime) {
            log("· \(camera): \(on ? "private" : "no longer private") (its privacy mode, on the camera)")
            HealthLog.shared.record(camera, on ? .madePrivate : .madePublic, "on the camera")
        }
    }
}
