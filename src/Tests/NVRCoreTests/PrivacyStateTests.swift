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

    @Test func nothingKeptIsNothingPrivate() {
        #expect(PrivacyState(path: Self.path()).privateCameras.isEmpty)
    }
}
