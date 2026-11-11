// SPDX-License-Identifier: MIT
import CryptoKit
import Foundation
import Testing
@testable import PondProtocol

@Suite struct SessionKeysTests {
    func bytes(_ key: SymmetricKey) -> [UInt8] { key.withUnsafeBytes { [UInt8]($0) } }

    @Test func eachSidesSendKeysAreTheOthersReceiveKeys() throws {
        let home = Curve25519.KeyAgreement.PrivateKey(), away = Curve25519.KeyAgreement.PrivateKey()
        let session = UUID()
        let atHome = try SessionKeys.derive(mine: home, theirs: away.publicKey.rawRepresentation, session: session, controlling: true)
        let atAway = try SessionKeys.derive(mine: away, theirs: home.publicKey.rawRepresentation, session: session, controlling: false)
        #expect(bytes(atHome.controlSend) == bytes(atAway.controlReceive))
        #expect(bytes(atAway.controlSend) == bytes(atHome.controlReceive))
        #expect(atHome.videoSend.key == atAway.videoReceive.key && atHome.videoSend.salt == atAway.videoReceive.salt)
        #expect(atAway.videoSend.key == atHome.videoReceive.key && atAway.videoSend.salt == atHome.videoReceive.salt)
        // The two directions differ; the SRTP keys are AES-128's, their salts 14 bytes.
        #expect(bytes(atHome.controlSend) != bytes(atHome.controlReceive))
        #expect(atHome.videoSend.key.count == 16 && atHome.videoSend.salt.count == 14)
        #expect(bytes(atHome.controlSend).count == 32)
    }

    @Test func anotherSessionOrKeyIsAnotherSecret() throws {
        let home = Curve25519.KeyAgreement.PrivateKey(), away = Curve25519.KeyAgreement.PrivateKey()
        let one = try SessionKeys.derive(mine: home, theirs: away.publicKey.rawRepresentation, session: UUID(), controlling: true)
        let two = try SessionKeys.derive(mine: home, theirs: away.publicKey.rawRepresentation, session: UUID(), controlling: true)
        #expect(bytes(one.controlSend) != bytes(two.controlSend))
        let stranger = Curve25519.KeyAgreement.PrivateKey()
        let other = try SessionKeys.derive(mine: home, theirs: stranger.publicKey.rawRepresentation, session: UUID(), controlling: true)
        #expect(bytes(one.controlSend) != bytes(other.controlSend))
        #expect(throws: SessionKeys.Failure.badPublicKey) {
            try SessionKeys.derive(mine: home, theirs: Data([1, 2, 3]), session: UUID(), controlling: true)
        }
    }
}
