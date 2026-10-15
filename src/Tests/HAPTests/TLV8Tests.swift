import Testing
@testable import HAP

@Suite struct TLV8Tests {
    @Test func shortItemsRoundTrip() throws {
        let items = [TLV8Item(0x06, [0x01]), TLV8Item(0x00, [0x00]), TLV8Item(0x01, Array("Pair-Setup".utf8))]
        let bytes = TLV8.encode(items)
        #expect(bytes.prefix(6) == [0x06, 0x01, 0x01, 0x00, 0x01, 0x00])
        #expect(try TLV8.decode(bytes) == items)
    }

    @Test func emptyValueIsOneZeroLengthItem() throws {
        #expect(TLV8.encode([TLV8Item(0x07, [])]) == [0x07, 0x00])
        #expect(try TLV8.decode([0x07, 0x00]) == [TLV8Item(0x07, [])])
    }

    // An SRP public key (384 bytes) is the common case of a value longer than one item.
    @Test func longValueIsFragmentedAndJoined() throws {
        let key = (0 ..< 384).map { UInt8($0 % 251) }
        let bytes = TLV8.encode([TLV8Item(0x03, key), TLV8Item(0x06, [0x02])])
        #expect(bytes.count == 2 + 255 + 2 + 129 + 3)
        #expect(bytes[0 ... 1] == [0x03, 0xFF])
        #expect(bytes[257 ... 258] == [0x03, 129])
        #expect(try TLV8.decode(bytes) == [TLV8Item(0x03, key), TLV8Item(0x06, [0x02])])
    }

    @Test func exactly255BytesIsOneItem() throws {
        let value = [UInt8](repeating: 0xAB, count: 255)
        let bytes = TLV8.encode([TLV8Item(0x09, value)])
        #expect(bytes.count == 257)
        #expect(try TLV8.decode(bytes) == [TLV8Item(0x09, value)])
    }

    // Two items of the same type after a short one are separate items, not fragments.
    @Test func sameTypeAfterShortItemIsNotJoined() throws {
        let bytes: [UInt8] = [0x01, 0x01, 0xAA, 0x01, 0x01, 0xBB]
        #expect(try TLV8.decode(bytes) == [TLV8Item(0x01, [0xAA]), TLV8Item(0x01, [0xBB])])
    }

    @Test func listsSplitOnSeparators() throws {
        let entries = [[TLV8Item(0x01, [0x01]), TLV8Item(0x02, [0x05])], [TLV8Item(0x01, [0x02])]]
        let bytes = TLV8.encodeList(entries)
        #expect(bytes == [0x01, 0x01, 0x01, 0x02, 0x01, 0x05, 0xFF, 0x00, 0x01, 0x01, 0x02])
        #expect(try TLV8.decodeList(bytes) == entries)
    }

    @Test func truncatedDataIsAnError() {
        #expect(throws: TLV8.DecodeError.truncated(offset: 0)) { try TLV8.decode([0x01, 0x03, 0xAA]) }
        #expect(throws: TLV8.DecodeError.truncated(offset: 3)) { try TLV8.decode([0x01, 0x01, 0xAA, 0x02]) }
    }

    @Test func valueLookup() throws {
        let items = try TLV8.decode([0x06, 0x01, 0x03, 0x07, 0x01, 0x02])
        #expect(items.value(0x07) == [0x02])
        #expect(items.value(0x05) == nil)
    }
}
