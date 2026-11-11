import Foundation
import Testing
@testable import HAP

/// What a controller (the Home app) does, to test the accessory's side against.
struct SRPClient {
    let group: SRPGroup
    let hash: SRPHash
    let a: BigUInt
    var publicKey: [UInt8] { group.g.power(a, modulus: group.n).bytes(length: group.length) }

    /// The shared key and the controller's proof, from the accessory's salt and public value.
    func respond(username: String, password: String, salt: [UInt8], serverPublicKey: [UInt8]) -> (key: [UInt8], proof: [UInt8], premaster: BigUInt) {
        let n = group.n, g = group.g
        let padA = publicKey, padB = BigUInt(bytes: serverPublicKey).bytes(length: group.length)
        let u = BigUInt(bytes: hash(padA, padB))
        let x = BigUInt(bytes: hash(salt, hash(Array("\(username):\(password)".utf8))))
        let k = BigUInt(bytes: hash(n.bytes(), g.bytes(length: group.length)))
        let gx = g.power(x, modulus: n)
        // (B − k·g^x) mod N, kept positive.
        let base = (BigUInt(bytes: serverPublicKey) + n * k - (k * gx) % n) % n
        let s = base.power(a + u * x, modulus: n)
        let key = hash(s.bytes(length: group.length))
        let hxor = zip(hash(n.bytes()), hash(g.bytes())).map { $0 ^ $1 }
        let proof = hash(hxor, hash(Array(username.utf8)), salt, padA, padB, key)
        return (key, proof, s)
    }
}

@Suite struct SRPTests {
    // RFC 5054, appendix B.
    static let salt = BigUInt(hex: "BEB25379 D1A8581E B5A72767 3A2441EE")!.bytes()
    static let a = BigUInt(hex: "60975527 035CF2AD 1989806F 0407210B C81EDC04 E2762A56 AFD529DD DA2D4393")!
    static let b = BigUInt(hex: "E487CB59 D31AC550 471E81F0 0F6928E0 1DDA08E9 74A004F4 9E61F5D1 05284D20")!

    @Test func rfc5054Vectors() throws {
        let server = SRPServer(username: "alice", password: "password123", group: .rfc5054_1024, hash: .sha1,
                               salt: Self.salt, privateKey: Self.b.bytes())
        #expect(server.verifierBytes == BigUInt(hex: """
            7E273DE8 696FFC4F 4E337D05 B4B375BE B0DDE156 9E8FA00A 9886D812 9BADA1F1 822223CA 1A605B53 0E379BA4
            729FDC59 F105B478 7E5186F5 C671085A 1447B52A 48CF1970 B4FB6F84 00BBF4CE BFBB1681 52E08AB5 EA53D15C
            1AFF87B2 B9DA6E04 E058AD51 CC72BFC9 033B564E 26480D78 E955A5E2 9E7AB245 DB2BE315 E2099AFB
            """)!.bytes())
        #expect(BigUInt(bytes: server.publicKey) == BigUInt(hex: """
            BD0C6151 2C692C0C B6D041FA 01BB152D 4916A1E7 7AF46AE1 05393011 BAF38964 DC46A067 0DD125B9 5A981652
            236F99D9 B681CBF8 7837EC99 6C6DA044 53728610 D0C6DDB5 8B318885 D7D82C7F 8DEB75CE 7BD4FBAA 37089E6F
            9C6059F3 88838E7A 00030B33 1EB76840 910440B1 B27AAEAE EB4012B7 D7665238 A8E3FB00 4B117B58
            """))
        let client = SRPClient(group: .rfc5054_1024, hash: .sha1, a: Self.a)
        #expect(BigUInt(bytes: client.publicKey) == BigUInt(hex: """
            61D5E490 F6F1B795 47B0704C 436F523D D0E560F0 C64115BB 72557EC4 4352E890 3211C046 92272D8B 2D1A5358
            A2CF1B6E 0BFCF99F 921530EC 8E393561 79EAE45E 42BA92AE ACED8251 71E1E8B9 AF6D9C03 E1327F44 BE087EF0
            6530E69F 66615261 EEF54073 CA11CF58 58F0EDFD FE15EFEA B349EF5D 76988A36 72FAC47B 0769447B
            """))
        let session = try #require(server.session(controllerPublicKey: client.publicKey))
        let premaster = BigUInt(hex: """
            B0DC82BA BCF30674 AE450C02 87745E79 90A3381F 63B387AA F271A10D 233861E3 59B48220 F7C4693C 9AE12B0A
            6F67809F 0876E2D0 13800D6C 41BB59B6 D5979B5C 00A172B4 A2A5903A 0BDCAF8A 709585EB 2AFAFA8F 3499B200
            210DCC1F 10EB3394 3CD67FC8 8A2F39A4 BE5BEC4E C0A3212D C346D7E4 74B29EDE 8A469FFE CA686E5A
            """)
        #expect(session.premaster == premaster)
        #expect(client.respond(username: "alice", password: "password123", salt: Self.salt,
                               serverPublicKey: server.publicKey).premaster == premaster)
    }

    @Test func homeKitExchange() throws {
        let server = SRPServer(username: "Pair-Setup", password: "123-45-678")
        let client = SRPClient(group: .rfc5054_3072, hash: .sha512, a: BigUInt(bytes: SRPServer.random(32)))
        let reply = client.respond(username: "Pair-Setup", password: "123-45-678", salt: server.salt,
                                   serverPublicKey: server.publicKey)
        let session = try #require(server.session(controllerPublicKey: client.publicKey))
        #expect(session.key == reply.key)
        #expect(session.verify(controllerProof: reply.proof))
        #expect(server.publicKey.count == 384)
        #expect(session.key.count == 64)
        // The wrong setup code gives a proof that does not check out.
        let wrong = client.respond(username: "Pair-Setup", password: "111-11-111", salt: server.salt,
                                   serverPublicKey: server.publicKey)
        #expect(!session.verify(controllerProof: wrong.proof))
        #expect(server.session(controllerPublicKey: server.group.n.bytes()) == nil)
    }

    /// Fixed inputs, checked against a port of fast-srp-hap (HAP-NodeJS's SRP) rather than our own client.
    @Test func matchesFastSRPHAP() throws {
        let server = SRPServer(username: "Pair-Setup", password: "031-45-154", salt: Array(0 ..< 16),
                               privateKey: Array(100 ..< 132))
        let client = SRPClient(group: .rfc5054_3072, hash: .sha512, a: BigUInt(bytes: Array(200 ..< 232)))
        let session = try #require(server.session(controllerPublicKey: client.publicKey))
        let hex = { (b: [UInt8]) in b.map { String(format: "%02x", $0) }.joined() }
        #expect(hex(session.key) == "2c19b798c7c540e94442dbfeb5590b3722f0e7da7720f7bbd494501e64dafdebd95afd37e8c41eb0006fcdb225d89d17c2ff68e25a7e958b3908d4b6bb8ab12e")
        #expect(hex(session.expectedProof) == "9d15b511aac507ae133d118842e59ae2e97d2957d4d5b1b198de8be5b541ee3985bd70a766fff94f3360a5d2bdc45f3995cb51b42326ccbe1f3805b48dcfcd06")
        #expect(hex(session.proof) == "664dc7c22a2b78b3050fad03d89e0d5a92e3b189fde45e673cbe9ad5183154ed8d08033d8fcab0cce84d1541e1e808f531f053e6881589ddf9e66611d34c92b8")
    }
}
