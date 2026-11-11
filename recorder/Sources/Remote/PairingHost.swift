// The Pond's side of pairing (the codes, the messages and the device's side are PondProtocol's, in Pairing.swift):
// codes made, requests checked, devices kept.
import CryptoKit
import Foundation
import PondProtocol

/// The Pond's side of pairing: codes made, requests checked, devices kept.
public final class PairingHost: @unchecked Sendable {
    let keys: RemoteKeys
    let identity: RemoteIdentity
    /// How long a code is good for.
    public static let lifetime: TimeInterval = 600
    private var outstanding: [Data: Date] = [:]
    private let lock = NSLock()

    public enum Failure: Error, Equatable {
        case noSuchCode
        case expired
        case badProof
    }

    public init(keys: RemoteKeys, identity: RemoteIdentity) {
        self.keys = keys
        self.identity = identity
    }

    /// A new code, good for ten minutes, once.
    public func newCode(signaling: String, now: Date = Date()) -> PairingCode {
        var secret = Data(count: 16)
        secret.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let expires = now.addingTimeInterval(Self.lifetime)
        lock.withLock {
            outstanding = outstanding.filter { $0.value > now }
            outstanding[secret] = expires
        }
        return PairingCode(pond: identity.peer, signaling: signaling, secret: secret, expires: expires)
    }

    /// A device's request (opened from its envelope): if it proves a code's secret, the device kept, the code used up,
    /// and the answer to send it.
    public func handle(_ body: Data, now: Date = Date()) throws -> (device: RemotePeer, answer: Envelope) {
        guard let request = try? JSONDecoder().decode(PairingMessage.Request.self, from: body) else { throw Failure.badProof }
        let matched: (Data, Date)? = lock.withLock {
            outstanding.first { secret, _ in
                HMAC<SHA256>.isValidAuthenticationCode(request.proof, authenticating: PairingMessage.vouched(request.peer),
                                                       using: SymmetricKey(data: secret))
            }.map { ($0.key, $0.value) }
        }
        guard let (secret, expires) = matched else { throw Failure.noSuchCode }
        _ = lock.withLock { outstanding.removeValue(forKey: secret) }
        guard expires > now else { throw Failure.expired }
        try keys.add(request.peer)
        let answer = try Envelope.seal(kind: PairingMessage.accepted, body: try JSONEncoder().encode(PairingMessage.Accepted(pond: identity.peer)),
                                       from: identity, to: request.peer, now: now)
        return (request.peer, answer)
    }
}
