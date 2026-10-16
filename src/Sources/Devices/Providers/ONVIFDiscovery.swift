// Cameras on the local network, found the ONVIF way (WS-Discovery): one Probe sent to the multicast group
// cameras listen on (239.255.255.250, UDP 3702), asking for video transmitters; each answers on its own
// with its ONVIF address and its scopes (usually its name and hardware). No login: it's what a camera tells
// anyone on the network. Sent with a plain UDP socket, from whatever port the system picks; the answers
// come back to it.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A camera that answered: where it is and what it says it is.
public struct DiscoveredCamera: Equatable, Sendable, Identifiable {
    /// Its WS-Discovery identity (usually "urn:uuid:…"), the same each time it answers.
    public var id: String
    /// The host its ONVIF service is on (from its first address).
    public var host: String
    /// Its ONVIF device service addresses.
    public var addresses: [URL]
    /// From its scopes: the name it was given, and its hardware (often the model).
    public var name: String?
    public var hardware: String?

    /// What to call it: its name, else its hardware, else its address.
    public var title: String { name ?? hardware ?? host }
}

public enum ONVIFDiscovery {
    static let group = "239.255.255.250"
    static let port: UInt16 = 3702

    /// What a probe found: the cameras that answered, one each (some answer twice), in the order they
    /// answered; and, if the probe could never be sent, why (macOS not, or not yet, letting Pond on the
    /// local network).
    public struct Result: Sendable {
        public var cameras: [DiscoveredCamera]
        public var sendFailure: String?

        public init(cameras: [DiscoveredCamera], sendFailure: String?) {
            self.cameras = cameras
            self.sendFailure = sendFailure
        }
    }

    /// `anyDevice` asks every WS-Discovery device, not only cameras; `trace` is told each answer that comes.
    public static func probe(seconds: Double = 3, anyDevice: Bool = false,
                             trace: (@Sendable (String) -> Void)? = nil) async -> Result {
        await Task.detached { probeNow(seconds: seconds, anyDevice: anyDevice, trace: trace) }.value
    }

    static func probeNow(seconds: Double, anyDevice: Bool = false, trace: (@Sendable (String) -> Void)? = nil) -> Result {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return Result(cameras: [], sendFailure: String(cString: strerror(errno))) }
        defer { close(fd) }
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        // Short reads, so the loop notices the time is up.
        var wait = timeval(tv_sec: 0, tv_usec: 120_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var to = sockaddr_in()
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = port.bigEndian
        inet_pton(AF_INET, group, &to.sin_addr)
        let message = Array(probeMessage(anyDevice: anyDevice).utf8)
        var sentOnce = false, failure: String?
        func send() {
            let n = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if n >= 0 { sentOnce = true } else { failure = String(cString: strerror(errno)) }
        }
        // Sent again now and then: UDP can drop it, and a process's first sends fail while macOS decides
        // whether it may use the local network (answers to each are told apart by the camera's id).
        var sends: [Double] = [0, 0.5, 1.5, 2.5].filter { $0 < seconds }

        // Some cameras answer to the group rather than to the asker: heard on a second socket, in the group.
        let group = groupListener()
        defer { if group >= 0 { close(group) } }

        var found: [DiscoveredCamera] = []
        let started = Date()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Date().timeIntervalSince(started) < seconds {
            if let next = sends.first, Date().timeIntervalSince(started) >= next {
                sends.removeFirst()
                send()
            }
            // Whichever socket has something (each read waits up to a quarter second).
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            var n = 0
            for socket in [fd, group] where socket >= 0 && n <= 0 {
                n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, &buffer, buffer.count, 0, $0, &fromLength) }
                }
            }
            guard n > 0 else { continue }
            let text = String(decoding: buffer[..<n], as: UTF8.self)
            if let trace {
                var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &from.sin_addr, &address, socklen_t(INET_ADDRSTRLEN))
                let types = text.range(of: "Types>[^<]*<", options: .regularExpression).map { String(text[$0]) } ?? ""
                let addrs = text.range(of: "XAddrs>[^<]*<", options: .regularExpression).map { String(text[$0]) } ?? ""
                trace("\(String(decoding: address.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)):\(UInt16(bigEndian: from.sin_port)) sent \(n) bytes: \(matches(in: text).map(\.title)) \(types) \(addrs)")
            }
            for camera in matches(in: text) where !found.contains(where: { $0.id == camera.id }) {
                found.append(camera)
            }
        }
        return Result(cameras: found, sendFailure: sentOnce ? nil : failure)
    }

    /// A socket in the discovery group, on its port (shared with anything else listening there): it hears
    /// answers sent to the group, and cameras announcing themselves. -1 if it can't be had.
    static func groupListener() -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 120_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = port.bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var membership = ip_mreq()
        inet_pton(AF_INET, group, &membership.imr_multiaddr)
        membership.imr_interface.s_addr = INADDR_ANY
        guard bound == 0,
              setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    /// A Probe for network video transmitters (cameras and encoders).
    static func probeMessage(id: UUID = UUID(), anyDevice: Bool = false) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>\
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" \
        xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" \
        xmlns:dn="http://www.onvif.org/ver10/network/wsdl">\
        <e:Header><w:MessageID>uuid:\(id.uuidString.lowercased())</w:MessageID>\
        <w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>\
        <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>\
        <e:Body><d:Probe>\(types(anyDevice))</d:Probe></e:Body></e:Envelope>
        """
    }

    /// What a probe asks for: video transmitters (cameras and encoders); or, for tests, the general ONVIF
    /// device (POND_PROBE_TYPES=device) or anything (anyDevice).
    static func types(_ anyDevice: Bool) -> String {
        if anyDevice { return "" }
        if ProcessInfo.processInfo.environment["POND_PROBE_TYPES"] == "device" {
            return "<d:Types xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\">tds:Device</d:Types>"
        }
        return "<d:Types>dn:NetworkVideoTransmitter</d:Types>"
    }

    /// The cameras in a ProbeMatches answer.
    static func matches(in text: String) -> [DiscoveredCamera] {
        guard let document = try? XMLDocument(xmlString: text) else { return [] }
        return document.all("ProbeMatch").compactMap { match in
            let addresses = (match.first("XAddrs")?.trimmed ?? "").split(separator: " ").compactMap { URL(string: String($0)) }
            guard let host = addresses.first?.host else { return nil }
            let id = match.first("EndpointReference")?.first("Address")?.trimmed ?? host
            let scopes = (match.first("Scopes")?.trimmed ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            return DiscoveredCamera(id: id, host: host, addresses: addresses,
                                    name: scope("name", in: scopes), hardware: scope("hardware", in: scopes))
        }
    }

    /// The value of an ONVIF scope ("onvif://www.onvif.org/name/Front%20door" → "Front door").
    static func scope(_ key: String, in scopes: [String]) -> String? {
        let prefix = "onvif://www.onvif.org/\(key)/"
        guard let scope = scopes.first(where: { $0.lowercased().hasPrefix(prefix) }) else { return nil }
        let value = String(scope.dropFirst(prefix.count))
        let decoded = (value.removingPercentEncoding ?? value).trimmingCharacters(in: .whitespaces)
        return decoded.isEmpty ? nil : decoded
    }
}
