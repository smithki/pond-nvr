// The accessory database: accessories hold services, services hold characteristics, each with an instance
// ID (iid). Controllers read it whole as JSON (GET /accessories), then read, write and subscribe to single
// characteristics by "aid.iid".
import CryptoKit
import Foundation

/// A characteristic's value as JSON carries it. TLV8 and data values travel base64-encoded.
public enum HAPValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case tlv8([UInt8])
    case null

    var json: Any {
        switch self {
        case let .bool(b): b
        case let .int(i): i
        case let .double(d): d
        case let .string(s): s
        case let .tlv8(bytes): Data(bytes).base64EncodedString()
        case .null: NSNull()
        }
    }

    /// A value written by a controller, read in this characteristic's format.
    static func from(json: Any, format: Characteristic.Format) -> HAPValue? {
        switch format {
        case .bool:
            if let b = json as? Bool { return .bool(b) }
            if let n = json as? NSNumber { return .bool(n.intValue != 0) }
        case .uint8, .uint16, .uint32, .uint64, .int:
            if let n = json as? NSNumber { return .int(n.intValue) }
        case .float:
            if let n = json as? NSNumber { return .double(n.doubleValue) }
        case .string:
            if let s = json as? String { return .string(s) }
        case .tlv8, .data:
            if let s = json as? String, let d = Data(base64Encoded: s) { return .tlv8(Array(d)) }
        }
        return nil
    }
}

/// HAP's status codes for characteristic reads and writes.
public enum HAPStatus: Int, Error, Sendable {
    case success = 0
    case insufficientPrivileges = -70401
    case communicationFailure = -70402
    case busy = -70403
    case readOnly = -70404
    case writeOnly = -70405
    case notificationNotSupported = -70406
    case outOfResources = -70407
    case timedOut = -70408
    case resourceDoesNotExist = -70409
    case invalidValue = -70410
    case insufficientAuthorization = -70411
}

public final class Characteristic: @unchecked Sendable {
    public enum Format: String, Sendable { case bool, uint8, uint16, uint32, uint64, int, float, string, tlv8, data }

    public struct Permissions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let read = Permissions(rawValue: 1)
        public static let write = Permissions(rawValue: 2)
        public static let notify = Permissions(rawValue: 4)
        public static let writeResponse = Permissions(rawValue: 8)
        public static let timedWrite = Permissions(rawValue: 16)
        public static let hidden = Permissions(rawValue: 32)

        var strings: [String] {
            [(Self.read, "pr"), (.write, "pw"), (.notify, "ev"), (.writeResponse, "wr"), (.timedWrite, "tw"), (.hidden, "hd")]
                .filter { contains($0.0) }.map(\.1)
        }
    }

    /// The short form of an Apple-defined type ("25" for On), or a full UUID.
    public let type: String
    public let format: Format
    public let permissions: Permissions
    public internal(set) var iid = 0
    public var minValue: Double?
    public var maxValue: Double?
    public var minStep: Double?
    public var validValues: [Int]?
    public var maxLength: Int?
    var stored: HAPValue
    /// Computes the value on read, instead of the stored one.
    public var onRead: (@Sendable () -> HAPValue)?
    /// Takes a write; returns the write-response value for TLV8 control points, or throws a status.
    public var onWrite: (@Sendable (HAPValue) throws(HAPStatus) -> HAPValue?)?
    /// Called when the value changes (or an event is sent), to notify subscribers with this value.
    var changed: (@Sendable (Characteristic, HAPValue) -> Void)?
    let lock = NSLock()

    public init(type: String, format: Format, permissions: Permissions, value: HAPValue = .null) {
        self.type = type
        self.format = format
        self.permissions = permissions
        stored = value
    }

    public var value: HAPValue {
        if let onRead { return onRead() }
        return lock.withLock { stored }
    }

    /// Sets the value from the accessory's side, notifying subscribed controllers if it changed.
    public func update(_ value: HAPValue) {
        let differs = lock.withLock {
            defer { stored = value }
            return stored != value
        }
        if differs { changed?(self, value) }
    }

    /// Sends `value` to subscribed controllers as an event, whatever the value was: for stateless
    /// characteristics such as a doorbell's Programmable Switch Event, where each press is news. Reads still
    /// get the stored value (null for those).
    public func sendEvent(_ value: HAPValue) {
        changed?(self, value)
    }

    /// Writes a value. A control point that answers (Setup Endpoints) keeps its answer as its value, since
    /// controllers read it back after writing.
    func write(_ value: HAPValue) throws(HAPStatus) -> HAPValue? {
        let response = try onWrite?(value)
        lock.withLock { stored = response ?? value }
        return response
    }

    func json(aid: Int, includeValue: Bool) -> [String: Any] {
        var d: [String: Any] = ["iid": iid, "type": type, "format": format.rawValue, "perms": permissions.strings]
        if includeValue, permissions.contains(.read) { d["value"] = value.json }
        if let minValue { d["minValue"] = minValue }
        if let maxValue { d["maxValue"] = maxValue }
        if let minStep { d["minStep"] = minStep }
        if let validValues { d["valid-values"] = validValues }
        if let maxLength { d["maxLen"] = maxLength }
        return d
    }
}

public final class Service: @unchecked Sendable {
    public let type: String
    public let characteristics: [Characteristic]
    public var primary = false
    public var hidden = false
    public var linked: [Service] = []
    public internal(set) var iid = 0

    public init(type: String, _ characteristics: [Characteristic]) {
        self.type = type
        self.characteristics = characteristics
    }

    public func characteristic(_ type: String) -> Characteristic? { characteristics.first { $0.type == type } }
}

public final class Accessory: @unchecked Sendable {
    public let aid: Int
    public let services: [Service]

    /// Numbers the services and characteristics from 1, in order.
    public init(aid: Int = 1, services: [Service]) {
        self.aid = aid
        self.services = services
        var next = 1
        for service in services {
            service.iid = next
            next += 1
            for c in service.characteristics {
                c.iid = next
                next += 1
            }
        }
    }

    public func characteristic(iid: Int) -> Characteristic? {
        for s in services { if let c = s.characteristics.first(where: { $0.iid == iid }) { return c } }
        return nil
    }

    /// The database's shape (services, characteristics, their ids, formats and permissions, not values), as
    /// a digest: when it changes, the configuration number must go up so controllers fetch it again.
    public var layoutDigest: String {
        var text = ""
        for s in services {
            text += "S\(s.iid) \(s.type) \(s.primary) \(s.hidden) \(s.linked.map(\.iid))\n"
            for c in s.characteristics {
                text += "C\(c.iid) \(c.type) \(c.format.rawValue) \(c.permissions.strings)\n"
            }
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func json() -> [String: Any] {
        ["aid": aid, "services": services.map { s in
            var d: [String: Any] = ["iid": s.iid, "type": s.type,
                                    "characteristics": s.characteristics.map { $0.json(aid: aid, includeValue: true) }]
            if s.primary { d["primary"] = true }
            if s.hidden { d["hidden"] = true }
            if !s.linked.isEmpty { d["linked"] = s.linked.map(\.iid) }
            return d
        }]
    }
}

/// Apple's type codes used here (HAP spec, short form).
public enum HAPType {
    // Services
    public static let accessoryInformation = "3E"
    public static let protocolInformation = "A2"
    public static let motionSensor = "85"
    public static let doorbell = "121"
    public static let cameraRTPStreamManagement = "110"
    public static let microphone = "112"
    public static let speaker = "113"
    public static let cameraRecordingManagement = "204"
    public static let cameraOperatingMode = "21A"
    public static let dataStreamTransportManagement = "129"
    public static let supportedCameraRecordingConfiguration = "205"
    public static let supportedVideoRecordingConfiguration = "206"
    public static let supportedAudioRecordingConfiguration = "207"
    public static let selectedCameraRecordingConfiguration = "209"
    public static let recordingAudioActive = "226"
    public static let homeKitCameraActive = "21B"
    public static let eventSnapshotsActive = "223"
    public static let periodicSnapshotsActive = "225"
    // Characteristics
    public static let identify = "14"
    public static let manufacturer = "20"
    public static let model = "21"
    public static let name = "23"
    public static let serialNumber = "30"
    public static let firmwareRevision = "52"
    public static let version = "37"
    public static let motionDetected = "22"
    public static let programmableSwitchEvent = "73"
    public static let statusActive = "75"
    public static let mute = "11A"
    public static let volume = "119"
    public static let streamingStatus = "120"
    public static let supportedVideoStreamConfiguration = "114"
    public static let supportedAudioStreamConfiguration = "115"
    public static let supportedRTPConfiguration = "116"
    public static let selectedRTPStreamConfiguration = "117"
    public static let setupEndpoints = "118"
    public static let active = "B0"
}
