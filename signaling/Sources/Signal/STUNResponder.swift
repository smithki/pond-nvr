// Answers STUN binding requests (RFC 5389) on UDP: tells each asker the address and port it came from, as the world
// sees it. Run by the signaling service, so devices finding their public addresses ask the same, self-hosted
// service, and no third party (a public STUN server) learns them.
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import Traversal

public final class STUNResponder: @unchecked Sendable {
    let port: UInt16
    private var fd: Int32 = -1
    public private(set) var boundPort: UInt16 = 0

    public init(port: UInt16) { self.port = port }

    /// Listening on every address (IPv6 and IPv4), answering on a thread of its own.
    public func start() throws {
        fd = socket(AF_INET6, Int32(SOCK_DGRAM_VALUE), 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var off: Int32 = 0
        setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        boundPort = UInt16(bigEndian: address.sin6_port)
        let socketFD = fd
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                var from = sockaddr_in6()
                var fromLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &buffer, buffer.count, 0, $0, &fromLength) }
                }
                guard n > 0 else { if n < 0 { return }; continue }
                guard let request = try? STUNMessage(Array(buffer[0 ..< n])), request.type == STUNMessage.bindingRequest else { continue }
                let answer = STUNMessage(type: STUNMessage.bindingSuccess, transaction: request.transaction, attributes: [
                    .init(STUNMessage.Attribute.xorMappedAddress, Self.address(from).xorEncoded(transaction: request.transaction)),
                ]).encoded()
                _ = withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socketFD, answer, answer.count, 0, $0, fromLength) }
                }
            }
        }
    }

    public func stop() { if fd >= 0 { close(fd) } }

    /// The asker's address: IPv4 as IPv4 (it arrives mapped into IPv6: ::ffff:a.b.c.d).
    static func address(_ from: sockaddr_in6) -> STUNAddress {
        var a = from.sin6_addr
        let bytes = withUnsafeBytes(of: &a) { Array($0) }
        let port = UInt16(bigEndian: from.sin6_port)
        if bytes[0 ..< 10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return STUNAddress(ip: Array(bytes[12 ..< 16]), port: port)
        }
        return STUNAddress(ip: bytes, port: port)
    }
}
