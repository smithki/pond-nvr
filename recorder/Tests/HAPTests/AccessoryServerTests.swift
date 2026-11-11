import CryptoKit
import Foundation
import Testing
@testable import HAP

/// A controller talking to an AccessoryServer through an in-memory connection.
final class Wire: @unchecked Sendable {
    var received: [UInt8] = []
    let lock = NSLock()
    func take() -> [UInt8] { lock.withLock { defer { received = [] }; return received } }
}

struct ClientSession {
    var outgoing: FrameCipher
    var incoming: FrameCipher

    init(shared: [UInt8]) {
        outgoing = FrameCipher(key: HAPCrypto.hkdf(shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key"))
        incoming = FrameCipher(key: HAPCrypto.hkdf(shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key"))
    }
}

/// A reply: its head as text, its body as bytes.
struct Reply {
    var head: String
    var body: [UInt8]
    var text: String { head + String(decoding: body, as: UTF8.self) }
    func hasPrefix(_ p: String) -> Bool { head.hasPrefix(p) }
    func contains(_ p: String) -> Bool { text.contains(p) }
}

/// Waits for whole HTTP messages from the wire (the server answers asynchronously).
func responses(_ wire: Wire, session: inout ClientSession?, count: Int = 1) async throws -> [Reply] {
    var bytes: [UInt8] = []
    var out: [Reply] = []
    for _ in 0 ..< 200 {
        var chunk = wire.take()
        if session != nil, !chunk.isEmpty { chunk = try session!.incoming.open(chunk) }
        bytes += chunk
        // Split into messages by Content-Length.
        while let end = HTTPRequestReader.headerEnd(bytes) {
            let head = String(decoding: bytes[0 ..< end], as: UTF8.self)
            let length = head.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard bytes.count >= end + 4 + length else { break }
            out.append(Reply(head: head, body: Array(bytes[end + 4 ..< end + 4 + length])))
            bytes.removeFirst(end + 4 + length)
        }
        if out.count >= count { return out }
        try await Task.sleep(for: .milliseconds(10))
    }
    return out
}

func body(_ reply: Reply) -> [UInt8] { reply.body }

func request(_ method: String, _ path: String, _ body: [UInt8] = [], type: String = "application/hap+json") -> [UInt8] {
    Array("\(method) \(path) HTTP/1.1\r\nHost: test\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
}

@Suite struct AccessoryServerTests {
    let identity = AccessoryIdentity.generate()

    func makeServer() -> (AccessoryServer, Characteristic) {
        let motion = Characteristic(type: HAPType.motionDetected, format: .bool, permissions: [.read, .notify], value: .bool(false))
        let info = Service(type: HAPType.accessoryInformation, [
            Characteristic(type: HAPType.identify, format: .bool, permissions: [.write]),
            Characteristic(type: HAPType.name, format: .string, permissions: [.read], value: .string("Porch")),
        ])
        let accessory = Accessory(services: [info, Service(type: HAPType.motionSensor, [motion])])
        let server = AccessoryServer(identity: identity, store: MemoryPairingStore(), accessory: accessory, setupCode: "031-45-154")
        return (server, motion)
    }

    /// Pairs, then verifies on a fresh connection; returns that connection, ready for encrypted requests.
    func pairedConnection(_ server: AccessoryServer) async throws -> (HAPConnection, Wire, ClientSession) {
        let controller = TestController()
        _ = try controller.pairSetup(with: server.pairSetup, code: "031-45-154").get()
        let wire = Wire()
        let conn = server.connect { bytes in wire.lock.withLock { wire.received += bytes } }
        // Pair verify over the connection, in plain HTTP.
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let minePublic = Array(mine.publicKey.rawRepresentation)
        conn.receive(request("POST", "/pair-verify", TLV8.encode([TLV8Item(PairingTLV.state, [1]),
                                                                  TLV8Item(PairingTLV.publicKey, minePublic)]),
                             type: "application/pairing+tlv8"))
        var none: ClientSession?
        let m2 = try TLV8.decode(body(try need(try await responses(wire, session: &none).first)))
        let theirs = try need(m2.value(PairingTLV.publicKey))
        let shared = try mine.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs)).withUnsafeBytes { Array($0) }
        let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let signature = Array(try controller.signingKey.signature(for: minePublic + Array(controller.identifier.utf8) + theirs))
        let sub = TLV8.encode([TLV8Item(PairingTLV.identifier, Array(controller.identifier.utf8)),
                               TLV8Item(PairingTLV.signature, signature)])
        conn.receive(request("POST", "/pair-verify", TLV8.encode([TLV8Item(PairingTLV.state, [3]),
            TLV8Item(PairingTLV.encryptedData, HAPCrypto.seal(sub, key: key, nonce: HAPCrypto.nonce("PV-Msg03")))]),
                             type: "application/pairing+tlv8"))
        let m4 = try TLV8.decode(body(try need(try await responses(wire, session: &none).first)))
        #expect(m4.value(PairingTLV.error) == nil)
        return (conn, wire, ClientSession(shared: shared))
    }

    @Test func encryptedSessionReadsWritesAndNotifies() async throws {
        let (server, motion) = makeServer()
        #expect(!server.isPaired)
        let (conn, wire, s) = try await pairedConnection(server)
        #expect(server.isPaired)
        var session: ClientSession? = s

        // The database.
        conn.receive(session!.outgoing.seal(request("GET", "/accessories")))
        let db = try JSONSerialization.jsonObject(with: Data(body(try need(try await responses(wire, session: &session).first)))) as? [String: Any]
        let services = try need((db?["accessories"] as? [[String: Any]])?.first?["services"] as? [[String: Any]])
        #expect(services.map { $0["type"] as? String } == ["3E", "85"])

        // Reading: the name (iid 3), and a characteristic that does not exist.
        conn.receive(session!.outgoing.seal(request("GET", "/characteristics?id=1.3,1.99")))
        let read = try need(try await responses(wire, session: &session).first)
        #expect(read.hasPrefix("HTTP/1.1 207"))
        #expect(read.contains("\"value\":\"Porch\""))
        #expect(read.contains("-70409"))

        // Subscribing to motion, then motion: an event arrives.
        conn.receive(session!.outgoing.seal(request("PUT", "/characteristics",
            Array(#"{"characteristics":[{"aid":1,"iid":\#(motion.iid),"ev":true}]}"#.utf8))))
        #expect(try need(try await responses(wire, session: &session).first).hasPrefix("HTTP/1.1 204"))
        motion.update(.bool(true))
        let event = try need(try await responses(wire, session: &session).first)
        #expect(event.hasPrefix("EVENT/1.0 200 OK"))
        #expect(event.contains("\"value\":true"))

        // Writing a read-only characteristic fails.
        conn.receive(session!.outgoing.seal(request("PUT", "/characteristics",
            Array(#"{"characteristics":[{"aid":1,"iid":3,"value":"x"}]}"#.utf8))))
        #expect(try need(try await responses(wire, session: &session).first).contains("-70404"))
    }

    @Test func nothingWithoutVerifying() async throws {
        let (server, _) = makeServer()
        let wire = Wire()
        let conn = server.connect { bytes in wire.lock.withLock { wire.received += bytes } }
        conn.receive(request("GET", "/accessories"))
        var none: ClientSession?
        #expect(try need(try await responses(wire, session: &none).first).hasPrefix("HTTP/1.1 470"))
    }

    @Test func setupCodesAndURI() {
        #expect(SetupInfo.isValid(code: "031-45-154"))
        #expect(!SetupInfo.isValid(code: "123-45-678"))
        #expect(!SetupInfo.isValid(code: "12345678"))
        for _ in 0 ..< 20 { #expect(SetupInfo.isValid(code: SetupInfo.generate().code)) }
        let uri = SetupInfo(code: "031-45-154", setupID: "1QJ8").uri(category: AccessoryCategory.ipCamera.rawValue)
        #expect(uri.hasPrefix("X-HM://") && uri.hasSuffix("1QJ8") && uri.count == 7 + 9 + 4)
    }
}
