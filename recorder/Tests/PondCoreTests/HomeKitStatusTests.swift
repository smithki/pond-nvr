import Foundation
import Testing
@testable import PondCore

@Suite struct HomeKitStatusTests {
    @Test func writtenAndReadBack() throws {
        let dir = NSTemporaryDirectory() + "pond-status-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = HomeKitStatus.path(nextTo: dir + "/config.json")
        #expect(path == dir + "/homekit-status.json")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let status = HomeKitStatus(updated: at, pid: 42, cameras: [
            "porch": .init(running: true, paired: true, viewers: 1),
            "door": .init(running: true, paired: false, problem: .init(.loginRefused, during: .liveView, at: at),
                          doorbell: .notSupported),
        ])
        status.write(path)
        #expect(HomeKitStatus.read(path) == status)
        #expect(HomeKitStatus.read(dir + "/missing.json") == nil)
    }

    @Test func olderSettingsHaveNoHomeKitOrDevice() throws {
        let json = """
        {"id":"porch","name":"Porch","main":"rtsp://h/main","sub":"rtsp://h/sub","username":"admin"}
        """
        let camera = try JSONDecoder().decode(Config.Camera.self, from: Data(json.utf8))
        #expect(camera.kind == .camera)
        #expect(camera.homekit == false)
        #expect(camera.device == nil)
        #expect(camera.host == "h")
    }

    @Test func newSettingsKeepThem() throws {
        var camera = Config.Camera(id: "door", name: "Door", main: "rtsp://h/main", sub: "rtsp://h/sub", username: "admin")
        camera.kind = .doorbell
        camera.homekit = true
        camera.device = Config.Device(manufacturer: "Reolink", model: "D340W", serial: "9", isDoorbell: true, provider: "reolink")
        let back = try JSONDecoder().decode(Config.Camera.self, from: JSONEncoder().encode(camera))
        #expect(back == camera)
    }
}
