// Pond's own sensor in HomeKit: an accessory of its own ("Pond"), a contact sensor named "Recording", closed while
// recording goes as it should and open when it doesn't (RecordingAlert), with its fault flag set too. The Home app
// can notify when a contact sensor opens, wherever one is, with no server of Pond's.
import Foundation
import HAP
import PondCore

public final class StatusSensor: @unchecked Sendable {
    public let accessory: Accessory
    let contact: Characteristic
    let fault: Characteristic

    public init(name: String) {
        let info = Service(type: HAPType.accessoryInformation, [
            Characteristic(type: HAPType.identify, format: .bool, permissions: [.write]),
            Characteristic(type: HAPType.manufacturer, format: .string, permissions: [.read], value: .string(Brand.name)),
            Characteristic(type: HAPType.model, format: .string, permissions: [.read], value: .string("Recording status")),
            Characteristic(type: HAPType.name, format: .string, permissions: [.read], value: .string(name)),
            Characteristic(type: HAPType.serialNumber, format: .string, permissions: [.read], value: .string("status")),
            Characteristic(type: HAPType.firmwareRevision, format: .string, permissions: [.read],
                           value: .string(Self.firmware(Brand.version))),
        ])
        let protocolInfo = Service(type: HAPType.protocolInformation, [
            Characteristic(type: HAPType.version, format: .string, permissions: [.read], value: .string("1.1.0")),
        ])
        // 0: contact detected (closed, all well); 1: not detected (open).
        contact = Characteristic(type: HAPType.contactSensorState, format: .uint8, permissions: [.read, .notify], value: .int(0))
        contact.minValue = 0
        contact.maxValue = 1
        contact.validValues = [0, 1]
        fault = Characteristic(type: HAPType.statusFault, format: .uint8, permissions: [.read, .notify], value: .int(0))
        fault.minValue = 0
        fault.maxValue = 1
        fault.validValues = [0, 1]
        let sensor = Service(type: HAPType.contactSensor, [
            contact, fault,
            Characteristic(type: HAPType.name, format: .string, permissions: [.read], value: .string("Recording")),
        ])
        sensor.primary = true
        accessory = Accessory(services: [info, protocolInfo, sensor])
    }

    /// Open (something's wrong) or closed.
    public func set(open: Bool) {
        contact.update(.int(open ? 1 : 0))
        fault.update(.int(open ? 1 : 0))
    }

    public var isOpen: Bool { contact.value == .int(1) }

    /// HomeKit takes up to three numbers ("1.4.2").
    static func firmware(_ version: String) -> String {
        guard let range = version.range(of: #"\d+(\.\d+){0,2}"#, options: .regularExpression) else { return "1.0.0" }
        return String(version[range])
    }
}
