// MD5, only for RTSP Digest authentication (RFC 2617), which requires it. Written out here so the module
// needs nothing beyond Foundation and builds on Linux too. Not for anything security-sensitive.
import Foundation

enum MD5 {
    private static let shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    // floor(|sin(i + 1)| * 2^32), as RFC 1321 defines them.
    private static let k: [UInt32] = (0 ..< 64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296)) }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var data = message
        let bitLength = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in 0 ..< 8 { data.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }

        var a0: UInt32 = 0x6745_2301, b0: UInt32 = 0xEFCD_AB89, c0: UInt32 = 0x98BA_DCFE, d0: UInt32 = 0x1032_5476
        for chunk in stride(from: 0, to: data.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0 ..< 16 {
                let j = chunk + 4 * i
                m[i] = UInt32(data[j]) | UInt32(data[j + 1]) << 8 | UInt32(data[j + 2]) << 16 | UInt32(data[j + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0 ..< 64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0 ..< 16: f = (b & c) | (~b & d); g = i
                case 16 ..< 32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32 ..< 48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d; d = c; c = b
                b = b &+ (f << shifts[i] | f >> (32 - shifts[i]))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        var out: [UInt8] = []
        for word in [a0, b0, c0, d0] {
            for i in 0 ..< 4 { out.append(UInt8(truncatingIfNeeded: word >> (8 * UInt32(i)))) }
        }
        return out
    }

    static func hex(_ string: String) -> String {
        digest(Array(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
