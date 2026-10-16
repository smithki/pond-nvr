// Reolink cameras on the local network, found Reolink's own way: they don't answer ONVIF discovery, but each
// answers a 4-byte broadcast to UDP port 2000 (AA AA 00 00) with 388 bytes to port 3000: its address, the
// name it was given, its MAC address and a unique ID, at fixed places. Not documented by Reolink; as worked
// out by the community (ha_reolink_discovery for Home Assistant). No login.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A Reolink camera that answered.
public struct ReolinkFound: Equatable, Sendable {
    public var host: String
    /// The name it was given in Reolink's app ("Garage Camera").
    public var name: String?
    /// Its MAC address ("EC:71:DB:00:00:01"): the same whatever its address.
    public var mac: String?
    public var uuid: String?
}

public enum ReolinkDiscovery {
    static let askPort: UInt16 = 2000
    static let answerPort: UInt16 = 3000
    /// What is sent, and what an answer repeats (bytes 104–107) to show it is one.
    static let ping: [UInt8] = [0xAA, 0xAA, 0x00, 0x00]

    /// The Reolink cameras that answer within `seconds`, one each.
    public static func probe(seconds: Double = 3) async -> [ReolinkFound] {
        await Task.detached { probeNow(seconds: seconds) }.value
    }

    static func probeNow(seconds: Double) -> [ReolinkFound] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 150_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        // The answers come to port 3000 (whatever port asked).
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = answerPort.bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return [] }

        // Each local network's own broadcast address (macOS refuses 255.255.255.255).
        let broadcasts = NetworkScan.localNetworks().map { $0.address | ~$0.mask }
        func ask() {
            for broadcast in broadcasts {
                var to = sockaddr_in()
                to.sin_family = sa_family_t(AF_INET)
                to.sin_port = askPort.bigEndian
                to.sin_addr.s_addr = broadcast.bigEndian
                _ = withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, ping, ping.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        // Asked again now and then: UDP can drop it, and a process's first sends fail while macOS decides
        // whether it may use the local network.
        var asks: [Double] = [0, 0.5, 1.5, 2.5].filter { $0 < seconds }
        var found: [ReolinkFound] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            if let next = asks.first, Date().timeIntervalSince(started) >= next {
                asks.removeFirst()
                ask()
            }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0, let camera = answer(Array(buffer[..<n])), !found.contains(where: { $0.host == camera.host }) else { continue }
            found.append(camera)
        }
        return found
    }

    /// A camera's answer, read; nil for anything else (our own ask echoing back, another device).
    static func answer(_ data: [UInt8]) -> ReolinkFound? {
        guard data.count == 388, Array(data[104 ..< 108]) == ping else { return nil }
        func text(_ offset: Int, _ length: Int) -> String? {
            let value = String(decoding: data[offset ..< offset + length].prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        guard let host = text(108, 20) else { return nil }
        let mac = text(164, 18) ?? data[80 ..< 86].map { String(format: "%02X", $0) }.joined(separator: ":")
        return ReolinkFound(host: host, name: text(132, 32), mac: mac, uuid: text(228, 32))
    }
}
