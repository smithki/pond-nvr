// A Reolink camera's own privacy mode kept in step with Pond's, both ways, over its Baichuan connection: made
// private in Pond, the camera's mode follows (ControlServer, through its provider); turned on or off on the
// camera (the Reolink app), Pond follows. Connecting (or again), a camera that disagrees with Pond is put right
// only if Pond's change never reached it (PrivacyState's untold: made while it couldn't be told, or the service
// stopped first); otherwise it was changed on the camera meanwhile, and Pond follows that.
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
            state: { [self] state in if state == .connected { connected(camera) } }))
    }

    /// No longer followed (the camera removed, or its connection to be made again).
    public func unwatch(_ camera: String) {
        _ = lock.withLock {
            fresh.remove(camera)
            return sessions.removeValue(forKey: camera)
        }
    }

    /// Connected (or again): its next privacy report is its first.
    func connected(_ camera: String) { _ = lock.withLock { fresh.insert(camera) } }

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
        let wanted = privacy.isPrivate(camera)
        if on == wanted {
            privacy.told(camera)
            return
        }
        // Connected again, and Pond's change never reached it: it's told now.
        if first, privacy.isUntold(camera) {
            log("· \(camera): \(wanted ? "private" : "public") in Pond while it couldn\u{2019}t be told; its privacy mode turned \(wanted ? "on" : "off") to match")
            if !wanted { privacy.wake(camera, for: BaichuanPrivacy.wakeTime) }
            Thread.detachNewThread { [privacy] in
                if (try? session.setPrivacyMode(wanted)) == wanted { privacy.told(camera) }
            }
            return
        }
        // Changed on the camera (now, or while Pond wasn't connected): Pond follows. Turned off, it starts its
        // video again, which takes a while.
        if privacy.set(camera, private: on, wakingFor: on ? nil : BaichuanPrivacy.wakeTime, byCamera: true) {
            log("· \(camera): \(on ? "private" : "no longer private") (its privacy mode, on the camera)")
            HealthLog.shared.record(camera, on ? .madePrivate : .madePublic, "on the camera")
        }
    }
}
