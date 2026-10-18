import Foundation
import Testing
@testable import NVRCore

@Suite struct PrivacyStateTests {
    static func path() -> String { NSTemporaryDirectory() + "pond-privacy-\(UUID().uuidString)/privacy.json" }

    @Test func keptAcrossRestarts() throws {
        let path = Self.path()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let state = PrivacyState(path: path)
        #expect(state.set("porch", private: true))
        #expect(PrivacyState(path: path).isPrivate("porch"))
        state.set("porch", private: false)
        #expect(!PrivacyState(path: path).isPrivate("porch"))
    }

    @Test func observersAreToldOnlyOfChanges() {
        let state = PrivacyState()
        final class Told: @unchecked Sendable { var changes: [String] = [] }
        let told = Told()
        let id = state.observe { camera, on in told.changes.append("\(camera) \(on)") }
        state.set("porch", private: true)
        // Already private: nothing to tell.
        #expect(!state.set("porch", private: true))
        state.set("porch", private: false)
        state.forget(id)
        state.set("garden", private: true)
        #expect(told.changes == ["porch true", "porch false"])
    }

    @Test func madePublicWhileDarkItWakesUntilItsVideoFlows() throws {
        let path = Self.path()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let state = PrivacyState(path: path)
        state.set("porch", private: true)
        state.set("porch", private: false, wakingFor: 45)
        #expect(state.isWaking("porch"))
        // Kept, for the app and across a restart.
        #expect(PrivacyState(path: path).wakingCameras == ["porch"])
        final class Told: @unchecked Sendable { var cameras: [String] = [] }
        let told = Told()
        state.observeAwake { told.cameras.append($0) }
        state.awake("porch")
        #expect(!state.isWaking("porch") && told.cameras == ["porch"])
        #expect(!PrivacyState(path: path).isWaking("porch"))
    }

    @Test func onlyAChangeToPublicWakes() {
        let state = PrivacyState()
        // Public already: nothing to wake from.
        state.set("porch", private: false, wakingFor: 45)
        #expect(!state.isWaking("porch"))
        state.set("porch", private: true)
        state.set("porch", private: false, wakingFor: 45)
        // Private again: no longer waking.
        state.set("porch", private: true)
        #expect(!state.isWaking("porch"))
        // Past its time, it isn't either.
        state.set("porch", private: false, wakingFor: -1)
        #expect(!state.isWaking("porch"))
    }

    @Test func settingsWaitTheLatestOfEach() throws {
        let path = Self.path()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let state = PrivacyState(path: path)
        state.queue("porch", item: "statusLight", .on(true))
        state.queue("porch", item: "statusLight", .on(false))
        state.queue("porch", item: "speakerVolume", .number(40))
        #expect(PrivacyState(path: path).pendingSettings("porch") == ["statusLight": .on(false), "speakerVolume": .number(40)])
        #expect(state.takePending("porch").count == 2)
        #expect(state.pendingSettings("porch").isEmpty)
        #expect(PrivacyState(path: path).allPending.isEmpty)
    }

    @Test func nothingKeptIsNothingPrivate() {
        #expect(PrivacyState(path: Self.path()).privateCameras.isEmpty)
    }
}
