// Pairing a device with a Pond, once: the Pond shows a code (a QR code, or text to paste) with its keys, its mailbox,
// where its signaling service is, and a secret for this pairing only, good for ten minutes. The device sends the Pond
// its own keys, sealed to the Pond, with proof it has the secret (an HMAC of its keys under it); the Pond keeps the
// device and answers, signed, so the device knows it's the Pond the code named. A code is used once. After, each
// knows the other's keys: every later message between them is sealed and signed with them.
import CryptoKit
import Foundation

public struct PairingCode: Codable, Equatable, Sendable {
    public var pond: RemotePeer
    /// The signaling service both use (its WebSocket address).
    public var signaling: String
    public var secret: Data
    public var expires: Date

    static let prefix = "pond-pair:"

    /// As text: for a QR code, or to paste.
    public var text: String {
        Self.prefix + ((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init(pond: RemotePeer, signaling: String, secret: Data, expires: Date) {
        self.pond = pond
        self.signaling = signaling
        self.secret = secret
        self.expires = expires
    }

    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else { return nil }
        var b64 = String(trimmed.dropFirst(Self.prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let code = try? JSONDecoder().decode(PairingCode.self, from: data) else { return nil }
        self = code
    }
}

/// The messages pairing sends.
enum PairingMessage {
    static let request = "pair.request", accepted = "pair.accepted"

    struct Request: Codable {
        var peer: RemotePeer
        var proof: Data
    }

    struct Accepted: Codable {
        var pond: RemotePeer
    }

    /// Proof of the code's secret, over the keys it vouches for.
    static func proof(_ peer: RemotePeer, secret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: vouched(peer), using: SymmetricKey(data: secret)))
    }

    /// What a proof covers: the device's keys, mailbox and name.
    static func vouched(_ peer: RemotePeer) -> Data {
        peer.signingKey + peer.agreementKey + Data(peer.mailbox.utf8) + Data(peer.name.utf8)
    }
}

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

/// The device's side of pairing.
public enum PairingGuest {
    /// The request to send the Pond a code names: this device's keys, with proof of the code's secret.
    public static func request(_ code: PairingCode, from me: RemoteIdentity, now: Date = Date()) throws -> Envelope {
        let peer = me.peer
        let body = try JSONEncoder().encode(PairingMessage.Request(peer: peer, proof: PairingMessage.proof(peer, secret: code.secret)))
        return try Envelope.seal(kind: PairingMessage.request, body: body, from: me, to: code.pond, now: now)
    }

    /// The Pond's answer (opened from its envelope, with its sender): the Pond, if it's the one the code named.
    public static func accepted(kind: String, body: Data, sender: Data, code: PairingCode) -> RemotePeer? {
        guard kind == PairingMessage.accepted, sender == code.pond.signingKey,
              let accepted = try? JSONDecoder().decode(PairingMessage.Accepted.self, from: body),
              accepted.pond.signingKey == code.pond.signingKey else { return nil }
        return accepted.pond
    }
}
