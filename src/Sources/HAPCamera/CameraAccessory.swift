// A camera as a HomeKit accessory: Accessory Information, Protocol Information, Camera RTP Stream Management
// (the camera itself, with the stream settings it offers, and live view through StreamManagement), a
// Microphone, a Speaker when the camera can be talked through (the Home app then offers to talk back), and a
// Motion Sensor. Without a StreamManagement, stream setups are answered "error".
import Devices
import Foundation
import HAP
import NVRCore

/// TLV items nested as camera settings use them: lists are kept apart by an empty item of type 0.
enum CameraTLV {
    static func item(_ type: UInt8, _ value: [UInt8]) -> [UInt8] { TLV8.encode([TLV8Item(type, value)]) }
    static func item(_ type: UInt8, _ byte: UInt8) -> [UInt8] { item(type, [byte]) }
    /// The same type for each entry, with empty type-0 items between.
    static func list(_ type: UInt8, _ entries: [[UInt8]]) -> [UInt8] {
        entries.enumerated().flatMap { i, e in (i == 0 ? [] : [0, 0]) + item(type, e) }
    }
    static func uint16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
}

public struct CameraStreamOptions: Sendable {
    /// Width, height and frame rate the camera can be asked for.
    public var resolutions: [(Int, Int, Int)]

    public init(resolutions: [(Int, Int, Int)]) { self.resolutions = resolutions }

    /// What HomeKit asks of a Reolink E1: up to its sub-stream's frame rate, in HomeKit's usual sizes.
    public static let standard = CameraStreamOptions(resolutions: [
        (1920, 1080, 30), (1280, 720, 30), (640, 360, 30), (480, 270, 30), (320, 180, 30),
        (1280, 960, 30), (1024, 768, 30), (640, 480, 30), (480, 360, 30), (320, 240, 15),
    ])

    var supportedVideo: [UInt8] {
        let params = CameraTLV.list(0x01, [[0], [1], [2]])       // profiles: baseline, main, high
            + CameraTLV.list(0x02, [[0], [1], [2]])               // levels 3.1, 3.2, 4.0
            + CameraTLV.item(0x03, 0)                             // packetization: non-interleaved
        let attributes = CameraTLV.list(0x03, resolutions.map { w, h, fps in
            CameraTLV.item(0x01, CameraTLV.uint16(w)) + CameraTLV.item(0x02, CameraTLV.uint16(h)) + CameraTLV.item(0x03, UInt8(fps))
        })
        let config = CameraTLV.item(0x01, 0) + CameraTLV.item(0x02, params) + attributes   // H.264
        return CameraTLV.item(0x01, config)
    }

    /// AAC-ELD only (what `AudioTranscoder` makes), mono, variable bit rate, 16 and 24 kHz; no comfort noise.
    var supportedAudio: [UInt8] {
        let params = CameraTLV.item(0x01, 1) + CameraTLV.item(0x02, 0) + CameraTLV.list(0x03, [[1], [2]])
        return CameraTLV.item(0x01, CameraTLV.item(0x01, 2) + CameraTLV.item(0x02, params)) + CameraTLV.item(0x02, 0)
    }

    /// SRTP with AES-CM-128 and HMAC-SHA1-80.
    var supportedRTP: [UInt8] { CameraTLV.item(0x02, 0) }
}

/// What the Home app shows under the accessory's details.
public struct AccessoryDetails: Equatable, Sendable {
    public var manufacturer: String
    public var model: String
    public var serial: String
    /// As the camera gives it; HomeKit is sent only its leading numbers (see `firmwareRevision`).
    public var firmware: String?

    public init(manufacturer: String, model: String, serial: String, firmware: String? = nil) {
        self.manufacturer = manufacturer
        self.model = model
        self.serial = serial
        self.firmware = firmware
    }

    /// From what the camera said it is, with stand-ins where it said nothing.
    public init(device: Config.Device?, cameraID: String) {
        let maker = device?.manufacturer.trimmingCharacters(in: .whitespaces) ?? ""
        let model = device?.model.trimmingCharacters(in: .whitespaces) ?? ""
        self.init(manufacturer: maker.isEmpty ? Brand.name : maker, model: model.isEmpty ? "Camera" : model,
                  serial: device?.serial ?? cameraID, firmware: device?.firmware)
    }

    /// HomeKit takes a firmware revision only as up to three numbers ("3.1.0"): the first such run in the
    /// camera's version ("v3.1.0.4417_2412122130"), else 1.0.0.
    public var firmwareRevision: String {
        guard let firmware, let range = firmware.range(of: #"\d+(\.\d+){0,2}"#, options: .regularExpression) else {
            return "1.0.0"
        }
        return String(firmware[range])
    }
}

/// The accessory for one camera, and the characteristics the host drives.
public final class CameraAccessory: @unchecked Sendable {
    public let accessory: Accessory
    public let motion: Characteristic
    /// A doorbell's button, for `ring()`; nil for a camera.
    let doorbellButton: Characteristic?

    let streams: [StreamManagement]

    /// HomeKit Secure Video's services and state, for a camera set to record in HomeKit.
    let recording: RecordingController?

    init(name: String, details: AccessoryDetails, doorbell: Bool = false, options: CameraStreamOptions = .standard,
         streams: [StreamManagement] = [], recording: RecordingController? = nil,
         speaker openSpeaker: (@Sendable () async -> (any TalkSession)?)? = nil) {
        self.recording = recording
        self.streams = streams
        self.details = details
        let info = Service(type: HAPType.accessoryInformation, [
            Characteristic(type: HAPType.identify, format: .bool, permissions: [.write]),
            Characteristic(type: HAPType.manufacturer, format: .string, permissions: [.read], value: .string(details.manufacturer)),
            Characteristic(type: HAPType.model, format: .string, permissions: [.read], value: .string(details.model)),
            Characteristic(type: HAPType.name, format: .string, permissions: [.read], value: .string(name)),
            Characteristic(type: HAPType.serialNumber, format: .string, permissions: [.read], value: .string(details.serial)),
            Characteristic(type: HAPType.firmwareRevision, format: .string, permissions: [.read],
                           value: .string(details.firmwareRevision)),
        ])
        let protocolInfo = Service(type: HAPType.protocolInformation, [
            Characteristic(type: HAPType.version, format: .string, permissions: [.read], value: .string("1.1.0")),
        ])

        let mute = Characteristic(type: HAPType.mute, format: .bool, permissions: [.read, .write, .notify], value: .bool(false))
        let microphone = Service(type: HAPType.microphone, [mute])
        // One stream management service per viewer at once (each its own slot); without streams, one that
        // answers stream setups "error".
        let slots = streams.isEmpty ? [nil] : streams.map(Optional.some)
        let streaming = slots.map { Self.streamingService(options: options, streams: $0, mute: mute) }
        streamingStatus = streaming.map { $0.characteristic(HAPType.streamingStatus)! }
        motion = Characteristic(type: HAPType.motionDetected, format: .bool, permissions: [.read, .notify], value: .bool(false))
        let motionSensor = Service(type: HAPType.motionSensor, [
            motion,
            Characteristic(type: HAPType.statusActive, format: .bool, permissions: [.read, .notify], value: .bool(true)),
        ])
        // The first slot where it always was; any more after the rest, so the others keep their ids.
        var services = [info, protocolInfo, streaming[0], microphone, motionSensor] + streaming.dropFirst()
        if doorbell {
            // Single press (0) only; reads are null, as the button has no state, only presses.
            let button = Characteristic(type: HAPType.programmableSwitchEvent, format: .uint8, permissions: [.read, .notify])
            button.validValues = [0]
            button.minValue = 0
            button.maxValue = 0
            let bell = Service(type: HAPType.doorbell, [button])
            bell.primary = true
            services.insert(bell, at: 2)
            doorbellButton = button
        } else {
            streaming[0].primary = true
            doorbellButton = nil
        }
        // Recording's services after all the rest, so theirs keep their ids.
        if let recording {
            // The motion sensor linked to it, not a doorbell's button (as HAP-NodeJS links them): linked too, the hub
            // took a doorbell's recordings (valid, and its notifications sent) and kept none of them.
            services += recording.services(sensors: [motionSensor], statusActive: [motionSensor.characteristic(HAPType.statusActive)!])
        }
        // Talking back: a speaker (muted and how loud, as the Home app sets them), last of all: added before the
        // recording services, it moved theirs, and the hub stopped asking to record (it keeps them by their ids).
        if let openSpeaker {
            let speakerMute = Characteristic(type: HAPType.mute, format: .bool, permissions: [.read, .write, .notify],
                                             value: .bool(false))
            let volume = Characteristic(type: HAPType.volume, format: .uint8, permissions: [.read, .write, .notify],
                                        value: .int(100))
            volume.minValue = 0
            volume.maxValue = 100
            services.append(Service(type: HAPType.speaker, [speakerMute, volume]))
            for stream in streams {
                stream.openSpeaker = openSpeaker
                stream.speakerMuted = { speakerMute.value == .bool(true) }
                stream.speakerVolume = { if case let .int(level) = volume.value { Double(level) / 100 } else { 1 } }
            }
        }
        accessory = Accessory(services: services)
    }

    /// The model shown in the Home app.
    public var model: String { details.model }
    let details: AccessoryDetails
    private let streamingStatus: [Characteristic]

    /// Tells the Home app whether a slot is streaming now.
    func setStreaming(_ inUse: Bool, slot: Int = 0) {
        guard streamingStatus.indices.contains(slot) else { return }
        streamingStatus[slot].update(.tlv8(StreamManagement.status(inUse ? 1 : 0)))
    }

    /// A camera RTP stream management service, driven by `streams` (or answering "error" without).
    static func streamingService(options: CameraStreamOptions, streams: StreamManagement?, mute: Characteristic) -> Service {
        let endpoints = Characteristic(type: HAPType.setupEndpoints, format: .tlv8, permissions: [.read, .write],
                                       value: .tlv8(CameraTLV.item(0x02, 2)))
        let selected = Characteristic(type: HAPType.selectedRTPStreamConfiguration, format: .tlv8,
                                      permissions: [.read, .write], value: .tlv8([]))
        let service = Service(type: HAPType.cameraRTPStreamManagement, [
            Characteristic(type: HAPType.supportedVideoStreamConfiguration, format: .tlv8, permissions: [.read],
                           value: .tlv8(options.supportedVideo)),
            Characteristic(type: HAPType.supportedAudioStreamConfiguration, format: .tlv8, permissions: [.read],
                           value: .tlv8(options.supportedAudio)),
            Characteristic(type: HAPType.supportedRTPConfiguration, format: .tlv8, permissions: [.read],
                           value: .tlv8(options.supportedRTP)),
            selected,
            Characteristic(type: HAPType.streamingStatus, format: .tlv8, permissions: [.read, .notify],
                           value: .tlv8(CameraTLV.item(0x01, 0))),
            endpoints,
            Characteristic(type: HAPType.active, format: .uint8, permissions: [.read, .write, .notify], value: .int(1)),
        ])
        if let streams {
            endpoints.onWrite = { value throws(HAPStatus) in
                guard case let .tlv8(bytes) = value else { throw .invalidValue }
                return .tlv8(streams.setupEndpoints(bytes))
            }
            selected.onWrite = { value throws(HAPStatus) in
                guard case let .tlv8(bytes) = value else { throw .invalidValue }
                streams.selectedConfiguration(bytes)
                return nil
            }
            streams.microphoneMuted = { mute.value == .bool(true) }
        }
        return service
    }

    /// The doorbell was pressed: the Home app rings and shows who is there.
    public func ring() {
        doorbellButton?.sendEvent(.int(0))
    }
}
