// HomeKit pairing, the accessory's side.
//
// Pair setup (once, with the setup code): SRP proves both sides know the code (M1–M4); then, encrypted with
// the SRP key, each sends its long-term Ed25519 public key and a signature over it (M5, M6). The accessory
// keeps the controller's key as its first, admin pairing.
//
// Pair verify (every connection): an X25519 exchange, each side signing both ephemeral keys with its
// long-term key (M1–M4). The shared secret gives the session's two ChaCha20-Poly1305 keys.
import CryptoKit
import Foundation

/// HAP's TLV types for pairing.
public enum PairingTLV {
    public static let method: UInt8 = 0x00
    public static let identifier: UInt8 = 0x01
    public static let salt: UInt8 = 0x02
    public static let publicKey: UInt8 = 0x03
    public static let proof: UInt8 = 0x04
    public static let encryptedData: UInt8 = 0x05
    public static let state: UInt8 = 0x06
    public static let error: UInt8 = 0x07
    public static let signature: UInt8 = 0x0A
    public static let permissions: UInt8 = 0x0B
    public static let flags: UInt8 = 0x13
}

/// HAP's pairing errors.
public enum PairingError: UInt8, Error, Sendable {
    case unknown = 1, authentication = 2, backoff = 3, maxPeers = 4, maxTries = 5, unavailable = 6, busy = 7
}

/// An accessory's identity: its device ID (also its pairing identifier) and long-term signing key.
public struct AccessoryIdentity: Sendable {
    /// Like a MAC address: "AA:BB:CC:DD:EE:FF". It changes only if the accessory is reset.
    public let deviceID: String
    public let signingKey: Curve25519.Signing.PrivateKey

    public init(deviceID: String, signingKey: Curve25519.Signing.PrivateKey) {
        self.deviceID = deviceID
        self.signingKey = signingKey
    }

    /// A new identity, for an accessory not yet set up.
    public static func generate() -> AccessoryIdentity {
        let bytes = SRPServer.random(6)
        return AccessoryIdentity(deviceID: bytes.map { String(format: "%02X", $0) }.joined(separator: ":"),
                                 signingKey: Curve25519.Signing.PrivateKey())
    }
}

/// A controller (an iPhone, a home hub) paired with the accessory.
public struct PairedController: Codable, Equatable, Sendable {
    public var identifier: String
    public var publicKey: [UInt8]
    public var admin: Bool

    public init(identifier: String, publicKey: [UInt8], admin: Bool) {
        self.identifier = identifier
        self.publicKey = publicKey
        self.admin = admin
    }
}

/// Where an accessory keeps its pairings (the Keychain, in the app).
public protocol PairingStore: AnyObject, Sendable {
    func pairings() -> [PairedController]
    func save(_ pairings: [PairedController])
}

public final class MemoryPairingStore: PairingStore, @unchecked Sendable {
    private var list: [PairedController] = []
    private let lock = NSLock()
    public init(_ list: [PairedController] = []) { self.list = list }
    public func pairings() -> [PairedController] { lock.withLock { list } }
    public func save(_ pairings: [PairedController]) { lock.withLock { list = pairings } }
}

enum HAPCrypto {
    static func hkdf(_ secret: [UInt8], salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Array(salt.utf8),
                               info: Array(info.utf8), outputByteCount: 32)
    }

    static func hkdfBytes(_ secret: [UInt8], salt: [UInt8], info: String, count: Int = 32) -> [UInt8] {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: Array(info.utf8),
                               outputByteCount: count).withUnsafeBytes { Array($0) }
    }

    /// The 12-byte nonce for a pairing message: four zero bytes, then its 8-character label.
    static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: [0, 0, 0, 0] + Array(label.utf8))
    }

    static func seal(_ plain: [UInt8], key: SymmetricKey, nonce: ChaChaPoly.Nonce) -> [UInt8] {
        let box = try! ChaChaPoly.seal(plain, using: key, nonce: nonce)
        return Array(box.ciphertext) + Array(box.tag)
    }

    static func open(_ sealed: [UInt8], key: SymmetricKey, nonce: ChaChaPoly.Nonce) -> [UInt8]? {
        guard sealed.count >= 16,
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        else { return nil }
        return (try? ChaChaPoly.open(box, using: key)).map(Array.init)
    }
}

extension Array where Element == TLV8Item {
    static func error(state: UInt8, _ error: PairingError) -> [TLV8Item] {
        [TLV8Item(PairingTLV.state, [state]), TLV8Item(PairingTLV.error, [error.rawValue])]
    }
}

/// Pair setup, one attempt at a time. Feed it each request's TLVs; it returns the reply's.
public final class PairSetup: @unchecked Sendable {
    let identity: AccessoryIdentity
    let store: PairingStore
    let setupCode: String
    private var srp: SRPServer?
    private var session: SRPServer.Session?
    /// Failed attempts since start; after 100 the accessory refuses until restarted, as HAP requires.
    private var failures = 0
    private let lock = NSLock()

    public init(identity: AccessoryIdentity, store: PairingStore, setupCode: String) {
        self.identity = identity
        self.store = store
        self.setupCode = setupCode
    }

    public func handle(_ request: [TLV8Item]) -> [TLV8Item] {
        lock.withLock {
            switch request.value(PairingTLV.state)?.first {
            case 1: m1()
            case 3: m3(request)
            case 5: m5(request)
            default: .error(state: 2, .unknown)
            }
        }
    }

    private func m1() -> [TLV8Item] {
        guard store.pairings().isEmpty else { return .error(state: 2, .unavailable) }
        guard failures < 100 else { return .error(state: 2, .maxTries) }
        let srp = SRPServer(username: "Pair-Setup", password: setupCode)
        self.srp = srp
        session = nil
        return [TLV8Item(PairingTLV.state, [2]), TLV8Item(PairingTLV.publicKey, srp.publicKey),
                TLV8Item(PairingTLV.salt, srp.salt)]
    }

    private func m3(_ request: [TLV8Item]) -> [TLV8Item] {
        guard let srp, let a = request.value(PairingTLV.publicKey), let proof = request.value(PairingTLV.proof),
              let session = srp.session(controllerPublicKey: a), session.verify(controllerProof: proof) else {
            failures += 1
            self.srp = nil
            return .error(state: 4, .authentication)
        }
        self.session = session
        return [TLV8Item(PairingTLV.state, [4]), TLV8Item(PairingTLV.proof, session.proof)]
    }

    private func m5(_ request: [TLV8Item]) -> [TLV8Item] {
        guard let session, let sealed = request.value(PairingTLV.encryptedData) else { return .error(state: 6, .authentication) }
        let key = HAPCrypto.hkdf(session.key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        guard let plain = HAPCrypto.open(sealed, key: key, nonce: HAPCrypto.nonce("PS-Msg05")),
              let sub = try? TLV8.decode(plain),
              let controllerID = sub.value(PairingTLV.identifier), let ltpk = sub.value(PairingTLV.publicKey),
              let signature = sub.value(PairingTLV.signature),
              let controllerKey = try? Curve25519.Signing.PublicKey(rawRepresentation: ltpk) else {
            return .error(state: 6, .authentication)
        }
        let controllerX = HAPCrypto.hkdfBytes(session.key, salt: Array("Pair-Setup-Controller-Sign-Salt".utf8),
                                              info: "Pair-Setup-Controller-Sign-Info")
        guard controllerKey.isValidSignature(signature, for: controllerX + controllerID + ltpk) else {
            return .error(state: 6, .authentication)
        }
        store.save([PairedController(identifier: String(decoding: controllerID, as: UTF8.self), publicKey: ltpk, admin: true)])

        let accessoryX = HAPCrypto.hkdfBytes(session.key, salt: Array("Pair-Setup-Accessory-Sign-Salt".utf8),
                                             info: "Pair-Setup-Accessory-Sign-Info")
        let accessoryID = Array(identity.deviceID.utf8)
        let accessoryLTPK = Array(identity.signingKey.publicKey.rawRepresentation)
        let accessorySignature = Array(try! identity.signingKey.signature(for: accessoryX + accessoryID + accessoryLTPK))
        let reply = TLV8.encode([TLV8Item(PairingTLV.identifier, accessoryID), TLV8Item(PairingTLV.publicKey, accessoryLTPK),
                                 TLV8Item(PairingTLV.signature, accessorySignature)])
        self.session = nil
        srp = nil
        return [TLV8Item(PairingTLV.state, [6]),
                TLV8Item(PairingTLV.encryptedData, HAPCrypto.seal(reply, key: key, nonce: HAPCrypto.nonce("PS-Msg06")))]
    }
}

/// The keys of an encrypted session, from pair verify.
public struct SessionKeys: Sendable {
    /// The X25519 shared secret (HomeKit Data Stream derives its keys from it too).
    public let sharedSecret: [UInt8]
    /// Accessory to controller, and controller to accessory.
    public let outgoing: SymmetricKey
    public let incoming: SymmetricKey
    /// The paired controller at the other end.
    public let controller: PairedController

    init(sharedSecret: [UInt8], controller: PairedController) {
        self.sharedSecret = sharedSecret
        self.controller = controller
        outgoing = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        incoming = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
    }
}

/// Pair verify, for one connection.
public final class PairVerify: @unchecked Sendable {
    let identity: AccessoryIdentity
    let store: PairingStore
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var controllerPublic: [UInt8]?
    private var shared: [UInt8]?
    /// Set once verified: the connection's keys.
    public private(set) var keys: SessionKeys?

    public init(identity: AccessoryIdentity, store: PairingStore) {
        self.identity = identity
        self.store = store
    }

    public func handle(_ request: [TLV8Item]) -> [TLV8Item] {
        switch request.value(PairingTLV.state)?.first {
        case 1: m1(request)
        case 3: m3(request)
        default: .error(state: 2, .unknown)
        }
    }

    private func m1(_ request: [TLV8Item]) -> [TLV8Item] {
        guard let theirs = request.value(PairingTLV.publicKey),
              let theirKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs) else {
            return .error(state: 2, .authentication)
        }
        let mine = Curve25519.KeyAgreement.PrivateKey()
        guard let secret = try? mine.sharedSecretFromKeyAgreement(with: theirKey) else { return .error(state: 2, .authentication) }
        let shared = secret.withUnsafeBytes { Array($0) }
        let minePublic = Array(mine.publicKey.rawRepresentation)
        let accessoryID = Array(identity.deviceID.utf8)
        let signature = Array(try! identity.signingKey.signature(for: minePublic + accessoryID + theirs))
        let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let sub = TLV8.encode([TLV8Item(PairingTLV.identifier, accessoryID), TLV8Item(PairingTLV.signature, signature)])
        ephemeral = mine
        controllerPublic = theirs
        self.shared = shared
        return [TLV8Item(PairingTLV.state, [2]), TLV8Item(PairingTLV.publicKey, minePublic),
                TLV8Item(PairingTLV.encryptedData, HAPCrypto.seal(sub, key: key, nonce: HAPCrypto.nonce("PV-Msg02")))]
    }

    private func m3(_ request: [TLV8Item]) -> [TLV8Item] {
        guard let ephemeral, let controllerPublic, let shared, let sealed = request.value(PairingTLV.encryptedData) else {
            return .error(state: 4, .authentication)
        }
        let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        guard let plain = HAPCrypto.open(sealed, key: key, nonce: HAPCrypto.nonce("PV-Msg03")),
              let sub = try? TLV8.decode(plain),
              let idBytes = sub.value(PairingTLV.identifier), let signature = sub.value(PairingTLV.signature) else {
            return .error(state: 4, .authentication)
        }
        let id = String(decoding: idBytes, as: UTF8.self)
        guard let pairing = store.pairings().first(where: { $0.identifier == id }),
              let ltpk = try? Curve25519.Signing.PublicKey(rawRepresentation: pairing.publicKey),
              ltpk.isValidSignature(signature, for: controllerPublic + idBytes + Array(ephemeral.publicKey.rawRepresentation))
        else {
            return .error(state: 4, .authentication)
        }
        keys = SessionKeys(sharedSecret: shared, controller: pairing)
        return [TLV8Item(PairingTLV.state, [4])]
    }
}

/// Adding, removing and listing pairings: admin controllers only, over a verified session.
public enum Pairings {
    public static func handle(_ request: [TLV8Item], from controller: PairedController, store: PairingStore) -> [TLV8Item] {
        guard controller.admin else { return .error(state: 2, .authentication) }
        var list = store.pairings()
        switch request.value(PairingTLV.method)?.first {
        case 3:   // add
            guard let id = request.value(PairingTLV.identifier), let key = request.value(PairingTLV.publicKey) else {
                return .error(state: 2, .unknown)
            }
            let identifier = String(decoding: id, as: UTF8.self)
            let admin = request.value(PairingTLV.permissions)?.first == 1
            if let i = list.firstIndex(where: { $0.identifier == identifier }) {
                guard list[i].publicKey == key else { return .error(state: 2, .unknown) }
                list[i].admin = admin
            } else {
                guard list.count < 16 else { return .error(state: 2, .maxPeers) }
                list.append(PairedController(identifier: identifier, publicKey: key, admin: admin))
            }
            store.save(list)
            return [TLV8Item(PairingTLV.state, [2])]
        case 4:   // remove
            guard let id = request.value(PairingTLV.identifier) else { return .error(state: 2, .unknown) }
            list.removeAll { $0.identifier == String(decoding: id, as: UTF8.self) }
            store.save(list)
            return [TLV8Item(PairingTLV.state, [2])]
        case 5:   // list
            let entries = list.map { p in
                [TLV8Item(PairingTLV.identifier, Array(p.identifier.utf8)), TLV8Item(PairingTLV.publicKey, p.publicKey),
                 TLV8Item(PairingTLV.permissions, [p.admin ? 1 : 0])]
            }
            // Entries apart by separator items.
            let separated = entries.enumerated().flatMap { i, e in i == 0 ? e : [TLV8Item(TLV8.separator, [])] + e }
            return [TLV8Item(PairingTLV.state, [2])] + separated
        default:
            return .error(state: 2, .unknown)
        }
    }
}
