import Foundation

// Unsigned big integers, just enough for SRP: bytes in and out, add, subtract, multiply, remainder and
// modular exponentiation. Limbs are 64-bit, least significant first; schoolbook multiplication and Knuth's
// long division (TAOCP vol. 2, 4.3.1, algorithm D). A 3072-bit exponentiation takes a few milliseconds.

public struct BigUInt: Equatable, Sendable, CustomStringConvertible {
    /// Least significant first, no zero limbs at the top (zero is []).
    private(set) var limbs: [UInt64]

    init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    public init(_ value: UInt64) {
        self.init(limbs: [value])
    }

    /// From big-endian bytes.
    public init(bytes: [UInt8]) {
        var limbs = [UInt64](repeating: 0, count: (bytes.count + 7) / 8)
        for (i, byte) in bytes.reversed().enumerated() {
            limbs[i / 8] |= UInt64(byte) << (UInt64(i % 8) * 8)
        }
        self.init(limbs: limbs)
    }

    /// From hexadecimal, ignoring spaces and line breaks.
    public init?(hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        var bytes: [UInt8] = []
        var chars = Array(digits)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i ... i + 1]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        self.init(bytes: bytes)
    }

    public var isZero: Bool { limbs.isEmpty }

    /// Big-endian bytes: the fewest that hold the value, or exactly `length` (left-padded with zeros).
    public func bytes(length: Int? = nil) -> [UInt8] {
        var out: [UInt8] = []
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift))) }
        }
        while let first = out.first, first == 0 { out.removeFirst() }
        if let length, out.count < length { out = [UInt8](repeating: 0, count: length - out.count) + out }
        return out
    }

    public var description: String {
        bytes().map { String(format: "%02X", $0) }.joined()
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    // MARK: - Arithmetic

    public static func < (a: BigUInt, b: BigUInt) -> Bool { compare(a.limbs, b.limbs) < 0 }

    static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i] ? -1 : 1
        }
        return 0
    }

    public static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var out = [UInt64](repeating: 0, count: max(a.limbs.count, b.limbs.count) + 1)
        var carry: UInt64 = 0
        for i in 0 ..< out.count - 1 {
            let x = i < a.limbs.count ? a.limbs[i] : 0
            let y = i < b.limbs.count ? b.limbs[i] : 0
            let (s1, o1) = x.addingReportingOverflow(y)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        out[out.count - 1] = carry
        return BigUInt(limbs: out)
    }

    /// a − b, for a ≥ b.
    public static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(!(a < b), "BigUInt subtraction would be negative")
        var out = a.limbs
        var borrow: UInt64 = 0
        for i in 0 ..< out.count {
            let y = i < b.limbs.count ? b.limbs[i] : 0
            let (d1, o1) = out[i].subtractingReportingOverflow(y)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return BigUInt(limbs: out)
    }

    public static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        guard !a.isZero, !b.isZero else { return BigUInt(limbs: []) }
        var out = [UInt64](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0 ..< a.limbs.count {
            var carry: UInt64 = 0
            let x = a.limbs[i]
            for j in 0 ..< b.limbs.count {
                let (hi, lo) = x.multipliedFullWidth(by: b.limbs[j])
                let (s1, o1) = lo.addingReportingOverflow(out[i + j])
                let (s2, o2) = s1.addingReportingOverflow(carry)
                out[i + j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            out[i + b.limbs.count] = carry
        }
        return BigUInt(limbs: out)
    }

    /// a mod m (m ≠ 0).
    public static func % (a: BigUInt, m: BigUInt) -> BigUInt {
        precondition(!m.isZero, "BigUInt modulo zero")
        if a < m { return a }
        if m.limbs.count == 1 {
            var rem: UInt64 = 0
            for limb in a.limbs.reversed() {
                rem = m.limbs[0].dividingFullWidth((rem, limb)).remainder
            }
            return BigUInt(rem)
        }
        return BigUInt(limbs: remainder(a.limbs, m.limbs))
    }

    /// Knuth's algorithm D, remainder only. v has at least two limbs and u ≥ v.
    static func remainder(_ uIn: [UInt64], _ vIn: [UInt64]) -> [UInt64] {
        let n = vIn.count, m = uIn.count - n
        let shift = UInt64(vIn[n - 1].leadingZeroBitCount)
        // Normalize: shift so the divisor's top bit is set.
        var v = vIn, u = uIn + [0]
        if shift > 0 {
            for i in stride(from: n - 1, through: 1, by: -1) { v[i] = v[i] << shift | v[i - 1] >> (64 - shift) }
            v[0] <<= shift
            for i in stride(from: u.count - 1, through: 1, by: -1) { u[i] = u[i] << shift | u[i - 1] >> (64 - shift) }
            u[0] <<= shift
        }
        let top = v[n - 1], next = v[n - 2]
        for j in stride(from: m, through: 0, by: -1) {
            // Estimate the quotient digit from the top two limbs.
            var qhat: UInt64, rhat: UInt64
            var rhatOverflow = false
            if u[j + n] >= top {
                qhat = .max
                let (r, o) = u[j + n - 1].addingReportingOverflow(top)
                rhat = r
                rhatOverflow = o
            } else {
                (qhat, rhat) = top.dividingFullWidth((u[j + n], u[j + n - 1]))
            }
            while !rhatOverflow {
                let (phi, plo) = qhat.multipliedFullWidth(by: next)
                if phi > rhat || (phi == rhat && plo > u[j + n - 2]) {
                    qhat -= 1
                    let (r, o) = rhat.addingReportingOverflow(top)
                    rhat = r
                    rhatOverflow = o
                } else {
                    break
                }
            }
            // u[j...j+n] -= qhat × v
            var borrow: UInt64 = 0, carry: UInt64 = 0
            for i in 0 ..< n {
                let (phi, plo) = qhat.multipliedFullWidth(by: v[i])
                let (p, o1) = plo.addingReportingOverflow(carry)
                carry = phi &+ (o1 ? 1 : 0)
                let (d1, b1) = u[i + j].subtractingReportingOverflow(p)
                let (d2, b2) = d1.subtractingReportingOverflow(borrow)
                u[i + j] = d2
                borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
            }
            let (d1, b1) = u[j + n].subtractingReportingOverflow(carry)
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            u[j + n] = d2
            if b1 || b2 {
                // qhat was one too large: add v back.
                var c: UInt64 = 0
                for i in 0 ..< n {
                    let (s1, o1) = u[i + j].addingReportingOverflow(v[i])
                    let (s2, o2) = s1.addingReportingOverflow(c)
                    u[i + j] = s2
                    c = (o1 ? 1 : 0) + (o2 ? 1 : 0)
                }
                u[j + n] = u[j + n] &+ c
            }
        }
        // Unnormalize the remainder.
        var r = Array(u[0 ..< n])
        if shift > 0 {
            for i in 0 ..< n - 1 { r[i] = r[i] >> shift | r[i + 1] << (64 - shift) }
            r[n - 1] >>= shift
        }
        return r
    }

    /// self^exponent mod m, left to right by bits.
    public func power(_ exponent: BigUInt, modulus m: BigUInt) -> BigUInt {
        var result = BigUInt(1) % m
        let base = self % m
        for limb in exponent.limbs.reversed() {
            for bit in stride(from: 63, through: 0, by: -1) {
                result = (result * result) % m
                if (limb >> UInt64(bit)) & 1 == 1 { result = (result * base) % m }
            }
        }
        return result
    }
}
