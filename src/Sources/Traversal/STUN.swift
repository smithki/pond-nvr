// STUN messages (RFC 5389, and RFC 8445's attributes for checks): what a device sends to learn the address the world sees
// it at, and what two devices send each other to check a path between them works (and only they: their checks carry
// MESSAGE-INTEGRITY, an HMAC under a password exchanged in their sealed offer and answer). Plain Swift: the signaling
// service (on Linux) answers binding requests with it, and Pond's PathFinder speaks it.
import Foundation

public struct STUNMessage: Equatable, Sendable {
    public var type: UInt16
    public var transaction: [UInt8]
    public var attributes: [Attribute]

    public static let cookie: UInt32 = 0x2112_A442

    // Message types.
    public static let bindingRequest: UInt16 = 0x0001, bindingSuccess: UInt16 = 0x0101, bindingError: UInt16 = 0x0111

    public struct Attribute: Equatable, Sendable {
        public var type: UInt16
        public var value: [UInt8]

        public init(_ type: UInt16, _ value: [UInt8]) {
            self.type = type
            self.value = value
        }

        public static let mappedAddress: UInt16 = 0x0001, username: UInt16 = 0x0006, messageIntegrity: UInt16 = 0x0008,
                           errorCode: UInt16 = 0x0009, xorMappedAddress: UInt16 = 0x0020, priority: UInt16 = 0x0024,
                           useCandidate: UInt16 = 0x0025, software: UInt16 = 0x8022, fingerprint: UInt16 = 0x8028,
                           iceControlled: UInt16 = 0x8029, iceControlling: UInt16 = 0x802A
    }

    public init(type: UInt16, transaction: [UInt8] = STUNMessage.newTransaction(), attributes: [Attribute] = []) {
        self.type = type
        self.transaction = transaction
        self.attributes = attributes
    }

    public static func newTransaction() -> [UInt8] { (0 ..< 12).map { _ in UInt8.random(in: 0 ... 255) } }

    public func attribute(_ type: UInt16) -> [UInt8]? { attributes.first { $0.type == type }?.value }

    // MARK: Writing

    /// The message as bytes: its attributes, then (with `integrity`, a key) MESSAGE-INTEGRITY, then FINGERPRINT.
    public func encoded(integrity key: [UInt8]? = nil, fingerprint: Bool = true) -> [UInt8] {
        var body: [UInt8] = []
        for attribute in attributes { body += Self.encode(attribute) }
        func header(length: Int) -> [UInt8] {
            Self.be16(type) + Self.be16(UInt16(length)) + Self.be32(Self.cookie) + transaction
        }
        if let key {
            // The HMAC is over the message so far, its length counting the integrity attribute (24 bytes).
            let mac = Hashes.hmac(key, header(length: body.count + 24) + body)
            body += Self.encode(Attribute(Attribute.messageIntegrity, mac))
        }
        if fingerprint {
            let crc = Hashes.crc32(header(length: body.count + 8) + body) ^ 0x5354_554E
            body += Self.encode(Attribute(Attribute.fingerprint, Self.be32(crc)))
        }
        return header(length: body.count) + body
    }

    static func encode(_ attribute: Attribute) -> [UInt8] {
        let padding = (4 - attribute.value.count % 4) % 4
        return be16(attribute.type) + be16(UInt16(attribute.value.count)) + attribute.value + [UInt8](repeating: 0, count: padding)
    }

    // MARK: Reading

    public enum Failure: Error, Equatable {
        case notSTUN
        case badIntegrity
        case badFingerprint
    }

    /// Whether bytes look like a STUN message (its first two bits clear, the magic cookie): told from media on the
    /// same port.
    public static func looksLikeSTUN(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 20 && bytes[0] & 0xC0 == 0 && be32(bytes, 4) == cookie
    }

    /// A message read; with `integrity`, its MESSAGE-INTEGRITY checked under that key (and required).
    public init(_ bytes: [UInt8], integrity key: [UInt8]? = nil) throws(Failure) {
        guard Self.looksLikeSTUN(bytes) else { throw .notSTUN }
        let length = Int(Self.be16(bytes, 2))
        guard bytes.count >= 20 + length, length % 4 == 0 else { throw .notSTUN }
        type = Self.be16(bytes, 0)
        transaction = Array(bytes[8 ..< 20])
        attributes = []
        var at = 20
        var integrityChecked = false
        while at + 4 <= 20 + length {
            let kind = Self.be16(bytes, at), size = Int(Self.be16(bytes, at + 2))
            guard at + 4 + size <= 20 + length else { throw .notSTUN }
            let value = Array(bytes[at + 4 ..< at + 4 + size])
            switch kind {
            case Attribute.messageIntegrity:
                if let key {
                    var header = Array(bytes[0 ..< 20])
                    header.replaceSubrange(2 ..< 4, with: Self.be16(UInt16(at + 24 - 20)))
                    guard Hashes.hmac(key, header + Array(bytes[20 ..< at])) == value else { throw .badIntegrity }
                    integrityChecked = true
                }
            case Attribute.fingerprint:
                var header = Array(bytes[0 ..< 20])
                header.replaceSubrange(2 ..< 4, with: Self.be16(UInt16(at + 8 - 20)))
                guard Self.be32(Hashes.crc32(header + Array(bytes[20 ..< at])) ^ 0x5354_554E) == value else { throw .badFingerprint }
            default:
                attributes.append(Attribute(kind, value))
            }
            at += 4 + size + (4 - size % 4) % 4
        }
        if key != nil, !integrityChecked { throw .badIntegrity }
    }

    // MARK: Bytes

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
}

/// An address and port, as STUN carries them (XOR-MAPPED-ADDRESS: XORed with the cookie and transaction, so NATs
/// that rewrite addresses in packets leave it alone).
public struct STUNAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// 4 bytes (IPv4) or 16 (IPv6).
    public var ip: [UInt8]
    public var port: UInt16

    public init(ip: [UInt8], port: UInt16) {
        self.ip = ip
        self.port = port
    }

    public var isIPv6: Bool { ip.count == 16 }

    public var description: String {
        if isIPv6 {
            let groups = stride(from: 0, to: 16, by: 2).map { String(UInt16(ip[$0]) << 8 | UInt16(ip[$0 + 1]), radix: 16) }
            return "[\(groups.joined(separator: ":"))]:\(port)"
        }
        return ip.map(String.init).joined(separator: ".") + ":\(port)"
    }

    /// XOR-MAPPED-ADDRESS's value.
    public func xorEncoded(transaction: [UInt8]) -> [UInt8] {
        let cookie = STUNMessage.be32(STUNMessage.cookie)
        let mask = cookie + transaction
        let port = self.port ^ UInt16(STUNMessage.cookie >> 16)
        return [0, isIPv6 ? 0x02 : 0x01] + STUNMessage.be16(port) + ip.enumerated().map { $1 ^ mask[$0] }
    }

    public init?(xorEncoded value: [UInt8], transaction: [UInt8]) {
        guard value.count >= 8 else { return nil }
        let family = value[1], length = family == 0x02 ? 16 : 4
        guard value.count >= 4 + length else { return nil }
        let mask = STUNMessage.be32(STUNMessage.cookie) + transaction
        port = STUNMessage.be16(value, 2) ^ UInt16(STUNMessage.cookie >> 16)
        ip = (0 ..< length).map { value[4 + $0] ^ mask[$0] }
    }
}
