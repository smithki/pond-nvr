// SRP-6a (RFC 5054), the accessory's (server's) side, as HomeKit pair-setup uses it: the 3072-bit group,
// SHA-512, username "Pair-Setup" and the setup code as the password. Numbers sent or hashed are padded to the
// group's length, as HomeKit's implementations do.
//
//   x = H(s | H(I ":" P))      v = g^x            k = H(N | PAD(g))
//   B = k·v + g^b              u = H(PAD(A) | PAD(B))
//   S = (A · v^u)^b            K = H(S)
//   M1 = H(H(N) xor H(g) | H(I) | s | PAD(A) | PAD(B) | K)          M2 = H(PAD(A) | M1 | K)
//
// In M1, N and g are hashed as their own bytes, not padded (g is the single byte 5), as HomeKit does;
// padding g there makes every proof from the Home app look wrong.
import CryptoKit
import Foundation

public struct SRPGroup: Sendable {
    public let n: BigUInt
    public let g: BigUInt
    /// N's length in bytes, which numbers are padded to.
    public var length: Int { n.bytes().count }

    /// RFC 5054's 3072-bit group, generator 5: HomeKit's.
    public static let rfc5054_3072 = SRPGroup(n: BigUInt(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """)!, g: BigUInt(5))

    /// RFC 5054's 1024-bit group, generator 2: for its test vectors.
    public static let rfc5054_1024 = SRPGroup(n: BigUInt(hex: """
        EEAF0AB9ADB38DD69C33F80AFA8FC5E860726187 75FF3C0B9EA2314C9C256576D674DF7496EA81D3383B4813D692C6E0E0D5D8E250B98BE48E495C1D6089DAD15DC7D7B46154D6B6CE8EF4AD69B15D4982559B297BCF1885C529F566660E57EC68EDBC3C05726CC02FD4CBF4976EAA9AFD5138FE8376435B9FC61D2FC0EB06E3
        """)!, g: BigUInt(2))
}

/// The hash SRP uses: SHA-512 for HomeKit, SHA-1 for RFC 5054's test vectors.
public struct SRPHash: Sendable {
    public let digest: @Sendable ([UInt8]) -> [UInt8]

    public static let sha512 = SRPHash { Array(SHA512.hash(data: $0)) }
    public static let sha1 = SRPHash { Array(Insecure.SHA1.hash(data: $0)) }

    func callAsFunction(_ parts: [UInt8]...) -> [UInt8] { digest(parts.flatMap { $0 }) }
}

/// One pairing attempt, on the accessory.
public struct SRPServer: Sendable {
    public let group: SRPGroup
    let hash: SRPHash
    public let username: [UInt8]
    public let salt: [UInt8]
    let verifier: BigUInt
    let b: BigUInt
    /// The accessory's public value, sent to the controller.
    public let publicKey: [UInt8]

    /// - Parameters:
    ///   - salt: 16 random bytes; `privateKey`: 32 random bytes. Given only by tests.
    public init(username: String, password: String, group: SRPGroup = .rfc5054_3072, hash: SRPHash = .sha512,
                salt: [UInt8]? = nil, privateKey: [UInt8]? = nil) {
        self.group = group
        self.hash = hash
        self.username = Array(username.utf8)
        self.salt = salt ?? Self.random(16)
        let x = BigUInt(bytes: hash(self.salt, hash(Array("\(username):\(password)".utf8))))
        verifier = group.g.power(x, modulus: group.n)
        b = BigUInt(bytes: privateKey ?? Self.random(32))
        let k = BigUInt(bytes: hash(group.n.bytes(), group.g.bytes(length: group.length)))
        let bigB = (k * verifier + group.g.power(b, modulus: group.n)) % group.n
        publicKey = bigB.bytes(length: group.length)
    }

    static func random(_ count: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &g) }
    }

    /// The verifier, v = g^x.
    public var verifierBytes: [UInt8] { verifier.bytes() }

    public struct Session: Sendable {
        /// The shared key, K = H(S).
        public let key: [UInt8]
        /// The premaster secret, S (for tests).
        public let premaster: BigUInt
        /// What the controller's proof must be.
        let expectedProof: [UInt8]
        /// The accessory's proof, sent once the controller's checks out.
        public let proof: [UInt8]

        public func verify(controllerProof: [UInt8]) -> Bool {
            guard controllerProof.count == expectedProof.count else { return false }
            // Compared in full whatever matches, so timing says nothing.
            return zip(controllerProof, expectedProof).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
        }
    }

    /// Takes the controller's public value A; nil if it is not acceptable (A mod N = 0).
    public func session(controllerPublicKey aBytes: [UInt8]) -> Session? {
        let a = BigUInt(bytes: aBytes)
        guard !(a % group.n).isZero else { return nil }
        let padA = a.bytes(length: group.length)
        let u = BigUInt(bytes: hash(padA, publicKey))
        guard !u.isZero else { return nil }
        let s = (a * verifier.power(u, modulus: group.n)).power(b, modulus: group.n)
        let key = hash(s.bytes(length: group.length))
        let hn = hash(group.n.bytes()), hg = hash(group.g.bytes())
        let hxor = zip(hn, hg).map { $0 ^ $1 }
        let m1 = hash(hxor, hash(username), salt, padA, publicKey, key)
        let m2 = hash(padA, m1, key)
        return Session(key: key, premaster: s, expectedProof: m1, proof: m2)
    }
}
