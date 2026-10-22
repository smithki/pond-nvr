// Who's who in remote access: each Pond, and each device paired with it, has an identity of its own (an Ed25519 key
// to sign with, an X25519 key to be sealed to), kept in the Keychain. Its public half is what others know of it: an
// id (a short hash of its signing key), its keys, a name, and its mailbox at the signaling service (the hash of a
// secret only it can derive, so only it can collect what's sent there; the service can check that with a hash, and
// never needs to read a thing).
import CryptoKit
import Foundation
import NVRCore

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

    struct Stored: Codable {
        var name: String
        var signing: Data
        var agreement: Data
    }

    func stored() -> Stored { Stored(name: name, signing: signing.rawRepresentation, agreement: agreement.rawRepresentation) }

    init(_ stored: Stored) throws {
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

/// What remote access keeps: this end's identity, and the peers paired with it.
public final class RemoteKeys: @unchecked Sendable {
    let store: CredentialStore
    private let lock = NSLock()
    static let identityAccount = "identity", peersAccount = "peers", relayAccount = "relay-secret"

    /// Over a credential store (the Keychain's, service `pond-remote`, in Pond; a memory one in tests).
    public init(store: CredentialStore) { self.store = store }

    /// This end's identity: made (and kept) the first time it's asked for.
    public func identity(name: String) throws -> RemoteIdentity {
        try lock.withLock {
            if let text = try store.password(for: Self.identityAccount),
               let stored = try? JSONDecoder().decode(RemoteIdentity.Stored.self, from: Data(text.utf8)) {
                return try RemoteIdentity(stored)
            }
            let made = RemoteIdentity(name: name)
            try store.setPassword(String(decoding: try JSONEncoder().encode(made.stored()), as: UTF8.self), for: Self.identityAccount)
            return made
        }
    }

    public func peers() -> [RemotePeer] {
        lock.withLock {
            (try? store.password(for: Self.peersAccount)).flatMap { $0 }
                .flatMap { try? JSONDecoder().decode([RemotePeer].self, from: Data($0.utf8)) } ?? []
        }
    }

    /// Paired (or paired again: its name updated).
    public func add(_ peer: RemotePeer) throws {
        try save(peers().filter { $0.id != peer.id } + [peer])
    }

    public func remove(_ id: String) throws {
        try save(peers().filter { $0.id != id })
    }

    public func peer(signingKey: Data) -> RemotePeer? { peers().first { $0.signingKey == signingKey } }

    /// The relay's shared secret (coturn's static-auth-secret), if one's been given.
    public func relaySecret() -> String? { lock.withLock { (try? store.password(for: Self.relayAccount)).flatMap { $0 } } }

    public func setRelaySecret(_ secret: String?) throws {
        try lock.withLock {
            if let secret { try store.setPassword(secret, for: Self.relayAccount) } else { try store.removePassword(for: Self.relayAccount) }
        }
    }

    private func save(_ peers: [RemotePeer]) throws {
        try lock.withLock {
            try store.setPassword(String(decoding: try JSONEncoder().encode(peers), as: UTF8.self), for: Self.peersAccount)
        }
    }
}
