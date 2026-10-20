import Foundation
import Testing
@testable import Traversal

/// The published test vectors (FIPS 180, RFC 2202, RFC 4231, the CRC-32 check value).
@Suite struct HashesTests {
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func sha1() {
        #expect(Self.hex(Hashes.sha1(Self.bytes("abc"))) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(Self.hex(Hashes.sha1([])) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(Self.hex(Hashes.sha1(Self.bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))
            == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    }

    @Test func sha256() {
        #expect(Self.hex(Hashes.sha256(Self.bytes("abc"))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Self.hex(Hashes.sha256([])) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // A long one: a million "a"s.
        #expect(Self.hex(Hashes.sha256([UInt8](repeating: 0x61, count: 1_000_000)))
            == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func hmac() {
        // RFC 2202, test 2: HMAC-SHA1("Jefe", "what do ya want for nothing?").
        #expect(Self.hex(Hashes.hmac(Self.bytes("Jefe"), Self.bytes("what do ya want for nothing?")))
            == "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
        // RFC 4231, test 2, with SHA-256.
        #expect(Self.hex(Hashes.hmac(Self.bytes("Jefe"), Self.bytes("what do ya want for nothing?"), hash: Hashes.sha256))
            == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    @Test func crc32() {
        #expect(Hashes.crc32(Self.bytes("123456789")) == 0xCBF4_3926)
    }
}
