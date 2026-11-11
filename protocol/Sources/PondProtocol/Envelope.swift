// SPDX-License-Identifier: MIT
// What passes through the signaling service: envelopes, each sealed to its recipient's key (HPKE: X25519, SHA-256,
// ChaCha20-Poly1305) and signed inside by its sender (Ed25519). The service sees whose mailbox it's for, and opaque
// bytes: not who sent it, nor what it says (offers, answers, addresses). The recipient checks it was sealed for its
// mailbox, signed by the key it says, sent within a few minutes, and not seen before (a copy replayed is refused).
import CryptoKit
import Foundation

public struct Envelope: Codable, Equatable, Sendable {
    /// The recipient's mailbox.
    public var to: String
    /// HPKE's encapsulated key, then the sealed message.
    public var sealed: Data

    public init(to: String, sealed: Data) {
        self.to = to
        self.sealed = sealed
    }

    static let info = Data("pond envelope 1".utf8)
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    /// How far a message's time may be from now.
    public static let window: TimeInterval = 300

    /// What's inside: the kind of message, its body, who signed it, when, and a nonce.
    struct Inner: Codable {
        var kind: String
        var body: Data
        var from: Data
        var to: String
        var time: Double
        var nonce: Data
    }

    struct Signed: Codable {
        var inner: Data
        var signature: Data
    }

    public enum Failure: Error, Equatable {
        case unreadable
        case notForMe
        case badSignature
        case stale
        case replayed
        case unknownSender
    }

    /// A message sealed to `recipient`, signed by `sender`.
    public static func seal(kind: String, body: Data, from sender: RemoteIdentity, to recipient: RemotePeer, now: Date = Date()) throws -> Envelope {
        var nonce = Data(count: 16)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let inner = try JSONEncoder().encode(Inner(kind: kind, body: body, from: sender.signing.publicKey.rawRepresentation,
                                                   to: recipient.mailbox, time: now.timeIntervalSince1970, nonce: nonce))
        let signed = try JSONEncoder().encode(Signed(inner: inner, signature: try sender.signing.signature(for: inner)))
        var hpke = try HPKE.Sender(recipientKey: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.agreementKey),
                                   ciphersuite: suite, info: info)
        let sealed = try hpke.seal(signed)
        return Envelope(to: recipient.mailbox, sealed: hpke.encapsulatedKey + sealed)
    }

    /// Opened by the identity it's for: its kind, its body, and its sender's signing key (one of `known`, unless
    /// `kinds` from strangers are allowed: a request to pair).
    public func open(as identity: RemoteIdentity, replay: ReplayGuard, strangers kinds: Set<String> = [], known: [RemotePeer],
                     now: Date = Date()) throws(Failure) -> (kind: String, body: Data, sender: Data) {
        guard to == identity.peer.mailbox else { throw .notForMe }
        guard sealed.count > 32 else { throw .unreadable }
        let encapsulated = sealed.prefix(32), ciphertext = sealed.dropFirst(32)
        guard var hpke = try? HPKE.Recipient(privateKey: identity.agreement, ciphersuite: Self.suite, info: Self.info,
                                             encapsulatedKey: Data(encapsulated)),
              let plain = try? hpke.open(Data(ciphertext)),
              let signed = try? JSONDecoder().decode(Signed.self, from: plain),
              let inner = try? JSONDecoder().decode(Inner.self, from: signed.inner) else { throw .unreadable }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: inner.from),
              key.isValidSignature(signed.signature, for: signed.inner) else { throw .badSignature }
        // Signed for this mailbox (not re-sealed to another from one opened elsewhere).
        guard inner.to == to else { throw .notForMe }
        guard abs(now.timeIntervalSince1970 - inner.time) <= Self.window else { throw .stale }
        guard known.contains(where: { $0.signingKey == inner.from }) || kinds.contains(inner.kind) else { throw .unknownSender }
        guard replay.first(inner.nonce, at: now) else { throw .replayed }
        return (inner.kind, inner.body, inner.from)
    }
}

/// Nonces seen lately (within the envelopes' window): a message seen once isn't taken twice.
public final class ReplayGuard: @unchecked Sendable {
    private var seen: [Data: Date] = [:]
    private let lock = NSLock()

    public init() {}

    /// True the first time a nonce is seen.
    func first(_ nonce: Data, at now: Date) -> Bool {
        lock.withLock {
            seen = seen.filter { now.timeIntervalSince($0.value) <= 2 * Envelope.window }
            guard seen[nonce] == nil else { return false }
            seen[nonce] = now
            return true
        }
    }
}
