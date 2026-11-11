import Testing
@testable import HAP

/// Encodings worked out from HAP-NodeJS's DataStreamWriter (src/lib/datastream/DataStreamParser.ts).
@Suite struct OpackTests {
    @Test func numbersPickTheirSmallestForm() {
        #expect(Opack.int(-1).encoded == [0x07])
        #expect(Opack.int(0).encoded == [0x08])
        #expect(Opack.int(39).encoded == [0x2F])
        #expect(Opack.int(40).encoded == [0x30, 40])
        #expect(Opack.int(-2).encoded == [0x30, 0xFE])
        #expect(Opack.int(300).encoded == [0x31, 0x2C, 0x01])
        #expect(Opack.int(100_000).encoded == [0x32, 0xA0, 0x86, 0x01, 0x00])     // 5 bytes, as HAP-NodeJS's test
        #expect(Opack.int(2_147_483_648).encoded.count == 9)
        #expect(Opack.float(1.5).encoded == [0x36, 0, 0, 0, 0, 0, 0, 0xF8, 0x3F])
    }

    @Test func textAndDataCarryShortLengthsInTheirTag() {
        #expect(Opack.string("hello").encoded == [0x45] + Array("hello".utf8))
        #expect(Opack.string("hëllo").encoded.first == 0x46)                     // 6 bytes of UTF-8
        #expect(Opack.string(String(repeating: "a", count: 40)).encoded.prefix(2) == [0x61, 40])
        #expect(Opack.data([1, 2, 3]).encoded == [0x73, 1, 2, 3])
        #expect(Opack.data([UInt8](repeating: 0, count: 300)).encoded.prefix(3) == [0x92, 0x2C, 0x01])
    }

    @Test func aDataStreamHelloRoundTrips() throws {
        // The header of HDS's first request: {protocol: "control", request: "hello", id: 1}.
        let header = Opack.dictionary([("protocol", .string("control")), ("request", .string("hello")), ("id", .int(1))])
        let bytes = header.encoded
        #expect(bytes == [0xE3, 0x48] + Array("protocol".utf8) + [0x47] + Array("control".utf8)
            + [0x47] + Array("request".utf8) + [0x45] + Array("hello".utf8) + [0x42] + Array("id".utf8) + [0x09])
        let decoded = try Opack.decode(bytes)
        #expect(decoded == header)
        #expect(decoded["request"]?.string == "hello")
    }

    @Test func longCollectionsAreTerminated() throws {
        let long = Opack.array((0 ..< 13).map { .int(Int64($0)) })
        #expect(long.encoded.first == 0xDF && long.encoded.last == 0x03)
        #expect(try Opack.decode(long.encoded) == long)
        let dict = Opack.dictionary((0 ..< 15).map { ("k\($0)", .bool($0 % 2 == 0)) })
        #expect(dict.encoded.first == 0xEF)
        #expect(try Opack.decode(dict.encoded) == dict)
    }

    @Test func compressedValuesReferBackToTheFullOnes() throws {
        // {"a": "xyz", "b": <the first value written in full again>}: "a" is index 0, "xyz" 1, "b" 2.
        let bytes: [UInt8] = [0xE2, 0x41, 0x61, 0x43, 0x78, 0x79, 0x7A, 0x41, 0x62, 0xA1]
        #expect(try Opack.decode(bytes) == .dictionary([("a", .string("xyz")), ("b", .string("xyz"))]))
        #expect(throws: Opack.DecodeError.self) { try Opack.decode([0xA5]) }
    }

    @Test func malformedMessagesAreErrorsNotCrashes() {
        #expect(throws: Opack.DecodeError.self) { try Opack.decode([0x45, 0x61]) }          // ends early
        #expect(throws: Opack.DecodeError.self) { try Opack.decode([0x08, 0x08]) }          // something after it
        #expect(throws: Opack.DecodeError.self) { try Opack.decode([0x00]) }                // tag 0
        #expect(throws: Opack.DecodeError.self) { try Opack.decode([0xE1, 0x08, 0x08]) }    // a key that isn't text
    }
}
