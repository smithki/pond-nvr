// A small RTSP client: DESCRIBE, SETUP over TCP (interleaved), PLAY, then reading packets. Synchronous, for
// the camera check; the recorder will drive the same pieces (reader, auth, SDP) asynchronously.
import Foundation

public enum RTSPError: Error, Equatable, Codable, CustomStringConvertible {
    case transport(TransportError)
    case unauthorized
    case notFound(String)
    case status(Int, String)
    case timeout(String)
    case malformed(String)

    public var description: String {
        switch self {
        case let .transport(e): e.description
        case .unauthorized: "the camera refused the username or password"
        case let .notFound(url): "the camera has no stream at \(url)"
        case let .status(code, reason): "the camera answered \(code) \(reason)"
        case let .timeout(what): "no answer to \(what)"
        case let .malformed(what): "the camera's answer could not be read: \(what)"
        }
    }
}

public final class RTSPClient {
    let transport: RTSPTransport
    let username: String
    let password: String
    let timeout: Double
    private var reader = RTSPReader()
    private var cseq = 0
    private var challenge: AuthChallenge?
    private var nonceCount = 0
    private(set) var session: String?
    /// Interleaved packets that arrived while waiting for a reply.
    private var early: [InterleavedPacket] = []

    public init(transport: RTSPTransport, username: String, password: String, timeout: Double = 10) {
        self.transport = transport
        self.username = username
        self.password = password
        self.timeout = timeout
    }

    /// Sends a request and returns the reply, answering one authentication challenge on the way.
    public func request(_ method: String, _ url: String, headers: [(String, String)] = []) throws(RTSPError) -> RTSPResponse {
        for attempt in 0 ..< 2 {
            cseq += 1
            var all: [(String, String)] = [("CSeq", "\(cseq)"), ("User-Agent", "Pond")]
            all += headers
            if let session { all.append(("Session", session)) }
            if let challenge {
                nonceCount += 1
                all.append(("Authorization", challenge.authorization(method: method, uri: url, username: username,
                                                                     password: password, nc: nonceCount)))
            }
            do {
                try transport.send(RTSPRequest(method: method, url: url, headers: all).encoded())
            } catch {
                throw .transport(error)
            }
            let response = try waitForResponse(method)
            switch response.status {
            case 200 ..< 300:
                return response
            case 401:
                guard attempt == 0, let c = AuthChallenge.parse(response.headers["www-authenticate"] ?? []) else {
                    throw .unauthorized
                }
                // A second 401 after answering a fresh challenge means the login is wrong.
                if challenge != nil, case .digest = c, challenge == c { throw .unauthorized }
                challenge = c
                nonceCount = 0
            case 404:
                throw .notFound(url)
            default:
                throw .status(response.status, response.reason)
            }
        }
        throw .unauthorized
    }

    private func waitForResponse(_ method: String) throws(RTSPError) -> RTSPResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                while let item = try reader.next() {
                    switch item {
                    case let .response(r): return r
                    case let .interleaved(p): early.append(p)
                    }
                }
            } catch {
                throw .malformed("\(error)")
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw .timeout(method) }
            do {
                reader.feed(try transport.receive(timeout: left))
            } catch {
                throw .transport(error)
            }
        }
    }

    /// DESCRIBE: the stream's session description.
    public func describe(_ url: String) throws(RTSPError) -> (sdp: SDP, base: String) {
        let r = try request("DESCRIBE", url, headers: [("Accept", "application/sdp")])
        var base = r.header("content-base") ?? url
        if base.hasSuffix("/") { base.removeLast() }
        return (SDP(r.bodyText), base)
    }

    /// SETUP one track over this connection, on interleaved channels `channel` (RTP) and `channel + 1` (RTCP).
    public func setup(_ trackURL: String, channel: UInt8, headers: [(String, String)] = []) throws(RTSPError) {
        let r = try request("SETUP", trackURL,
                            headers: [("Transport", "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)")] + headers)
        guard let s = r.header("session") else { throw .malformed("SETUP reply without a session") }
        session = s.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public func play(_ url: String, headers: [(String, String)] = []) throws(RTSPError) {
        _ = try request("PLAY", url, headers: [("Range", "npt=0.000-")] + headers)
    }

    /// Sends bytes as they are (an interleaved packet).
    public func sendRaw(_ bytes: [UInt8]) throws(RTSPError) {
        do { try transport.send(bytes) } catch { throw .transport(error) }
    }

    /// Reads and drops whatever has arrived (the camera's RTCP, replies to keepalives), so its sending
    /// doesn't stall; waits up to `timeout`. Throws if the camera hung up.
    public func drain(timeout: Double = 0) throws(RTSPError) {
        do {
            let bytes = try transport.receive(timeout: timeout)
            if !bytes.isEmpty { reader.feed(bytes); while (try? reader.next()) != nil {} }
        } catch {
            throw .transport(error)
        }
    }

    /// Sends a request without waiting for the reply (which `nextPacket` skips). For keepalives while playing:
    /// cameras end a session that hears nothing for its timeout, usually 60 s.
    public func sendWithoutReply(_ method: String, _ url: String) throws(RTSPError) {
        cseq += 1
        var headers: [(String, String)] = [("CSeq", "\(cseq)"), ("User-Agent", "Pond")]
        if let session { headers.append(("Session", session)) }
        if let challenge {
            nonceCount += 1
            headers.append(("Authorization", challenge.authorization(method: method, uri: url, username: username,
                                                                     password: password, nc: nonceCount)))
        }
        do {
            try transport.send(RTSPRequest(method: method, url: url, headers: headers).encoded())
        } catch {
            throw .transport(error)
        }
    }

    public func teardown(_ url: String) {
        _ = try? transport.send(RTSPRequest(method: "TEARDOWN", url: url,
                                            headers: [("CSeq", "\(cseq + 1)")] + (session.map { [("Session", $0)] } ?? [])).encoded())
    }

    /// How many times the stream lost its framing (and was read on from the next packet), and the bytes skipped.
    public var framingLost: (times: Int, bytes: Int) { (reader.resyncs, reader.skipped) }

    /// The next interleaved packet, or nil if none arrives within `timeout` seconds.
    public func nextPacket(timeout: Double) throws(RTSPError) -> InterleavedPacket? {
        if !early.isEmpty { return early.removeFirst() }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                while let item = try reader.next() {
                    if case let .interleaved(p) = item { return p }   // stray replies are ignored
                }
            } catch {
                throw .malformed("\(error)")
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            do {
                reader.feed(try transport.receive(timeout: left))
            } catch {
                throw .transport(error)
            }
        }
    }
}
