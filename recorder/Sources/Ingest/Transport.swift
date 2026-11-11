// The byte stream an RTSP client talks over. SocketTransport is a plain TCP socket; tests use a scripted fake.
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol RTSPTransport: AnyObject {
    func send(_ bytes: [UInt8]) throws(TransportError)
    /// Bytes that arrived within `timeout` seconds; empty if none did. Throws `.closed` when the peer hung up.
    func receive(timeout: Double) throws(TransportError) -> [UInt8]
    func close()
}

public enum TransportError: Error, Equatable, Codable, CustomStringConvertible {
    case unreachable(String)
    /// The camera answered, and turned the connection down (nothing listening on the port): it's there, its
    /// service isn't (a video server that didn't start again, say), unlike no answer at all.
    case refused(String)
    case closed
    case failed(String)

    public var description: String {
        switch self {
        case let .unreachable(reason): reason
        case let .refused(reason): reason
        case .closed: "the camera closed the connection"
        case let .failed(reason): reason
        }
    }
}

public final class SocketTransport: RTSPTransport {
    private var fd: Int32 = -1

    /// Connects, giving up after `timeout` seconds.
    public init(host: String, port: Int, timeout: Double) throws(TransportError) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let first = list else {
            throw .unreachable("\(host) could not be resolved: \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(list) }
        var lastError = "no address"
        // Refused by every address tried (not timed out, not unroutable): the camera's there, its service isn't.
        var refusedEverywhere = true
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let ai = info {
            info = ai.pointee.ai_next
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard s >= 0 else { continue }
            let flags = fcntl(s, F_GETFL, 0)
            _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
            if connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0, errno != EINPROGRESS {
                if errno != ECONNREFUSED { refusedEverywhere = false }
                lastError = String(cString: strerror(errno))
                _ = Glibc_or_Darwin_close(s)
                continue
            }
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &soError, &len)
            if ready <= 0 || soError != 0 {
                if ready <= 0 || soError != ECONNREFUSED { refusedEverywhere = false }
                lastError = ready == 0 ? "no answer within \(Int(timeout)) s" : String(cString: strerror(soError))
                _ = Glibc_or_Darwin_close(s)
                continue
            }
            _ = fcntl(s, F_SETFL, flags)
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            fd = s
            return
        }
        if refusedEverywhere, lastError != "no address" { throw .refused("\(host):\(port) refused the connection") }
        throw .unreachable("\(host):\(port) did not answer: \(lastError)")
    }

    /// A socket already connected (a local one, as the stream relay uses), owned from here on.
    public init(connected fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        self.fd = fd
    }

    deinit { close() }

    public func send(_ bytes: [UInt8]) throws(TransportError) {
        guard fd >= 0 else { throw .closed }
        var sent = 0
        while sent < bytes.count {
            #if os(Linux)
            let n = bytes[sent...].withUnsafeBytes { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            #else
            let n = bytes[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            #endif
            guard n > 0 else { throw .failed("sending failed: \(String(cString: strerror(errno)))") }
            sent += n
        }
    }

    public func receive(timeout: Double) throws(TransportError) -> [UInt8] {
        guard fd >= 0 else { throw .closed }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, Int32(max(0, timeout) * 1000))
        if ready == 0 { return [] }
        guard ready > 0 else { throw .failed("waiting failed: \(String(cString: strerror(errno)))") }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n == 0 { throw .closed }
        guard n > 0 else { throw .failed("receiving failed: \(String(cString: strerror(errno)))") }
        return Array(buffer[0 ..< n])
    }

    public func close() {
        if fd >= 0 {
            _ = Glibc_or_Darwin_close(fd)
            fd = -1
        }
    }
}

// `close` is shadowed by the method above.
private func Glibc_or_Darwin_close(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}
