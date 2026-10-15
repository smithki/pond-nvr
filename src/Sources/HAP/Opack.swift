// Apple's compact binary encoding ("opack"), which the HomeKit Data Stream's messages are in: a tag byte
// (with small numbers, lengths and counts folded into it), then the value's bytes, little-endian. Encoded
// as HAP-NodeJS's DataStreamWriter does (its DataStreamParser is the reference), except that nothing is
// compressed: a decoder takes a value written out in full anywhere. Decoding takes compressed values too:
// a tag 0xA0 + n stands for the nth distinct value written in full before it among strings, data, sized
// numbers, floats, UUIDs and dates (not booleans, null or the numbers folded into a tag).
import Foundation

public indirect enum Opack: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case string(String)
    case data([UInt8])
    /// 16 bytes, big-endian.
    case uuid([UInt8])
    /// Seconds since 2001-01-01.
    case date(Double)
    case array([Opack])
    /// In order (the order is kept on the wire).
    case dictionary([(String, Opack)])

    public static func == (a: Opack, b: Opack) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case let (.bool(x), .bool(y)): x == y
        case let (.int(x), .int(y)): x == y
        case let (.float(x), .float(y)): x == y
        case let (.string(x), .string(y)): x == y
        case let (.data(x), .data(y)), let (.uuid(x), .uuid(y)): x == y
        case let (.date(x), .date(y)): x == y
        case let (.array(x), .array(y)): x == y
        case let (.dictionary(x), .dictionary(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    // MARK: - Reading

    /// The value for `key` in a dictionary.
    public subscript(key: String) -> Opack? {
        guard case let .dictionary(entries) = self else { return nil }
        return entries.first { $0.0 == key }?.1
    }

    public var string: String? { if case let .string(s) = self { s } else { nil } }
    public var int: Int64? { if case let .int(i) = self { i } else { nil } }
    public var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
    public var data: [UInt8]? { if case let .data(d) = self { d } else { nil } }
    public var array: [Opack]? { if case let .array(a) = self { a } else { nil } }

    // MARK: - Encoding

    public var encoded: [UInt8] {
        var out: [UInt8] = []
        encode(into: &out)
        return out
    }

    func encode(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(0x04)
        case let .bool(b): out.append(b ? 0x01 : 0x02)
        case let .int(n):
            switch n {
            case -1: out.append(0x07)
            case 0 ... 39: out.append(0x08 + UInt8(n))
            case -128 ... 127: out += [0x30] + Self.le(UInt64(bitPattern: n), 1)
            case -32768 ... 32767: out += [0x31] + Self.le(UInt64(bitPattern: n), 2)
            case -2_147_483_648 ... 2_147_483_647: out += [0x32] + Self.le(UInt64(bitPattern: n), 4)
            default: out += [0x33] + Self.le(UInt64(bitPattern: n), 8)
            }
        case let .float(f): out += [0x36] + Self.le(f.bitPattern, 8)
        case let .string(s): Self.sized(Array(s.utf8), base: 0x40, tags: (0x61, 0x62, 0x63), into: &out)
        case let .data(d): Self.sized(d, base: 0x70, tags: (0x91, 0x92, 0x93), into: &out)
        case let .uuid(u): out += [0x05] + u
        case let .date(d): out += [0x06] + Self.le(d.bitPattern, 8)
        case let .array(items):
            out.append(items.count <= 12 ? 0xD0 + UInt8(items.count) : 0xDF)
            for item in items { item.encode(into: &out) }
            if items.count > 12 { out.append(0x03) }
        case let .dictionary(entries):
            out.append(entries.count <= 14 ? 0xE0 + UInt8(entries.count) : 0xEF)
            for (key, value) in entries {
                Opack.string(key).encode(into: &out)
                value.encode(into: &out)
            }
            if entries.count > 14 { out.append(0x03) }
        }
    }

    static func le(_ v: UInt64, _ bytes: Int) -> [UInt8] { (0 ..< bytes).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

    /// Up to 32 bytes in the tag (base + length); else a tag and a 1, 2 or 4-byte length.
    static func sized(_ bytes: [UInt8], base: UInt8, tags: (UInt8, UInt8, UInt8), into out: inout [UInt8]) {
        switch bytes.count {
        case 0 ... 32: out.append(base + UInt8(bytes.count))
        case 33 ... 255: out += [tags.0, UInt8(bytes.count)]
        case 256 ... 65535: out += [tags.1] + le(UInt64(bytes.count), 2)
        default: out += [tags.2] + le(UInt64(bytes.count), 4)
        }
        out += bytes
    }

    // MARK: - Decoding

    public struct DecodeError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The value at the start of `bytes` (a whole message: anything after it is an error).
    public static func decode(_ bytes: [UInt8]) throws(DecodeError) -> Opack {
        var reader = Reader(bytes: bytes)
        let value = try reader.value()
        guard reader.at == bytes.count else { throw DecodeError(description: "\(bytes.count - reader.at) bytes after the value") }
        return value
    }

    struct Reader {
        let bytes: [UInt8]
        var at = 0
        /// Values written in full so far, for the compressed tags that refer back to them.
        var written: [Opack] = []

        mutating func take(_ n: Int) throws(DecodeError) -> ArraySlice<UInt8> {
            guard n >= 0, at + n <= bytes.count else { throw DecodeError(description: "the message ends early") }
            defer { at += n }
            return bytes[at ..< at + n]
        }

        mutating func unsigned(_ n: Int) throws(DecodeError) -> UInt64 {
            try take(n).reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        mutating func signed(_ n: Int) throws(DecodeError) -> Int64 {
            let raw = try unsigned(n)
            let shift = UInt64(64 - 8 * n)
            return Int64(bitPattern: raw << shift) >> Int64(shift)
        }

        mutating func remember(_ value: Opack) -> Opack {
            if !written.contains(value) { written.append(value) }
            return value
        }

        /// The terminator (0x03) as nil, for terminated arrays and dictionaries.
        mutating func valueOrEnd() throws(DecodeError) -> Opack? {
            guard at < bytes.count else { throw DecodeError(description: "the message ends early") }
            if bytes[at] == 0x03 {
                at += 1
                return nil
            }
            return try value()
        }

        mutating func value() throws(DecodeError) -> Opack {
            let tag = try take(1).first!
            switch tag {
            case 0x01: return .bool(true)
            case 0x02: return .bool(false)
            case 0x04: return .null
            case 0x05: return remember(.uuid(Array(try take(16))))
            case 0x06: return remember(.date(Double(bitPattern: try unsigned(8))))
            case 0x07: return .int(-1)
            case 0x08 ... 0x2F: return .int(Int64(tag) - 8)
            case 0x30: return remember(.int(try signed(1)))
            case 0x31: return remember(.int(try signed(2)))
            case 0x32: return remember(.int(try signed(4)))
            case 0x33: return remember(.int(try signed(8)))
            case 0x35: return remember(.float(Double(Float(bitPattern: UInt32(try unsigned(4))))))
            case 0x36: return remember(.float(Double(bitPattern: try unsigned(8))))
            case 0x40 ... 0x60: return remember(.string(try text(Int(tag - 0x40))))
            case 0x61: return remember(.string(try text(Int(try unsigned(1)))))
            case 0x62: return remember(.string(try text(Int(try unsigned(2)))))
            case 0x63: return remember(.string(try text(Int(try unsigned(4)))))
            case 0x64: return remember(.string(try text(Int(try unsigned(8)))))
            case 0x6F:
                guard let end = bytes[at...].firstIndex(of: 0) else { throw DecodeError(description: "an unterminated string") }
                let s = String(decoding: bytes[at ..< end], as: UTF8.self)
                at = end + 1
                return remember(.string(s))
            case 0x70 ... 0x90: return remember(.data(Array(try take(Int(tag - 0x70)))))
            case 0x91: return remember(.data(Array(try take(Int(try unsigned(1))))))
            case 0x92: return remember(.data(Array(try take(Int(try unsigned(2))))))
            case 0x93: return remember(.data(Array(try take(Int(try unsigned(4))))))
            case 0x94: return remember(.data(Array(try take(Int(try unsigned(8))))))
            case 0xA0 ... 0xCF:
                let index = Int(tag - 0xA0)
                guard index < written.count else { throw DecodeError(description: "a reference to value \(index) of \(written.count)") }
                return written[index]
            case 0xD0 ... 0xDE:
                var items: [Opack] = []
                for _ in 0 ..< Int(tag - 0xD0) { items.append(try value()) }
                return .array(items)
            case 0xDF:
                var items: [Opack] = []
                while let item = try valueOrEnd() { items.append(item) }
                return .array(items)
            case 0xE0 ... 0xEE:
                var entries: [(String, Opack)] = []
                for _ in 0 ..< Int(tag - 0xE0) { entries.append((try key(), try value())) }
                return .dictionary(entries)
            case 0xEF:
                var entries: [(String, Opack)] = []
                while let k = try valueOrEnd() {
                    guard case let .string(key) = k else { throw DecodeError(description: "a dictionary key that isn't text") }
                    entries.append((key, try value()))
                }
                return .dictionary(entries)
            default:
                throw DecodeError(description: String(format: "an unknown tag 0x%02x", tag))
            }
        }

        mutating func text(_ n: Int) throws(DecodeError) -> String {
            String(decoding: try take(n), as: UTF8.self)
        }

        mutating func key() throws(DecodeError) -> String {
            guard case let .string(key) = try value() else { throw DecodeError(description: "a dictionary key that isn't text") }
            return key
        }
    }
}
