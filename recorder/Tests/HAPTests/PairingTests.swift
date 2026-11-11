import CryptoKit
import Foundation
import Testing
@testable import HAP

/// A controller (the Home app's side of pairing), to drive the accessory through it.
struct TestController {
    let identifier = "A1B2C3D4-0000-4000-8000-000000000001"
    let signingKey = Curve25519.Signing.PrivateKey()

    /// Pair setup, M1 to M6. Returns the accessory's long-term public key, or the error it gave.
    func pairSetup(with setup: PairSetup, code: String) throws -> Result<[UInt8], PairingError> {
        let m2 = setup.handle([TLV8Item(PairingTLV.state, [1]), TLV8Item(PairingTLV.method, [0])])
        if let e = m2.value(PairingTLV.error)?.first { return .failure(PairingError(rawValue: e)!) }
        let salt = try need(m2.value(PairingTLV.salt)), b = try need(m2.value(PairingTLV.publicKey))
        let srp = SRPClient(group: .rfc5054_3072, hash: .sha512, a: BigUInt(bytes: SRPServer.random(32)))
        let reply = srp.respond(username: "Pair-Setup", password: code, salt: salt, serverPublicKey: b)

        let m4 = setup.handle([TLV8Item(PairingTLV.state, [3]), TLV8Item(PairingTLV.publicKey, srp.publicKey),
                               TLV8Item(PairingTLV.proof, reply.proof)])
        if let e = m4.value(PairingTLV.error)?.first { return .failure(PairingError(rawValue: e)!) }

        let key = HAPCrypto.hkdf(reply.key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let x = HAPCrypto.hkdfBytes(reply.key, salt: Array("Pair-Setup-Controller-Sign-Salt".utf8),
                                    info: "Pair-Setup-Controller-Sign-Info")
        let ltpk = Array(signingKey.publicKey.rawRepresentation)
        let signature = Array(try signingKey.signature(for: x + Array(identifier.utf8) + ltpk))
        let sub = TLV8.encode([TLV8Item(PairingTLV.identifier, Array(identifier.utf8)),
                               TLV8Item(PairingTLV.publicKey, ltpk), TLV8Item(PairingTLV.signature, signature)])
        let m6 = setup.handle([TLV8Item(PairingTLV.state, [5]),
                               TLV8Item(PairingTLV.encryptedData, HAPCrypto.seal(sub, key: key, nonce: HAPCrypto.nonce("PS-Msg05")))])
        if let e = m6.value(PairingTLV.error)?.first { return .failure(PairingError(rawValue: e)!) }

        let plain = try need(HAPCrypto.open(try need(m6.value(PairingTLV.encryptedData)), key: key,
                                                nonce: HAPCrypto.nonce("PS-Msg06")))
        let inner = try TLV8.decode(plain)
        let accessoryID = try need(inner.value(PairingTLV.identifier))
        let accessoryLTPK = try need(inner.value(PairingTLV.publicKey))
        let ax = HAPCrypto.hkdfBytes(reply.key, salt: Array("Pair-Setup-Accessory-Sign-Salt".utf8),
                                     info: "Pair-Setup-Accessory-Sign-Info")
        let ok = try Curve25519.Signing.PublicKey(rawRepresentation: accessoryLTPK)
            .isValidSignature(try need(inner.value(PairingTLV.signature)), for: ax + accessoryID + accessoryLTPK)
        #expect(ok)
        return .success(accessoryLTPK)
    }

    /// Pair verify, M1 to M4. Returns the shared secret, or nil if refused.
    func pairVerify(with verify: PairVerify, accessoryLTPK: [UInt8], accessoryID: String) throws -> [UInt8]? {
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let minePublic = Array(mine.publicKey.rawRepresentation)
        let m2 = verify.handle([TLV8Item(PairingTLV.state, [1]), TLV8Item(PairingTLV.publicKey, minePublic)])
        let theirs = try need(m2.value(PairingTLV.publicKey))
        let shared = try mine.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs)).withUnsafeBytes { Array($0) }
        let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let inner = try TLV8.decode(try need(HAPCrypto.open(try need(m2.value(PairingTLV.encryptedData)), key: key,
                                                                 nonce: HAPCrypto.nonce("PV-Msg02"))))
        #expect(inner.value(PairingTLV.identifier) == Array(accessoryID.utf8))
        let accessorySigned = theirs + Array(accessoryID.utf8) + minePublic
        #expect(try Curve25519.Signing.PublicKey(rawRepresentation: accessoryLTPK)
            .isValidSignature(try need(inner.value(PairingTLV.signature)), for: accessorySigned))

        let signature = Array(try signingKey.signature(for: minePublic + Array(identifier.utf8) + theirs))
        let sub = TLV8.encode([TLV8Item(PairingTLV.identifier, Array(identifier.utf8)), TLV8Item(PairingTLV.signature, signature)])
        let m4 = verify.handle([TLV8Item(PairingTLV.state, [3]),
                                TLV8Item(PairingTLV.encryptedData, HAPCrypto.seal(sub, key: key, nonce: HAPCrypto.nonce("PV-Msg03")))])
        return m4.value(PairingTLV.error) == nil ? shared : nil
    }
}

@Suite struct PairingTests {
    let identity = AccessoryIdentity.generate()

    @Test func pairSetupThenVerify() throws {
        let store = MemoryPairingStore()
        let controller = TestController()
        let setup = PairSetup(identity: identity, store: store, setupCode: "031-45-154")
        let ltpk = try controller.pairSetup(with: setup, code: "031-45-154").get()
        #expect(ltpk == Array(identity.signingKey.publicKey.rawRepresentation))
        #expect(store.pairings() == [PairedController(identifier: controller.identifier,
                                                      publicKey: Array(controller.signingKey.publicKey.rawRepresentation), admin: true)])

        let verify = PairVerify(identity: identity, store: store)
        let shared = try need(try controller.pairVerify(with: verify, accessoryLTPK: ltpk, accessoryID: identity.deviceID))
        let keys = try need(verify.keys)
        #expect(keys.sharedSecret == shared)
        #expect(keys.controller.identifier == controller.identifier)

        // Once paired, pair setup is refused.
        let again = PairSetup(identity: identity, store: store, setupCode: "031-45-154")
        #expect(try TestController().pairSetup(with: again, code: "031-45-154") == .failure(.unavailable))
    }

    @Test func wrongSetupCodeIsRefused() throws {
        let store = MemoryPairingStore()
        let setup = PairSetup(identity: identity, store: store, setupCode: "031-45-154")
        #expect(try TestController().pairSetup(with: setup, code: "111-11-111") == .failure(.authentication))
        #expect(store.pairings().isEmpty)
    }

    @Test func unknownControllerFailsVerify() throws {
        let store = MemoryPairingStore()
        let paired = TestController()
        let ltpk = try paired.pairSetup(with: PairSetup(identity: identity, store: store, setupCode: "031-45-154"),
                                        code: "031-45-154").get()
        let stranger = TestController()   // same identifier, other key
        let verify = PairVerify(identity: identity, store: store)
        #expect(try stranger.pairVerify(with: verify, accessoryLTPK: ltpk, accessoryID: identity.deviceID) == nil)
        #expect(verify.keys == nil)
    }

    @Test func adminsManagePairings() throws {
        let admin = PairedController(identifier: "admin", publicKey: [1], admin: true)
        let store = MemoryPairingStore([admin])
        let add = Pairings.handle([TLV8Item(PairingTLV.method, [3]), TLV8Item(PairingTLV.identifier, Array("hub".utf8)),
                                   TLV8Item(PairingTLV.publicKey, [2]), TLV8Item(PairingTLV.permissions, [0])],
                                  from: admin, store: store)
        #expect(add.value(PairingTLV.error) == nil)
        #expect(store.pairings().map(\.identifier) == ["admin", "hub"])
        // A non-admin cannot.
        let hub = store.pairings()[1]
        #expect(Pairings.handle([TLV8Item(PairingTLV.method, [5])], from: hub, store: store).value(PairingTLV.error) == [2])
        let list = Pairings.handle([TLV8Item(PairingTLV.method, [5])], from: admin, store: store)
        #expect(list.filter { $0.type == PairingTLV.identifier }.count == 2)
        _ = Pairings.handle([TLV8Item(PairingTLV.method, [4]), TLV8Item(PairingTLV.identifier, Array("hub".utf8))],
                            from: admin, store: store)
        #expect(store.pairings().map(\.identifier) == ["admin"])
    }
}


struct Missing: Error {}

/// The value, or a test failure (#require cannot be nested in itself).
func need<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    guard let value else {
        Issue.record("missing value", sourceLocation: sourceLocation)
        throw Missing()
    }
    return value
}
