import Foundation
@testable import HAP
import Testing
@testable import HAPCamera

@Suite struct RecordingTests {
    @Test func supportedCameraRecordingIsAsHAPNodeJSEncodesIt() {
        let options = RecordingOptions(doorbell: false)
        // prebuffer 4000 (4 bytes), triggers motion (8 bytes), fMP4 with 4000 ms fragments.
        #expect(options.supportedCameraRecording == [0x01, 4, 0xA0, 0x0F, 0, 0,
                                                     0x02, 8, 1, 0, 0, 0, 0, 0, 0, 0,
                                                     0x03, 11, 0x01, 1, 0, 0x02, 6, 0x01, 4, 0xA0, 0x0F, 0, 0])
        #expect(RecordingOptions(doorbell: true).supportedCameraRecording[8] == 3)   // motion and the doorbell's button
    }

    @Test func supportedAudioRecordingListsItsSampleRates() {
        let audio = RecordingOptions(doorbell: false).supportedAudioRecording
        let rates: [UInt8] = [0x03, 1, 1, 0, 0, 0x03, 1, 2, 0, 0, 0x03, 1, 3, 0, 0, 0x03, 1, 5]
        let parameters: [UInt8] = [0x01, 1, 1, 0x02, 1, 0] + rates
        let codec: [UInt8] = [0x01, 1, 0, 0x02, UInt8(parameters.count)] + parameters
        #expect(audio == [0x01, UInt8(codec.count)] + codec)
    }

    /// A choice as the hub writes it: 1920×1080 at 30 fps, 2000 kbit/s, keyframes every 4000 ms, 4000 ms
    /// fragments after 4000 ms of prebuffer, AAC-LC mono at 16 kHz, 32 kbit/s.
    static var hubChoice: [UInt8] {
        func le32(_ v: Int) -> [UInt8] { RecordingOptions.le32(UInt32(v)) }
        let recording = CameraTLV.item(0x01, le32(4000)) + CameraTLV.item(0x02, le32(1) + [0, 0, 0, 0])
            + CameraTLV.item(0x03, CameraTLV.item(0x01, 0) + CameraTLV.item(0x02, CameraTLV.item(0x01, le32(4000))))
        let video = CameraTLV.item(0x01, 0)
            + CameraTLV.item(0x02, CameraTLV.item(0x01, 2) + CameraTLV.item(0x02, 2) + CameraTLV.item(0x03, le32(2000))
                + CameraTLV.item(0x04, le32(4000)))
            + CameraTLV.item(0x03, CameraTLV.item(0x01, CameraTLV.uint16(1920)) + CameraTLV.item(0x02, CameraTLV.uint16(1080))
                + CameraTLV.item(0x03, 30))
        let audio = CameraTLV.item(0x01, 0)
            + CameraTLV.item(0x02, CameraTLV.item(0x01, 1) + CameraTLV.item(0x02, 0) + CameraTLV.item(0x03, 1)
                + CameraTLV.item(0x04, le32(32)))
        return CameraTLV.item(0x01, recording) + CameraTLV.item(0x02, video) + CameraTLV.item(0x03, audio)
    }

    @Test func theHubsChoiceIsRead() throws {
        let choice = try #require(SelectedRecording(Self.hubChoice))
        #expect(choice.width == 1920 && choice.height == 1080 && choice.fps == 30)
        #expect(choice.bitrate == 2000 && choice.keyframeInterval == 4000 && choice.profile == 2)
        #expect(choice.prebuffer == 4000 && choice.fragmentLength == 4000 && choice.eventTriggers == 1)
        #expect(choice.audioCodec == 0 && choice.sampleRate == 1 && choice.audioBitrate == 32)
        #expect(SelectedRecording([1, 2, 3]) == nil)
    }

    @Test func recordingServicesComeAfterTheRestAndAreKept() throws {
        final class Kept: @unchecked Sendable { var states: [RecordingState] = [] }
        let kept = Kept()
        let recording = RecordingController(options: RecordingOptions(doorbell: false), state: nil) { _ in }
        recording.saved = { kept.states.append($0) }
        defer { recording.stop() }
        let plain = CameraAccessory(name: "Porch", details: AccessoryDetails(device: nil, cameraID: "porch"))
        let camera = CameraAccessory(name: "Porch", details: AccessoryDetails(device: nil, cameraID: "porch"), recording: recording)
        let types = camera.accessory.services.map(\.type)
        #expect(Array(types.prefix(plain.accessory.services.count)) == plain.accessory.services.map(\.type))
        #expect(Array(types.suffix(3)) == ["204", "21A", "129"])
        let management = try #require(camera.accessory.services.first { $0.type == "204" })
        #expect(management.linked.map(\.type) == ["129", "85"])          // the data stream, the motion sensor

        // The hub's choice and recording on, kept.
        _ = try management.characteristic(HAPType.selectedCameraRecordingConfiguration)!.write(.tlv8(Self.hubChoice))
        _ = try management.characteristic(HAPType.active)!.write(.int(1))
        #expect(kept.states.last?.active == true)
        #expect(kept.states.last?.selected == Self.hubChoice)
        #expect(throws: HAPStatus.self) { try management.characteristic(HAPType.selectedCameraRecordingConfiguration)!.write(.tlv8([9])) }
    }

    /// Private in Pond: off in the Home app; the Home app turning it on keeps its choice for later but doesn't
    /// end the privacy (the hub writes it again on reconnecting, and with home and away modes).
    @Test func privacyIsOneWay() throws {
        let recording = RecordingController(options: RecordingOptions(doorbell: false), state: nil) { _ in }
        defer { recording.stop() }
        let camera = CameraAccessory(name: "Porch", details: AccessoryDetails(device: nil, cameraID: "porch"), recording: recording)
        let mode = try #require(camera.accessory.services.first { $0.type == "21A" })
        let active = try #require(mode.characteristic(HAPType.homeKitCameraActive))
        #expect(active.value == .int(1))
        recording.setPrivate(true)
        #expect(active.value == .int(0))
        _ = try active.write(.int(1))
        #expect(!recording.cameraOn)
        // Privacy over: as the Home app last had it.
        recording.setPrivate(false)
        #expect(recording.cameraOn && active.value == .int(1))
        // The Home app's own off stays off when privacy ends.
        _ = try active.write(.int(0))
        recording.setPrivate(true)
        recording.setPrivate(false)
        #expect(!recording.cameraOn)
    }
}
