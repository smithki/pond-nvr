// Reolink's own protocol, Baichuan (TCP 9000), which its apps use: for what its HTTP API doesn't do, privacy
// mode first. The client: connect, log in, and send commands (BaichuanSession keeps one lasting connection per
// camera over it); following reolink_aio (MIT, by starkillerOG), the library Home Assistant's Reolink integration
// uses (see NOTICE).
//
// A message: a header (little-endian), then its XML (an extension, then the body), encrypted:
//   magic f0 de bc 0a | command (4) | body length (4) | channel (1) + message number (3) |
//   legacy (class 1465, 20 bytes): 12 dc 14 65
//   modern (class 1464, 24 bytes): status (2) | class 14 64 | where the payload starts (4)
// Before login the XML is XORed with a key turned by the channel byte; after, AES-128-CFB with a key from the
// nonce and password (and a fixed IV).
import CommonCrypto
import CryptoKit
import Foundation
import Ingest

public final class BaichuanClient: @unchecked Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreachable(String)
        case loginRefused
        case status(Int)
        case unexpected(String)

        public var description: String {
            switch self {
            case let .unreachable(why): "no answer on Baichuan: \(why)"
            case .loginRefused: "the camera refused the login"
            case let .status(code): "the camera answered \(code)"
            case let .unexpected(what): "an unexpected answer: \(what)"
            }
        }
    }

    public static let port = 9000
    static let magic: [UInt8] = [0xF0, 0xDE, 0xBC, 0x0A]
    static let xmlKey: [UInt8] = [0x1F, 0x2D, 0x3C, 0x4B, 0x5A, 0x69, 0x78, 0xFF]
    static let aesIV = Array("0123456789abcdef".utf8)
    /// The channel byte for the camera itself (not one of an NVR's channels).
    static let host: UInt8 = 250

    let hostName: String
    let username: String
    let password: String
    private var transport: SocketTransport?
    private var buffer: [UInt8] = []
    private var counter: UInt32 = 0
    /// Sends one at a time (a session's requests come from other threads than its reader).
    private let sending = NSLock()
    private var aesKey: [UInt8]?
    /// What the login answered (its device information), as XML.
    public private(set) var loginReply: String?

    public init(host: String, username: String, password: String) {
        hostName = host
        self.username = username
        self.password = password
    }

    deinit { transport?.close() }

    public func close() {
        transport?.close()
        transport = nil
    }

    /// What has come (whole messages), waiting up to `timeout` for more if none has: for a session's reader.
    func pump(timeout: Double) throws(Failure) -> [Reply] {
        var out: [Reply] = []
        while let reply = try takeMessage() { out.append(reply) }
        guard out.isEmpty else { return out }
        do {
            buffer += try transport?.receive(timeout: timeout) ?? []
        } catch {
            throw .unreachable("\(error)")
        }
        while let reply = try takeMessage() { out.append(reply) }
        return out
    }

    /// The extension naming a channel, as a command to one carries it.
    static func channelExtension(_ channel: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <Extension version="1.1">
        <channelId>\(channel)</channelId>
        </Extension>
        """
    }

    // MARK: Logging in

    public func login(timeout: Double = 5) throws(Failure) {
        do {
            transport = try SocketTransport(host: hostName, port: Self.port, timeout: timeout)
        } catch {
            throw .unreachable("\(error)")
        }
        // The nonce: asked in the legacy form, answered XOR-encrypted.
        try send(command: 1, channel: Self.host, legacy: true, body: nil)
        let nonceReply = try receive(command: 1, timeout: timeout)
        guard let nonce = Self.value("nonce", in: nonceReply.xml) else { throw .unexpected("no nonce: \(nonceReply.xml.prefix(200))") }
        aesKey = Array(Self.md5Modern("\(nonce)-\(password)").prefix(16).utf8)
        // The login: the name and password each hashed with the nonce.
        let login = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <LoginUser version="1.1">
        <userName>\(Self.md5Modern(username + nonce))</userName>
        <password>\(Self.md5Modern(password + nonce))</password>
        <userVer>1</userVer>
        </LoginUser>
        <LoginNet version="1.1">
        <type>LAN</type>
        <udpPort>0</udpPort>
        </LoginNet>
        </body>
        """
        try send(command: 1, channel: Self.host, legacy: false, body: login, aes: false)
        let reply = try receive(command: 1, timeout: timeout)
        if reply.status == 401 { throw .loginRefused }
        guard reply.status == 200 else { throw .status(reply.status) }
        loginReply = reply.xml
    }

    // MARK: Privacy mode

    /// Its privacy mode (Baichuan 574), on or off.
    public func privacyMode(channel: Int = 0, timeout: Double = 5) throws(Failure) -> Bool {
        let reply = try ask(command: 574, channel: channel, body: nil, timeout: timeout)
        guard let sleep = Self.value("sleep", in: reply) else { throw .unexpected("no sleep state: \(reply.prefix(300))") }
        return sleep == "1"
    }

    /// Its privacy mode set (Baichuan 575), then read back (574): what it now is.
    @discardableResult
    public func setPrivacyMode(_ on: Bool, channel: Int = 0, timeout: Double = 8) throws(Failure) -> Bool {
        let body = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <sleepState version="1.1">
        <operate>2</operate>
        <sleep>\(on ? 1 : 0)</sleep>
        </sleepState>
        </body>
        """
        _ = try ask(command: 575, channel: channel, body: body, timeout: timeout)
        return try privacyMode(channel: channel, timeout: timeout)
    }

    /// One command to a channel of the camera, its reply's XML.
    public func ask(command: UInt32, channel: Int = 0, body: String?, timeout: Double = 5) throws(Failure) -> String {
        try send(command: command, channel: UInt8(channel + 1), legacy: false, body: body, extension: Self.channelExtension(channel), aes: true)
        let reply = try receive(command: command, timeout: timeout)
        guard reply.status == 200 else { throw .status(reply.status) }
        return reply.xml
    }

    // MARK: Messages

    func send(command: UInt32, channel: UInt8, legacy: Bool, body: String?, extension ext: String = "",
              aes: Bool = false) throws(Failure) {
        sending.lock()
        defer { sending.unlock() }
        let extBytes = encrypt(Array(ext.utf8), channel: channel, aes: aes)
        let bodyBytes = encrypt(Array((body ?? "").utf8), channel: channel, aes: aes)
        var header = Self.magic
        header += Self.le32(command)
        header += Self.le32(UInt32(extBytes.count + bodyBytes.count))
        header += [channel] + Self.le32(counter).prefix(3)
        counter = (counter + 1) % 16_777_216
        if legacy {
            header += [0x12, 0xDC, 0x14, 0x65]
        } else {
            header += [0x00, 0x00, 0x14, 0x64] + Self.le32(UInt32(extBytes.count))
        }
        do {
            try transport?.send(header + extBytes + bodyBytes)
        } catch {
            throw .unreachable("\(error)")
        }
    }

    struct Reply {
        var command: UInt32
        var status: Int
        var xml: String
    }

    /// The next reply to `command` (others, such as pushed events, passed over).
    private func receive(command: UInt32, timeout: Double) throws(Failure) -> Reply {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            while let reply = try takeMessage() {
                if reply.command == command { return reply }
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw .unreachable("no reply to \(command)") }
            do {
                buffer += try transport?.receive(timeout: left) ?? []
            } catch {
                throw .unreachable("\(error)")
            }
        }
    }

    /// A whole message from the buffer, if one has come.
    func takeMessage() throws(Failure) -> Reply? {
        guard buffer.count >= 20 else { return nil }
        guard Array(buffer[0 ..< 4]) == Self.magic else { throw .unexpected("no magic: \(buffer.prefix(8).map { String(format: "%02x", $0) }.joined())") }
        let headerLength = try Self.headerLength(Array(buffer[18 ..< 20]))
        guard buffer.count >= headerLength else { return nil }
        let length = Int(Self.le32(buffer, 8))
        guard buffer.count >= headerLength + length else { return nil }
        let command = Self.le32(buffer, 4)
        let channel = buffer[12]
        let status = headerLength == 24 ? Int(buffer[16]) | Int(buffer[17]) << 8 : 200
        let encryption = Array(buffer[16 ..< 18])
        let payloadOffset = headerLength == 24 ? Int(Self.le32(buffer, 20)) : 0
        let body = Array(buffer[headerLength ..< headerLength + length])
        buffer.removeFirst(headerLength + length)
        return Reply(command: command, status: status, xml: decrypt(body, channel: channel, legacyEncryption: headerLength == 20 ? encryption : nil,
                                                                  payloadOffset: payloadOffset))
    }

    static func headerLength(_ messageClass: [UInt8]) throws(Failure) -> Int {
        switch (messageClass[0], messageClass[1]) {
        case (0x14, 0x66), (0x14, 0x65): return 20
        case (0x14, 0x64), (0x00, 0x00): return 24
        default: throw .unexpected(String(format: "message class %02x%02x", messageClass[0], messageClass[1]))
        }
    }

    // MARK: Encryption

    private func encrypt(_ bytes: [UInt8], channel: UInt8, aes: Bool) -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        if aes, let key = aesKey { return Self.aesCFB(bytes, key: key, encrypt: true) }
        return Self.xor(bytes, offset: channel)
    }

    /// The reply's XML: XOR or AES, as its header says (legacy) or as the session is (modern); each part (the
    /// extension, then the body) decrypted apart, as each was encrypted apart.
    private func decrypt(_ body: [UInt8], channel: UInt8, legacyEncryption: [UInt8]?, payloadOffset: Int) -> String {
        guard !body.isEmpty else { return "" }
        func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
        if let legacy = legacyEncryption {
            switch (legacy[0], legacy[1]) {
            case (0x00, 0xDD): return text(body)
            case (0x02, 0xDD), (0x03, 0xDD): if let key = aesKey { return text(Self.aesCFB(body, key: key, encrypt: false)) }
            default: break
            }
            return text(Self.xor(body, offset: channel))
        }
        // Modern: AES once logged in (each part apart); else XOR. Whichever reads as XML.
        if let key = aesKey {
            var parts: [[UInt8]] = [body]
            if payloadOffset > 0, payloadOffset < body.count { parts = [Array(body[..<payloadOffset]), Array(body[payloadOffset...])] }
            let aes = parts.map { text(Self.aesCFB($0, key: key, encrypt: false)) }.joined()
            if aes.hasPrefix("<?xml") { return aes }
        }
        return text(Self.xor(body, offset: channel))
    }

    static func xor(_ bytes: [UInt8], offset: UInt8) -> [UInt8] {
        bytes.enumerated().map { index, byte in byte ^ xmlKey[(Int(offset) + index) % xmlKey.count] ^ offset }
    }

    static func aesCFB(_ bytes: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8] {
        var cryptor: CCCryptorRef?
        guard CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(kCCModeCFB), CCAlgorithm(kCCAlgorithmAES),
                                      CCPadding(ccNoPadding), aesIV, key, key.count, nil, 0, 0, 0, &cryptor) == kCCSuccess,
              let cryptor else { return [] }
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: bytes.count)
        var moved = 0
        guard CCCryptorUpdate(cryptor, bytes, bytes.count, &out, out.count, &moved) == kCCSuccess else { return [] }
        return Array(out.prefix(moved))
    }

    /// MD5 as hex, upper case, its first 31 characters (as Reolink's apps make it).
    static func md5Modern(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined().prefix(31).description
    }

    static func value(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>", range: start.upperBound ..< xml.endIndex)
        else { return nil }
        return String(xml[start.upperBound ..< end.lowerBound])
    }

    static func le32(_ value: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
