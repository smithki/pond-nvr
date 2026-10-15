import Foundation
@testable import HAP
import NVRCore
import Testing
@testable import HAPCamera

final class MemoryRecords: HomeKitRecords, @unchecked Sendable {
    var saved: [String: HomeKitRecord] = [:]
    let lock = NSLock()
    func record(for camera: String) -> HomeKitRecord? { lock.withLock { saved[camera] } }
    func save(_ record: HomeKitRecord, for camera: String) { lock.withLock { saved[camera] = record } }
    func remove(for camera: String) { _ = lock.withLock { saved.removeValue(forKey: camera) } }
}

@Suite struct CameraAccessoryTests {
    @Test func streamSettingsMatchHAPNodeJS() throws {
        // One resolution, to compare byte for byte with what HAP-NodeJS encodes for the same options.
        let video = CameraStreamOptions(resolutions: [(1280, 720, 30)]).supportedVideo
        // Computed by a port of HAP-NodeJS's tlv.encode and _supportedVideoStreamConfiguration.
        let expected = "012f010100021d0101000000010101000001010202010000000201010000020102030100030b010200050202d00203011e"
        #expect(video.map { String(format: "%02x", $0) }.joined() == expected)
        #expect(CameraStreamOptions.standard.supportedRTP == [0x02, 0x01, 0x00])
    }

    @Test func accessoryHasACameraAndAMotionSensor() {
        let camera = CameraAccessory(name: "Porch", details: AccessoryDetails(device: nil, cameraID: "porch"))
        #expect(camera.accessory.services.map(\.type) == ["3E", "A2", "110", "112", "85"])
        #expect(camera.accessory.services[2].primary)
        #expect(camera.motion.type == HAPType.motionDetected)
    }

    @Test func eachViewerSlotIsAStreamingServiceAfterTheRest() {
        func slots(_ n: Int) -> [StreamManagement] {
            (0 ..< n).map { _ in StreamManagement(main: ("rtsp://x/main", "u", "p"), sub: ("rtsp://x/sub", "u", "p")) { _ in } }
        }
        let one = CameraAccessory(name: "Porch", details: AccessoryDetails(device: nil, cameraID: "porch"), streams: slots(1))
        let two = CameraAccessory(name: "Porch", details: AccessoryDetails(device: nil, cameraID: "porch"), streams: slots(2))
        #expect(two.accessory.services.map(\.type) == ["3E", "A2", "110", "112", "85", "110"])
        // The services that were there keep their ids; only the shape's digest changes.
        #expect(Array(two.accessory.services.prefix(5).map(\.iid)) == one.accessory.services.map(\.iid))
        #expect(one.accessory.layoutDigest != two.accessory.layoutDigest)
        #expect(one.accessory.layoutDigest == CameraAccessory(name: "Other", details: AccessoryDetails(device: nil, cameraID: "x"),
                                                               streams: slots(1)).accessory.layoutDigest)
    }

    @Test func theConfigurationNumberGoesUpWhenTheShapeChanges() {
        let records = MemoryRecords()
        #expect(HomeKitHost.configNumber(for: "a", camera: "porch", records: records) == 1)   // no record yet
        records.save(.new(), for: "porch")
        // A record from before shapes were kept: served as 1, so the first shape kept is 2.
        #expect(HomeKitHost.configNumber(for: "a", camera: "porch", records: records) == 2)
        #expect(HomeKitHost.configNumber(for: "a", camera: "porch", records: records) == 2)
        #expect(HomeKitHost.configNumber(for: "b", camera: "porch", records: records) == 3)
        var record = records.record(for: "porch")!
        record.configNumber = 65535
        records.save(record, for: "porch")
        #expect(HomeKitHost.configNumber(for: "c", camera: "porch", records: records) == 1)
    }

    @Test func detailsFromTheCamera() {
        let device = Config.Device(manufacturer: "Reolink", model: "E1 Pro", serial: "1414", firmware: "v3.1.0.4417_2412122130")
        let details = AccessoryDetails(device: device, cameraID: "porch")
        #expect(details == AccessoryDetails(manufacturer: "Reolink", model: "E1 Pro", serial: "1414",
                                            firmware: "v3.1.0.4417_2412122130"))
        #expect(details.firmwareRevision == "3.1.0")
        let camera = CameraAccessory(name: "Porch", details: details)
        let info = camera.accessory.services[0]
        #expect(info.characteristic(HAPType.manufacturer)?.value == .string("Reolink"))
        #expect(info.characteristic(HAPType.model)?.value == .string("E1 Pro"))
        #expect(info.characteristic(HAPType.serialNumber)?.value == .string("1414"))
        #expect(info.characteristic(HAPType.firmwareRevision)?.value == .string("3.1.0"))
    }

    @Test func standInsWhenTheCameraSaidNothing() {
        let details = AccessoryDetails(device: nil, cameraID: "porch")
        #expect(details.serial == "porch")
        #expect(details.firmwareRevision == "1.0.0")
        #expect(AccessoryDetails(manufacturer: "A", model: "B", serial: "C", firmware: "build 7").firmwareRevision == "7")
        #expect(AccessoryDetails(manufacturer: "A", model: "B", serial: "C", firmware: "1.2.3.4").firmwareRevision == "1.2.3")
    }

    @Test func aDoorbellRingsThroughItsPrimaryDoorbellService() {
        let bell = CameraAccessory(name: "Front Door", details: AccessoryDetails(device: nil, cameraID: "door"), doorbell: true)
        let types = bell.accessory.services.map(\.type)
        #expect(types == ["3E", "A2", HAPType.doorbell, "110", "112", "85"])
        #expect(bell.accessory.services[2].primary)
        #expect(!bell.accessory.services[3].primary)
        let button = bell.accessory.services[2].characteristic(HAPType.programmableSwitchEvent)!
        #expect(button.value == .null)
        nonisolated(unsafe) var sent: [HAPValue] = []
        button.changed = { _, value in sent.append(value) }
        bell.ring()
        bell.ring()
        // Each press is sent, though the value is the same; reads stay null.
        #expect(sent == [.int(0), .int(0)])
        #expect(button.value == .null)
    }

    @Test func recordsAreMadeOnceAndKept() {
        let records = MemoryRecords()
        let host = HomeKitHost(records: records) { _ in }
        let first = host.record(for: "porch")
        #expect(SetupInfo.isValid(code: first.setupCode))
        #expect(host.record(for: "porch").deviceID == first.deviceID)
        #expect(host.record(for: "porch").setupCode == first.setupCode)
    }
}
