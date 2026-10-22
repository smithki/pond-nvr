// The hashes STUN and WebSocket need, in plain Swift, so what uses them builds on Linux with nothing added (Apple's
// CryptoKit is macOS's and iOS's only): SHA-1 (WebSocket's handshake, STUN's MESSAGE-INTEGRITY with HMAC), SHA-256
// (mailbox secrets), HMAC over either, CRC-32 (STUN's FINGERPRINT), and MD5 (TURN's long-term credentials).
import Foundation

public enum Hashes {
    // MARK: SHA-1

    public static func sha1(_ data: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in padded(data, bigEndianLength: true).chunks(64) {
            for i in 0 ..< 16 { w[i] = chunk.readBE32(i * 4) }
            for i in 16 ..< 80 { w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotl(1) }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0 ..< 80 {
                let (f, k): (UInt32, UInt32) = switch i {
                case 0 ..< 20: ((b & c) | (~b & d), 0x5A82_7999)
                case 20 ..< 40: (b ^ c ^ d, 0x6ED9_EBA1)
                case 40 ..< 60: ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default: (b ^ c ^ d, 0xCA62_C1D6)
                }
                let t = a.rotl(5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, b.rotl(30), a, t)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap(\.bigEndianBytes)
    }

    // MARK: SHA-256

    static let k256: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    /// MD5 (RFC 1321): only for TURN's long-term credentials, whose key is MD5(username:realm:password) by its
    /// RFC. Never for anything that needs it to be strong.
    public static func md5(_ data: [UInt8]) -> [UInt8] {
        let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        let k: [UInt32] = (0 ..< 64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296)) }
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476]
        var message = data + [0x80]
        while message.count % 64 != 56 { message.append(0) }
        let bits = UInt64(data.count) * 8
        message += (0 ..< 8).map { UInt8((bits >> (8 * UInt64($0))) & 0xFF) }   // little-endian, unlike SHA's
        for chunk in stride(from: 0, to: message.count, by: 64) {
            let m = (0 ..< 16).map { i in
                (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(message[chunk + i * 4 + $1]) << (8 * UInt32($1)) }
            }
            var (a, b, c, d) = (h[0], h[1], h[2], h[3])
            for i in 0 ..< 64 {
                var f: UInt32, g: Int
                switch i {
                case 0 ..< 16: f = (b & c) | (~b & d); g = i
                case 16 ..< 32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32 ..< 48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ (f << s[i] | f >> (32 - s[i]))
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
        }
        return h.flatMap { v in (0 ..< 4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    }

    public static func sha256(_ data: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19]
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in padded(data, bigEndianLength: true).chunks(64) {
            for i in 0 ..< 16 { w[i] = chunk.readBE32(i * 4) }
            for i in 16 ..< 64 {
                let s0 = w[i - 15].rotr(7) ^ w[i - 15].rotr(18) ^ (w[i - 15] >> 3)
                let s1 = w[i - 2].rotr(17) ^ w[i - 2].rotr(19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0 ..< 64 {
                let t1 = hh &+ (e.rotr(6) ^ e.rotr(11) ^ e.rotr(25)) &+ ((e & f) ^ (~e & g)) &+ k256[i] &+ w[i]
                let t2 = (a.rotr(2) ^ a.rotr(13) ^ a.rotr(22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.flatMap(\.bigEndianBytes)
    }

    // MARK: HMAC

    public static func hmac(_ key: [UInt8], _ message: [UInt8], hash: ([UInt8]) -> [UInt8] = sha1) -> [UInt8] {
        var key = key
        if key.count > 64 { key = hash(key) }
        key += [UInt8](repeating: 0, count: 64 - key.count)
        let inner = hash(key.map { $0 ^ 0x36 } + message)
        return hash(key.map { $0 ^ 0x5C } + inner)
    }

    // MARK: CRC-32 (IEEE)

    static let crcTable: [UInt32] = (0 ..< 256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// The message, a 1 bit, zeros, and its length in bits (64-bit, big-endian): to a multiple of 64 bytes.
    static func padded(_ data: [UInt8], bigEndianLength: Bool) -> [UInt8] {
        var out = data + [0x80]
        while out.count % 64 != 56 { out.append(0) }
        let bits = UInt64(data.count) * 8
        out += (0 ..< 8).map { UInt8(truncatingIfNeeded: bits >> (56 - 8 * $0)) }
        return out
    }
}

extension UInt32 {
    func rotl(_ n: UInt32) -> UInt32 { (self << n) | (self >> (32 - n)) }
    func rotr(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) }
    var bigEndianBytes: [UInt8] { [UInt8(self >> 24), UInt8(truncatingIfNeeded: self >> 16), UInt8(truncatingIfNeeded: self >> 8), UInt8(truncatingIfNeeded: self)] }
}

extension Array where Element == UInt8 {
    func chunks(_ size: Int) -> [ArraySlice<UInt8>] { stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] } }
}

extension ArraySlice where Element == UInt8 {
    func readBE32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
