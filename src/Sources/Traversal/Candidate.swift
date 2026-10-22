// Where a Pond (or a device) can be reached, as RFC 8445 puts it: a candidate is an address and port of one
// kind (the Mac's own, host; the one its router shows the world, server-reflexive, learned from STUN; one learned
// from a check's answer, peer-reflexive; or a relay's), with a priority. Each side sends the other its candidates
// in the sealed offer and answer; pairs of theirs and its own are then checked, best first.
import Foundation

public struct Candidate: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case host, srflx, prflx, relay

        /// RFC 8445's type preference: the Mac's own address first, a relay last.
        var preference: UInt32 {
            switch self {
            case .host: 126
            case .prflx: 110
            case .srflx: 100
            case .relay: 0
            }
        }
    }

    public var kind: Kind
    public var address: STUNAddress
    public var priority: UInt32

    public init(kind: Kind, address: STUNAddress, priority: UInt32? = nil) {
        self.kind = kind
        self.address = address
        self.priority = priority ?? Self.priority(kind, address)
    }

    /// RFC 8445 5.1.2.1, one component: type preference, then local preference (IPv6 a little before IPv4, as
    /// RFC 8421 has it: it needs no NAT, and a temporary address says less).
    public static func priority(_ kind: Kind, _ address: STUNAddress) -> UInt32 {
        let local: UInt32 = address.isIPv6 ? 65535 : 65534
        return kind.preference << 24 | local << 8 | (256 - 1)
    }

    public var description: String { "\(kind) \(address)" }
}

/// A local candidate and a remote one, of the same family, checked together.
public struct CandidatePair: Hashable, Sendable, CustomStringConvertible {
    public var local: Candidate
    public var remote: Candidate

    /// RFC 8445 6.1.2.3: G the controlling side's priority, D the controlled side's.
    public func priority(controlling: Bool) -> UInt64 {
        let g = UInt64(controlling ? local.priority : remote.priority), d = UInt64(controlling ? remote.priority : local.priority)
        return (1 << 32) * min(g, d) + 2 * max(g, d) + (g > d ? 1 : 0)
    }

    public var description: String { "\(local) → \(remote)" }
}

extension STUNAddress: Codable {
    /// As text: "203.0.113.5:4000" or "[2001:db8::1]:4000".
    public init?(_ text: String) {
        if text.hasPrefix("["), let close = text.lastIndex(of: "]"),
           let port = UInt16(text[text.index(after: close)...].dropFirst()) {
            guard let ip = Self.ipv6(String(text[text.index(after: text.startIndex) ..< close])) else { return nil }
            self.init(ip: ip, port: port)
        } else {
            let parts = text.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
            let octets = parts[0].split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { return nil }
            self.init(ip: octets, port: port)
        }
    }

    static func ipv6(_ text: String) -> [UInt8]? {
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        /// "2001:db8" as its groups; nil if one isn't hex.
        func groups(_ s: String) -> [UInt16]? {
            var out: [UInt16] = []
            for part in s.split(separator: ":") {
                guard let group = UInt16(part, radix: 16) else { return nil }
                out.append(group)
            }
            return out
        }
        guard let head = groups(halves[0]) else { return nil }
        var all = head
        if halves.count == 2 {
            guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return nil }
            all += [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail
        }
        guard all.count == 8 else { return nil }
        return all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let address = STUNAddress(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an address: \(text)"))
        }
        self = address
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
