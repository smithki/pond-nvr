import Foundation
import NVRCore
import Testing
@testable import Devices

/// What the service does with a camera's controls while it's private or waking (`ControlServer.whileAsleep`).
@Suite struct PrivacyControlsTests {
    static func server(_ privacy: PrivacyState) -> ControlServer {
        ControlServer(path: NSTemporaryDirectory() + "pond-\(UUID().uuidString).sock", privacy: privacy, lookup: { _ in nil }, log: { _ in })
    }

    static func ask(_ action: String, item: String? = nil, value: Config.Controls.Value? = nil) -> ControlSocket.Request {
        ControlSocket.Request(camera: "porch", action: action, item: item, value: value)
    }

    @Test func wakingItsSettingsWaitAndItsActionsAreTurnedDown() {
        let privacy = PrivacyState()
        privacy.set("porch", private: true)
        privacy.set("porch", private: false, wakingFor: 45)
        let server = Self.server(privacy)
        #expect(server.whileAsleep(Self.ask("item.set", item: "statusLight", value: .on(false)))?.queued == true)
        #expect(privacy.pendingSettings("porch") == ["statusLight": .on(false)])
        // Read as it'll be.
        #expect(server.whileAsleep(Self.ask("items.values"))?.values == ["statusLight": .on(false)])
        #expect(server.whileAsleep(Self.ask("ptz.move"))?.error != nil)
        #expect(server.whileAsleep(Self.ask("talk"))?.error != nil)
        // A stop is harmless: answered without the camera.
        #expect(server.whileAsleep(Self.ask("ptz.stop"))?.error == nil)
    }

    @Test func aSettingAlreadySoDoesntWait() {
        let privacy = PrivacyState()
        let server = Self.server(privacy)
        // Known from before it went dark.
        server.remember(Self.ask("items.values"), ControlSocket.Reply(values: ["statusLight": .on(true)]))
        privacy.set("porch", private: true)
        privacy.set("porch", private: false, wakingFor: 45)
        #expect(server.whileAsleep(Self.ask("item.set", item: "statusLight", value: .on(true)))?.queued == nil)
        #expect(privacy.pendingSettings("porch").isEmpty)
        // Changed, then set back: no longer waits.
        #expect(server.whileAsleep(Self.ask("item.set", item: "statusLight", value: .on(false)))?.queued == true)
        _ = server.whileAsleep(Self.ask("item.set", item: "statusLight", value: .on(true)))
        #expect(privacy.pendingSettings("porch").isEmpty)
    }

    @Test func privateButReachableItsSettingsAreSetAtOnce() {
        // Pond's own privacy (no camera privacy mode): the camera still answers.
        let privacy = PrivacyState()
        privacy.set("porch", private: true)
        let server = Self.server(privacy)
        #expect(server.whileAsleep(Self.ask("item.set", item: "statusLight", value: .on(false))) == nil)
        #expect(server.whileAsleep(Self.ask("items.values")) == nil)
        // But it isn't moved or talked through: what it shows can't be seen.
        #expect(server.whileAsleep(Self.ask("ptz.goto"))?.error != nil)
        #expect(server.whileAsleep(Self.ask("item.do", item: "siren"))?.error != nil)
    }

    @Test func publicNothingIsInTheWay() {
        let server = Self.server(PrivacyState())
        for action in ["item.set", "items.values", "ptz.move", "talk", "item.do"] {
            #expect(server.whileAsleep(Self.ask(action, item: "x", value: .on(true))) == nil)
        }
    }
}
