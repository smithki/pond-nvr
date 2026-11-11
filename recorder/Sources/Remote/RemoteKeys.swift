// What remote access keeps of its identities, in the Keychain (service `pond-remote`): this end's own (RemoteIdentity, in
// PondProtocol) and the peers paired with it.
import Foundation
import PondCore
import PondProtocol

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
               var stored = try? JSONDecoder().decode(RemoteIdentity.Stored.self, from: Data(text.utf8)) {
                // Renamed since: kept under its new name (devices pairing from now on are told it).
                if stored.name != name {
                    stored.name = name
                    try store.setPassword(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self), for: Self.identityAccount)
                }
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

    /// A paired device or Pond called something else here (what it calls itself is its own).
    public func rename(_ id: String, to name: String) throws {
        try save(peers().map { peer in
            guard peer.id == id else { return peer }
            var renamed = peer
            renamed.name = name
            return renamed
        })
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
