// SPDX-License-Identifier: MIT
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
public enum PairingMessage {
    public static let request = "pair.request", accepted = "pair.accepted"

    public struct Request: Codable, Sendable {
        public var peer: RemotePeer
        public var proof: Data

        public init(peer: RemotePeer, proof: Data) {
            self.peer = peer
            self.proof = proof
        }
    }

    public struct Accepted: Codable, Sendable {
        public var pond: RemotePeer

        public init(pond: RemotePeer) { self.pond = pond }
    }

    /// Proof of the code's secret, over the keys it vouches for.
    public static func proof(_ peer: RemotePeer, secret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: vouched(peer), using: SymmetricKey(data: secret)))
    }

    /// What a proof covers: the device's keys, mailbox and name.
    public static func vouched(_ peer: RemotePeer) -> Data {
        peer.signingKey + peer.agreementKey + Data(peer.mailbox.utf8) + Data(peer.name.utf8)
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
