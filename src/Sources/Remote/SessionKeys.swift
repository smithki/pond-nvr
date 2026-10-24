// The keys a session between two paired Ponds is encrypted with, new for every session. Each side makes a one-time
// X25519 key and sends its public half in the offer or answer, which travel sealed to the other and signed with the
// sender's long-term key: so each knows the other's one-time key is the other's, with nothing more to check. From
// the two, X25519 then HKDF-SHA256 (salted with the session's id, both public keys in its info) give, for each
// direction: a key for the control channel (ChaCha20-Poly1305) and an SRTP master key and salt for video (AES-128,
// as HomeKit's live video uses). The one-time keys are thrown away with the session: what was sent can't be read
// later, even by someone who has a Pond's long-term keys by then.
import CryptoKit
import Foundation

public struct SessionKeys: Sendable {
    /// What this side sends with, and what it reads the other's with.
    public var controlSend: SymmetricKey
    public var controlReceive: SymmetricKey
    public var videoSend: (key: [UInt8], salt: [UInt8])
    public var videoReceive: (key: [UInt8], salt: [UInt8])

    static let info = "pond session 1"
    /// A control key, then an SRTP master key and salt, for each direction.
    static let controlLength = 32, srtpKeyLength = 16, srtpSaltLength = 14

    public enum Failure: Error, Equatable { case badPublicKey }

    /// This side's keys, from its one-time key and the other's public one. The side being reached (controlling)
    /// and the one connecting each label the directions by role, so one's send keys are the other's receive keys.
    public static func derive(mine: Curve25519.KeyAgreement.PrivateKey, theirs: Data, session: UUID,
                              controlling: Bool) throws(Failure) -> SessionKeys {
        guard let other = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: other) else { throw .badPublicKey }
        // Both public keys in the info, the side being reached's first: a key swapped in is a different session.
        let (reached, connecting) = controlling ? (mine.publicKey.rawRepresentation, theirs) : (theirs, mine.publicKey.rawRepresentation)
        var salt = Data(count: 16)
        withUnsafeBytes(of: session.uuid) { raw in salt = Data(raw) }
        let each = controlLength + srtpKeyLength + srtpSaltLength
        let bytes = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(info.utf8) + reached + connecting,
                                                   outputByteCount: 2 * each)
            .withUnsafeBytes { [UInt8]($0) }
        /// One direction's keys, from where they start in the output.
        func direction(_ at: Int) -> (control: SymmetricKey, video: (key: [UInt8], salt: [UInt8])) {
            let control = SymmetricKey(data: bytes[at ..< at + controlLength])
            let key = Array(bytes[at + controlLength ..< at + controlLength + srtpKeyLength])
            let salt = Array(bytes[at + controlLength + srtpKeyLength ..< at + each])
            return (control, (key, salt))
        }
        // The first half goes from the side being reached to the one connecting; the second, back.
        let out = direction(0), back = direction(each)
        return controlling
            ? SessionKeys(controlSend: out.control, controlReceive: back.control, videoSend: out.video, videoReceive: back.video)
            : SessionKeys(controlSend: back.control, controlReceive: out.control, videoSend: back.video, videoReceive: out.video)
    }
}
