// Cameras that don't answer ONVIF discovery (Reolink's, among others), found by a quick look at this Mac's
// own network: every address nearby (the 254 around the Mac's, however large the network) asked at once
// whether it takes connections on RTSP's port, 554, or on 8000, where many cameras answer ONVIF (a camera
// serving all the video connections it can may turn away RTSP's). An address with 554 open is likely a
// camera; one with only 8000 open counts if it answers ONVIF there. Its name comes from the network (what
// the router calls it). No login, and nothing beyond the local network.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum NetworkScan {
    /// This Mac's IPv4 addresses on local networks, with their netmasks (not loopback, not link-local).
    static func localNetworks() -> [(address: UInt32, mask: UInt32)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [(UInt32, UInt32)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // 169.254.x.x (no network) is skipped.
            if a >> 16 == 0xA9FE { continue }
            out.append((a, m))
        }
        return out
    }

    /// The addresses to ask: those in each local network, at most the 254 around the Mac's own.
    static func candidates() -> [UInt32] {
        var hosts: Set<UInt32> = []
        for (address, mask) in localNetworks() {
            let narrow = max(mask, 0xFFFF_FF00)
            let network = address & narrow
            for host in 1 ..< (~narrow) where network | host != address { hosts.insert(network | host) }
        }
        return hosts.sorted()
    }

    static func text(_ address: UInt32) -> String {
        "\(address >> 24).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }

    /// The addresses that took a connection on `port` within `seconds`, all asked at once.
    public static func open(port: UInt16 = 554, seconds: Double = 0.8) async -> [String] {
        await Task.detached {
            let hosts = candidates()
            var (open, _) = openNow(hosts, port: port, seconds: seconds)
            // Nothing: a process's first connections fail, or hang, while macOS decides whether it may use
            // the local network. Once more, a moment later and with longer to answer.
            if open.isEmpty, !hosts.isEmpty {
                try? await Task.sleep(for: .seconds(2))
                (open, _) = openNow(hosts, port: port, seconds: seconds * 2)
            }
            return open
        }.value
    }

    /// The open ones, and how many failed at once on this Mac (no route: not let on the network).
    static func openNow(_ hosts: [UInt32], port: UInt16, seconds: Double) -> (open: [String], refused: Int) {
        var refused = 0
        var sockets: [(fd: Int32, host: UInt32)] = []
        defer { for s in sockets { close(s.fd) } }
        for host in hosts {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var to = sockaddr_in()
            to.sin_family = sa_family_t(AF_INET)
            to.sin_port = port.bigEndian
            to.sin_addr.s_addr = host.bigEndian
            let started = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if started != 0, errno != EINPROGRESS {
                refused += 1
                close(fd)
                continue
            }
            sockets.append((fd, host))
        }
        var open: Set<UInt32> = []
        let deadline = Date().addingTimeInterval(seconds)
        var waiting = sockets
        while !waiting.isEmpty, Date() < deadline {
            var fds = waiting.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            let left = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&fds, nfds_t(fds.count), left) > 0 else { break }
            var still: [(fd: Int32, host: UInt32)] = []
            for (i, entry) in waiting.enumerated() {
                guard fds[i].revents != 0 else { still.append(entry); continue }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &error, &length)
                if error == 0 { open.insert(entry.host) } else if error == EHOSTUNREACH || error == ENETUNREACH { refused += 1 }
            }
            waiting = still
        }
        return (open.sorted().map(text), refused)
    }

    /// What the network calls an address (the router's name for it, "doorbell"), without its domain; nil if
    /// it has none.
    public static func name(of host: String) -> String? {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let found = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard found == 0 else { return nil }
        let full = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let short = full.split(separator: ".").first.map(String.init) ?? full
        return short.isEmpty || short == host ? nil : short
    }
}

extension NetworkScan {
    /// The likely cameras: RTSP's port open, or ONVIF answering on 8000.
    public static func cameras() async -> [String] {
        async let rtsp = open(port: 554)
        async let onvif = open(port: 8000)
        var hosts = await rtsp
        for host in await onvif where !hosts.contains(host) {
            if await ONVIFClient.answers(host: host, port: 8000) { hosts.append(host) }
        }
        return hosts
    }
}

/// A camera found on the network, however it was found: where, what it's called, and how it answered.
public struct FoundCamera: Codable, Equatable, Sendable, Identifiable {
    public var host: String
    /// Its own name (given in its maker's app, or its ONVIF name), else what the network calls it.
    public var name: String?
    /// Its ONVIF hardware (often the model), when it answered ONVIF discovery.
    public var hardware: String?
    /// Its maker, when its maker's own discovery found it ("Reolink").
    public var maker: String?
    /// Its MAC address, when known: the same whatever its address.
    public var mac: String?
    /// It answered ONVIF discovery (so ONVIF works on it).
    public var answersONVIF: Bool

    public init(host: String, name: String? = nil, hardware: String? = nil, maker: String? = nil, mac: String? = nil,
                answersONVIF: Bool = false) {
        self.host = host
        self.name = name
        self.hardware = hardware
        self.maker = maker
        self.mac = mac
        self.answersONVIF = answersONVIF
    }

    public var id: String { host }
    public var title: String { name ?? hardware ?? host }
}

public enum CameraFinder {
    /// The cameras on the network, every way at once: ONVIF discovery, Reolink's own discovery, and a look at
    /// the network's addresses for cameras that answer neither. One each, by address, with the best name
    /// each way gives (the camera's own, then ONVIF's, then the network's).
    public static func find(seconds: Double = 3) async -> [FoundCamera] {
        async let onvif = ONVIFDiscovery.probe(seconds: seconds)
        async let reolink = ReolinkDiscovery.probe(seconds: seconds)
        async let scanned = NetworkScan.cameras()
        var found: [String: FoundCamera] = [:]
        for camera in await reolink {
            found[camera.host] = FoundCamera(host: camera.host, name: camera.name, maker: "Reolink", mac: camera.mac)
        }
        for camera in await onvif.cameras {
            var entry = found[camera.host] ?? FoundCamera(host: camera.host)
            entry.name = entry.name ?? camera.name
            entry.hardware = camera.hardware
            entry.answersONVIF = true
            found[camera.host] = entry
        }
        for host in await scanned where found[host] == nil { found[host] = FoundCamera(host: host) }
        // Names from the network for those nothing else named (a lookup each, off the main thread).
        let unnamed = found.values.filter { $0.name == nil }.map(\.host)
        let names = await Task.detached { unnamed.map { ($0, NetworkScan.name(of: $0)) } }.value
        for (host, name) in names { found[host]?.name = name }
        return found.values.sorted { $0.host.compare($1.host, options: .numeric) == .orderedAscending }
    }
}
