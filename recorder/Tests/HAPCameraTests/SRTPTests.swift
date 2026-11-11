import Foundation
import Testing
@testable import HAPCamera

func bytes(_ hex: String) -> [UInt8] {
    let h = Array(hex.filter { !$0.isWhitespace })
    return stride(from: 0, to: h.count, by: 2).map { UInt8(String(h[$0 ... $0 + 1]), radix: 16)! }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

@Suite struct SRTPTests {
    static let masterKey = bytes("E1F97A0D3E018BE0D64FA32C06DE4139")
    static let masterSalt = bytes("0EC675AD498AFEEBB6960B3AABE6")

    // RFC 3711, appendix B.2.
    @Test func aesCounterModeKeystream() {
        let stream = AESCM.keystream(key: bytes("2B7E151628AED2A6ABF7158809CF4F3C"),
                                     iv: bytes("F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000"), count: 48)
        #expect(hex(stream) == ("E03EAD0935C95E80E166B16DD92B4EB4" + "D23513162B02D0F72A43A2FE4A5F97AB"
            + "41E95B3BB0A2E8DD477901E4FCA894C0").lowercased())
    }

    // RFC 3711, appendix B.3.
    @Test func keyDerivation() {
        let keys = SRTPKeys(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        #expect(hex(keys.cipherKey) == "c61e7a93744f39ee10734afe3ff7a087")
        #expect(hex(keys.salt) == "30cbbc08863d8c85d49db34a9ae1")
        #expect(hex(keys.authKey) == "cebe321f6ff7716b6fd4ab49af256a156d38baa4")
    }

    // Reference packets made with OpenSSL's AES-128-CTR and Python's HMAC.
    @Test func packetsMatchAnIndependentImplementation() {
        var sender = SRTPSender(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        let rtp = [0x80, 99, 0x12, 0x34, 0, 0, 0x30, 0x39, 0xDE, 0xAD, 0xBE, 0xEF] + Array(0 ..< 50 as Range<UInt8>)
        #expect(hex(sender.protect(rtp: rtp)) == "8063123400003039deadbeef1e162ded720b403a2a241e308709ea43d8088bc5b40243e74a9d90dba574c4f85fed0a2c96c6c1303916785d718f974462bf0864a2bc62025007f514")
        let rtcp = [0x80, 200, 0, 6, 0xDE, 0xAD, 0xBE, 0xEF] + Array(0 ..< 20 as Range<UInt8>)
        #expect(hex(sender.protect(rtcp: rtcp)) == "80c80006deadbeef63c82f10406ba04a88b9fbfd8780ca36dae9f4ae8000000062263a9e9651de28bc46")
    }
}
