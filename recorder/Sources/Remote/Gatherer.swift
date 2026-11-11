// This Mac's own addresses, as candidates for a path (its host candidates). Only what's worth offering, and only
// what says little about the Mac: its physical network interfaces (Wi-Fi, Ethernet: en*), never virtual machines'
// bridges, VPN tunnels, AirDrop's links or loopback; IPv4 without link-local; IPv6 only its temporary addresses
// (RFC 4941: they change every day or so, and don't come from the hardware), global ones, never the stable
// address. In mesh mode only the mesh's tunnel addresses (Tailscale's and Headscale's ranges, or a subnet given).
import Darwin
import Foundation
import Traversal

public enum Gatherer {
    public enum Mode: Equatable, Sendable {
        case direct
        /// Only addresses in the mesh (its tunnel interfaces): no public address learned, no relay.
        case mesh(subnets: [Subnet])
    }

    /// Tailscale's (and so Headscale's) ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    public static let tailnet = [Subnet("100.64.0.0/10")!, Subnet("fd7a:115c:a1e0::/48")!]

    /// The host candidates for a socket on `port`.
    public static func hosts(port: UInt16, mode: Mode = .direct) -> [Candidate] {
        interfaces().compactMap { interface -> Candidate? in
            let address = STUNAddress(ip: interface.ip, port: port)
            switch mode {
            case .direct:
                guard interface.name.hasPrefix("en") else { return nil }
                if address.isIPv6 {
                    guard interface.ip[0] & 0xE0 == 0x20, temporary(interface) else { return nil }   // global (2000::/3), temporary
                } else {
                    guard !(interface.ip[0] == 169 && interface.ip[1] == 254), interface.ip[0] != 127 else { return nil }
                }
            case let .mesh(subnets):
                guard subnets.contains(where: { $0.contains(interface.ip) }) else { return nil }
            }
            return Candidate(kind: .host, address: address)
        }
    }

    struct Interface {
        var name: String
        var ip: [UInt8]
    }

    /// Every address of every interface that's up.
    static func interfaces() -> [Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var found: [Interface] = []
        var next = first
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                found.append(Interface(name: name, ip: withUnsafeBytes(of: &a) { Array($0) }))
            case AF_INET6:
                var a = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                found.append(Interface(name: name, ip: withUnsafeBytes(of: &a) { Array($0) }))
            default:
                continue
            }
        }
        return found
    }

    /// Whether an IPv6 address is a temporary one (and not yet deprecated), as the kernel marks it: SIOCGIFAFLAG_IN6
    /// (its in6_ifreq built by hand, as the header's macros don't reach Swift).
    static func temporary(_ interface: Interface) -> Bool {
        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // struct in6_ifreq: the interface's name (16 bytes), then a union: the address (a sockaddr_in6) in, the
        // address's flags (an int) out; 288 bytes in all.
        var request = [UInt8](repeating: 0, count: 288)
        for (i, byte) in interface.name.utf8.prefix(15).enumerated() { request[i] = byte }
        request[16] = UInt8(MemoryLayout<sockaddr_in6>.size)
        request[17] = UInt8(AF_INET6)
        for (i, byte) in interface.ip.enumerated() { request[16 + 8 + i] = byte }
        let SIOCGIFAFLAG_IN6: UInt = 0xC120_6949
        let IN6_IFF_DEPRECATED: Int32 = 0x10, IN6_IFF_TEMPORARY: Int32 = 0x80
        guard ioctl(fd, SIOCGIFAFLAG_IN6, &request) == 0 else { return false }
        let flags = request[16 ..< 20].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        return flags & IN6_IFF_TEMPORARY != 0 && flags & IN6_IFF_DEPRECATED == 0
    }
}

/// A range of addresses: "100.64.0.0/10", "fd7a:115c:a1e0::/48".
public struct Subnet: Equatable, Sendable, CustomStringConvertible {
    public var base: [UInt8]
    public var bits: Int

    public init?(_ text: String) {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]) else { return nil }
        let host = String(parts[0])
        let base = host.contains(":") ? STUNAddress("[\(host)]:0")?.ip : STUNAddress("\(host):0")?.ip
        guard let base, bits >= 0, bits <= base.count * 8 else { return nil }
        self.base = base
        self.bits = bits
    }

    public func contains(_ ip: [UInt8]) -> Bool {
        guard ip.count == base.count else { return false }
        for bit in 0 ..< bits where (ip[bit / 8] ^ base[bit / 8]) & (0x80 >> UInt8(bit % 8)) != 0 { return false }
        return true
    }

    public var description: String { "\(STUNAddress(ip: base, port: 0).description.dropLast(2))/\(bits)" }
}
