import Foundation
import NVRCore
import Testing
@testable import Devices

/// Connected again, a camera that disagrees with Pond: put right only if Pond's change never reached it.
@Suite struct PrivacySyncTests {
    /// Never started, so nothing reaches a camera (being told, it fails quietly).
    static let session = BaichuanSession(host: "192.0.2.1", username: "admin", password: "")

    @Test func changedInTheReolinkAppMeanwhilePondFollows() {
        let privacy = PrivacyState()
        let sync = CameraPrivacySync(privacy: privacy, log: { _ in })
        privacy.set("porch", private: true)
        privacy.told("porch")
        // Turned off in the Reolink app while Pond wasn't connected.
        sync.connected("porch")
        sync.heard("porch", false, from: Self.session)
        #expect(!privacy.isPrivate("porch"))
        #expect(privacy.isWaking("porch"))
    }

    @Test func pondsChangeThatNeverReachedItStands() {
        let privacy = PrivacyState()
        let sync = CameraPrivacySync(privacy: privacy, log: { _ in })
        // Made private in Pond while the camera couldn't be told.
        privacy.set("porch", private: true)
        sync.connected("porch")
        sync.heard("porch", false, from: Self.session)
        #expect(privacy.isPrivate("porch"))
    }

    @Test func aLaterChangeOnTheCameraIsFollowedEvenIfUntold() {
        let privacy = PrivacyState()
        let sync = CameraPrivacySync(privacy: privacy, log: { _ in })
        privacy.set("porch", private: true)
        sync.connected("porch")
        // Its first report agrees: it has Pond's change.
        sync.heard("porch", true, from: Self.session)
        #expect(!privacy.isUntold("porch"))
        sync.heard("porch", false, from: Self.session)
        #expect(!privacy.isPrivate("porch"))
    }
}
