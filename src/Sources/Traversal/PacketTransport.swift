// Where a PathFinder's packets go: one UDP socket for a session (its checks, and later its media, on the same
// port), or a test's network of its own. The socket is dual-stack: IPv4 and IPv6 alike, from one port.
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation

public protocol PacketTransport: AnyObject, Sendable {
    /// The port it's bound to.
    var port: UInt16 { get }
    /// A packet sent (dropped quietly if it can't be: UDP's way).
    func send(_ bytes: [UInt8], to: STUNAddress)
    /// Where what arrives goes: the bytes, and where from.
    func receive(_ handler: @escaping @Sendable ([UInt8], STUNAddress) -> Void)
    func close()
}

/// A real UDP socket on every address, IPv6 and IPv4 (IPv4 arrives mapped: ::ffff:a.b.c.d, and is sent so).
public final class DatagramSocket: PacketTransport, @unchecked Sendable {
    public let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var handler: (@Sendable ([UInt8], STUNAddress) -> Void)?
    private var closed = false

    public struct Failed: Error, CustomStringConvertible {
        public var description: String
    }

    /// Bound to `port` (0: any the system gives).
    public init(port: UInt16 = 0) throws {
        fd = socket(AF_INET6, Int32(SOCK_DGRAM_VALUE), 0)
        guard fd >= 0 else { throw Failed(description: "no socket (errno \(errno))") }
        var off: Int32 = 0
        setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        // Reads wake every half second, so a closed socket's thread notices and ends (shutting a UDP socket down
        // doesn't wake a read on macOS).
        var wake = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wake, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let socketFD = fd
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else {
            let error = errno
            _ = closeSocket(fd)
            throw Failed(description: error == EADDRINUSE ? "UDP port \(port) is in use" : "couldn't bind UDP port \(port) (errno \(error))")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(socketFD, $0, &length) }
        }
        self.port = UInt16(bigEndian: address.sin6_port)
        let thread = Thread { [weak self] in self?.read() }
        thread.name = "udp \(self.port)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func receive(_ handler: @escaping @Sendable ([UInt8], STUNAddress) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func send(_ bytes: [UInt8], to destination: STUNAddress) {
        var address = Self.socketAddress(destination)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }

    /// Closed: its reading thread ends within half a second, and closes the socket.
    public func close() { lock.withLock { closed = true } }

    deinit { close() }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !lock.withLock({ closed }) {
            var from = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
            let handler = lock.withLock { self.handler }
            handler?(Array(buffer[0 ..< n]), Self.address(from))
        }
        _ = closeSocket(fd)
    }

    /// An address as the socket takes it (IPv4 mapped into IPv6).
    static func socketAddress(_ a: STUNAddress) -> sockaddr_in6 {
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = a.port.bigEndian
        let bytes = a.isIPv6 ? a.ip : [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF] + a.ip
        withUnsafeMutableBytes(of: &address.sin6_addr) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        return address
    }

    /// Where a packet came from: IPv4 as IPv4.
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

/// The C library's `close` (inside the class, `close` is its own).
@inline(__always) func closeSocket(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
    Glibc.close(fd)
    #else
    Darwin.close(fd)
    #endif
}

/// Socket types as `socket()` takes them, on Linux and macOS alike.
#if canImport(Glibc)
public let SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
public let SOCK_DGRAM_VALUE = Int32(SOCK_DGRAM.rawValue)
#else
public let SOCK_STREAM_VALUE = SOCK_STREAM
public let SOCK_DGRAM_VALUE = SOCK_DGRAM
#endif
