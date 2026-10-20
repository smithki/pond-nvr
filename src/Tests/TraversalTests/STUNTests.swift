import Foundation
import Testing
@testable import Traversal

@Suite struct STUNTests {
    /// RFC 5769 §2.1: a sample request, with its MESSAGE-INTEGRITY (password "VOkJxbRl1RmTxUk/WvJxBt") and FINGERPRINT.
    static let sampleRequest: [UInt8] = [
        0x00, 0x01, 0x00, 0x58, 0x21, 0x12, 0xA4, 0x42, 0xB7, 0xE7, 0xA7, 0x01, 0xBC, 0x34, 0xD6, 0x86, 0xFA, 0x87, 0xDF, 0xAE,
        0x80, 0x22, 0x00, 0x10, 0x53, 0x54, 0x55, 0x4E, 0x20, 0x74, 0x65, 0x73, 0x74, 0x20, 0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74,
        0x00, 0x24, 0x00, 0x04, 0x6E, 0x00, 0x01, 0xFF, 0x80, 0x29, 0x00, 0x08, 0x93, 0x2F, 0xF9, 0xB1, 0x51, 0x26, 0x3B, 0x36,
        0x00, 0x06, 0x00, 0x09, 0x65, 0x76, 0x74, 0x6A, 0x3A, 0x68, 0x36, 0x76, 0x59, 0x20, 0x20, 0x20, 0x00, 0x08, 0x00, 0x14,
        0x9A, 0xEA, 0xA7, 0x0C, 0xBF, 0xD8, 0xCB, 0x56, 0x78, 0x1E, 0xF2, 0xB5, 0xB2, 0xD3, 0xF2, 0x49, 0xC1, 0xB5, 0x71, 0xA2,
        0x80, 0x28, 0x00, 0x04, 0xE5, 0x7A, 0x3B, 0xCF,
    ]

    @Test func theRFCsSampleIsReadAndItsIntegrityChecked() throws {
        let key = Array("VOkJxbRl1RmTxUk/WvJxBt".utf8)
        let message = try STUNMessage(Self.sampleRequest, integrity: key)
        #expect(message.type == STUNMessage.bindingRequest)
        #expect(message.attribute(STUNMessage.Attribute.username).map { String(decoding: $0, as: UTF8.self) } == "evtj:h6vY")
        #expect(message.attribute(STUNMessage.Attribute.priority) == [0x6E, 0x00, 0x01, 0xFF])
        #expect(throws: STUNMessage.Failure.badIntegrity) { try STUNMessage(Self.sampleRequest, integrity: Array("wrong".utf8)) }
        var corrupt = Self.sampleRequest
        corrupt[30] ^= 1
        #expect(throws: STUNMessage.Failure.badFingerprint) { try STUNMessage(corrupt) }
    }

    @Test func aMessageWrittenIsReadBack() throws {
        let key = Array("secret".utf8)
        let sent = STUNMessage(type: STUNMessage.bindingRequest, attributes: [
            .init(STUNMessage.Attribute.username, Array("a:b".utf8)),
            .init(STUNMessage.Attribute.priority, [1, 2, 3, 4]),
            .init(STUNMessage.Attribute.useCandidate, []),
        ])
        let bytes = sent.encoded(integrity: key)
        #expect(STUNMessage.looksLikeSTUN(bytes))
        #expect(try STUNMessage(bytes, integrity: key) == sent)
        // Without integrity asked for, it reads the same; with a key and no integrity in it, it's refused.
        #expect(try STUNMessage(bytes) == sent)
        #expect(throws: STUNMessage.Failure.badIntegrity) { try STUNMessage(sent.encoded(), integrity: key) }
    }

    @Test func addressesAreXORedBothWays() throws {
        let tx = STUNMessage.newTransaction()
        for address in [STUNAddress(ip: [192, 0, 2, 1], port: 32853),
                        STUNAddress(ip: [0x20, 0x01, 0x0D, 0xB8, 0x12, 0x34, 0x56, 0x78, 0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77], port: 443)] {
            #expect(STUNAddress(xorEncoded: address.xorEncoded(transaction: tx), transaction: tx) == address)
        }
        #expect(STUNAddress(ip: [192, 0, 2, 1], port: 32853).description == "192.0.2.1:32853")
    }

    @Test func mediaIsntTakenForSTUN() {
        // An RTP packet (version 2: its first two bits 10).
        #expect(!STUNMessage.looksLikeSTUN([0x80, 0x60] + [UInt8](repeating: 0, count: 30)))
    }
}
