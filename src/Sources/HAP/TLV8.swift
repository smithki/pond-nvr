// TLV8, the type-length-value encoding HAP uses for pairing and for camera stream setup.
//
// Each item is one type byte, one length byte, then up to 255 bytes of value. A longer value is split into
// consecutive items of the same type, and a reader joins them back together. Two items of the same type that
// belong to different list entries are kept apart by a zero-length separator item (type 0xFF).

/// One decoded TLV8 item: its type and its whole value (fragments already joined).
public struct TLV8Item: Equatable, Sendable {
    public var type: UInt8
    public var value: [UInt8]

    public init(_ type: UInt8, _ value: [UInt8]) {
        self.type = type
        self.value = value
    }
}

public enum TLV8 {
    /// The separator type between list entries.
    public static let separator: UInt8 = 0xFF

    public enum DecodeError: Error, Equatable {
        /// The data ended inside an item: at `offset` an item needed more bytes than were left.
        case truncated(offset: Int)
    }

    /// Encodes items in order, splitting values longer than 255 bytes into fragments.
    public static func encode(_ items: [TLV8Item]) -> [UInt8] {
        var out: [UInt8] = []
        for item in items {
            if item.value.isEmpty {
                out += [item.type, 0]
                continue
            }
            var rest = item.value[...]
            while !rest.isEmpty {
                let chunk = rest.prefix(255)
                out += [item.type, UInt8(chunk.count)]
                out += chunk
                rest = rest.dropFirst(chunk.count)
            }
        }
        return out
    }

    /// Decodes data into items, joining the fragments of a long value. Separator items are kept, so a caller
    /// reading a list can split on them; `decodeList` does that.
    public static func decode(_ data: [UInt8]) throws(DecodeError) -> [TLV8Item] {
        var items: [TLV8Item] = []
        var i = 0
        // True while the last item was a full 255-byte fragment, so a following item of the same type continues it.
        var continues = false
        while i < data.count {
            guard i + 2 <= data.count else { throw .truncated(offset: i) }
            let type = data[i]
            let length = Int(data[i + 1])
            guard i + 2 + length <= data.count else { throw .truncated(offset: i) }
            let value = Array(data[i + 2 ..< i + 2 + length])
            if continues, let last = items.last, last.type == type {
                items[items.count - 1].value += value
            } else {
                items.append(TLV8Item(type, value))
            }
            continues = length == 255
            i += 2 + length
        }
        return items
    }

    /// Decodes a list: entries are separated by separator items, which are not returned.
    public static func decodeList(_ data: [UInt8]) throws(DecodeError) -> [[TLV8Item]] {
        var entries: [[TLV8Item]] = [[]]
        for item in try decode(data) {
            if item.type == separator {
                entries.append([])
            } else {
                entries[entries.count - 1].append(item)
            }
        }
        return entries.filter { !$0.isEmpty }
    }

    /// Encodes a list of entries with a separator between each pair.
    public static func encodeList(_ entries: [[TLV8Item]]) -> [UInt8] {
        var items: [TLV8Item] = []
        for (n, entry) in entries.enumerated() {
            if n > 0 { items.append(TLV8Item(separator, [])) }
            items += entry
        }
        return encode(items)
    }
}

extension Array where Element == TLV8Item {
    /// The value of the first item of this type, if any.
    public func value(_ type: UInt8) -> [UInt8]? {
        first { $0.type == type }?.value
    }
}
