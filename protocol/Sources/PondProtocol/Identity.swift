// SPDX-License-Identifier: MIT
// Who's who in remote access: each Pond, and each device paired with it, has an identity of its own (an Ed25519 key
// to sign with, an X25519 key to be sealed to), kept in the Keychain. Its public half is what others know of it: an
// id (a short hash of its signing key), its keys, a name, and its mailbox at the signaling service (the hash of a
// secret only it can derive, so only it can collect what's sent there; the service can check that with a hash, and
// never needs to read a thing).
import CryptoKit
import Foundation

public struct RemoteIdentity: Sendable {
    public let signing: Curve25519.Signing.PrivateKey
    public let agreement: Curve25519.KeyAgreement.PrivateKey
    public var name: String

    public init(name: String, signing: Curve25519.Signing.PrivateKey = .init(), agreement: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.name = name
        self.signing = signing
        self.agreement = agreement
    }

    public var peer: RemotePeer {
        RemotePeer(name: name, signingKey: signing.publicKey.rawRepresentation, agreementKey: agreement.publicKey.rawRepresentation,
                   mailbox: Self.mailbox(of: mailboxSecret))
    }

    /// What proves this identity owns its mailbox (to the signaling service): derived from its own key, so the
    /// same every time, and known to no one else.
    public var mailboxSecret: Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: agreement.rawRepresentation),
                                         info: Data("pond mailbox".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// A mailbox's address: the hash of its secret, in hex.
    public static func mailbox(of secret: Data) -> String {
        SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Kept

    /// How an identity is kept (as JSON, by whoever keeps it: the recorder's RemoteKeys, in the Keychain).
    public struct Stored: Codable, Sendable {
        public var name: String
        public var signing: Data
        public var agreement: Data
    }

    public func stored() -> Stored { Stored(name: name, signing: signing.rawRepresentation, agreement: agreement.rawRepresentation) }

    public init(_ stored: Stored) throws {
        name = stored.name
        signing = try .init(rawRepresentation: stored.signing)
        agreement = try .init(rawRepresentation: stored.agreement)
    }
}

/// Another identity, as known: its keys, its name, its mailbox.
public struct RemotePeer: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var signingKey: Data
    public var agreementKey: Data
    public var mailbox: String

    public init(name: String, signingKey: Data, agreementKey: Data, mailbox: String) {
        self.name = name
        self.signingKey = signingKey
        self.agreementKey = agreementKey
        self.mailbox = mailbox
    }

    /// A short, stable id: the first 8 bytes of its signing key's hash, in hex.
    public var id: String { SHA256.hash(data: signingKey).prefix(8).map { String(format: "%02x", $0) }.joined() }
}
