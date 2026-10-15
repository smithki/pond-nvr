// The accessory on the network: a TCP listener advertised over Bonjour as _hap._tcp, with the TXT record
// the Home app reads (its ID, category, whether it is paired, and a hash for matching the setup QR code).
import CryptoKit
import Foundation
import Network

/// What a setup code and QR code need, and the Bonjour TXT record.
public struct SetupInfo: Sendable, Equatable {
    /// "XXX-XX-XXX".
    public let code: String
    /// Four characters, shown in the QR code and hashed into Bonjour so the Home app can find the accessory.
    public let setupID: String

    public init(code: String, setupID: String) {
        self.code = code
        self.setupID = setupID
    }

    /// Codes HomeKit refuses.
    static let refused: Set<String> = ["000-00-000", "111-11-111", "222-22-222", "333-33-333", "444-44-444",
                                       "555-55-555", "666-66-666", "777-77-777", "888-88-888", "999-99-999",
                                       "123-45-678", "876-54-321"]

    public static func isValid(code: String) -> Bool {
        let digits = code.filter(\.isNumber)
        return code.count == 10 && digits.count == 8 && code.split(separator: "-").map(\.count) == [3, 2, 3]
            && !refused.contains(code)
    }

    public static func generate() -> SetupInfo {
        var code: String
        repeat {
            let d = (0 ..< 8).map { _ in String(Int.random(in: 0 ... 9)) }
            code = "\(d[0 ..< 3].joined())-\(d[3 ..< 5].joined())-\(d[5 ..< 8].joined())"
        } while !isValid(code: code)
        let letters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return SetupInfo(code: code, setupID: String((0 ..< 4).map { _ in letters.randomElement()! }))
    }

    /// The X-HM:// URI a setup QR code holds: version, category, "IP" flag and the code, in base 36.
    public func uri(category: Int) -> String {
        var payload: UInt64 = 0
        payload = (payload << 4) | 0            // version and reserved
        payload = (payload << 8) | UInt64(category & 0xFF)
        payload = (payload << 4) | 2            // supports HAP over IP
        payload = (payload << 27) | (UInt64(code.filter(\.isNumber)) ?? 0) & 0x7FF_FFFF
        let encoded = String(payload, radix: 36, uppercase: true)
        return "X-HM://" + String(repeating: "0", count: max(0, 9 - encoded.count)) + encoded + setupID
    }

    /// Bonjour's "sh": the first 4 bytes of SHA-512(setup ID + device ID), base64.
    public func setupHash(deviceID: String) -> String {
        Data(SHA512.hash(data: Array((setupID + deviceID).utf8)).prefix(4)).base64EncodedString()
    }
}

/// HAP accessory categories (the icon in the Home app before setup).
public enum AccessoryCategory: Int, Sendable {
    case bridge = 2
    case sensor = 10
    case ipCamera = 17
    case videoDoorbell = 18
}

/// Serves one accessory on the network.
public final class HAPListener: @unchecked Sendable {
    let server: AccessoryServer
    let name: String
    let model: String
    let category: AccessoryCategory
    let setup: SetupInfo
    /// The database's version; raise it when services change.
    public var configNumber = 1
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hap.listener")
    public private(set) var port: UInt16?
    public var log: (@Sendable (String) -> Void)?

    public init(server: AccessoryServer, name: String, model: String, category: AccessoryCategory, setup: SetupInfo) {
        self.server = server
        self.name = name
        self.model = model
        self.category = category
        self.setup = setup
    }

    var txtRecord: NWTXTRecord {
        var txt = NWTXTRecord()
        txt["c#"] = String(configNumber)
        txt["ff"] = "0"
        txt["id"] = server.identity.deviceID
        txt["md"] = model
        txt["pv"] = "1.1"
        txt["s#"] = "1"
        txt["sf"] = server.isPaired ? "0" : "1"
        txt["ci"] = String(category.rawValue)
        txt["sh"] = setup.setupHash(deviceID: server.identity.deviceID)
        return txt
    }

    /// Starts listening (on `port`, or any free port) and advertising.
    public func start(port: UInt16? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
        listener.service = NWListener.Service(name: name, type: "_hap._tcp", txtRecord: txtRecord)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue
                self.log?("HomeKit: \(self.name) listening on port \(listener.port?.rawValue ?? 0)")
            case let .failed(error):
                self.log?("HomeKit: \(self.name) stopped: \(error)")
            default:
                break
            }
        }
        // Added to whatever else listens for pairing changes (the host's status), not instead of it.
        let others = server.pairingsChanged
        server.pairingsChanged = { [weak self] in
            others?()
            self?.refreshAdvertisement()
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Updates the TXT record, after pairing or unpairing.
    public func refreshAdvertisement() {
        queue.async { [weak self] in
            guard let self, let listener = self.listener else { return }
            listener.service = NWListener.Service(name: self.name, type: "_hap._tcp", txtRecord: self.txtRecord)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        let hap = server.connect { bytes in
            connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: hap.closed()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, hap)
    }

    private func receive(_ connection: NWConnection, _ hap: HAPConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            if let data, !data.isEmpty { hap.receive(Array(data)) }
            if done || error != nil || hap.shouldClose {
                connection.cancel()
                return
            }
            self?.receive(connection, hap)
        }
    }
}
