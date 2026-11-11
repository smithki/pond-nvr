import Foundation
import Testing
@testable import Devices

@Suite struct BaichuanTests {
    @Test func theXORCipherUndoesItself() {
        let text = Array("<?xml version=\"1.0\" encoding=\"UTF-8\" ?><body/>".utf8)
        for offset: UInt8 in [0, 1, 250, 251] {
            let once = BaichuanClient.xor(text, offset: offset)
            #expect(once != text)
            #expect(BaichuanClient.xor(once, offset: offset) == text)
        }
    }

    @Test func theXORKeyTurnsWithTheOffset() {
        // Byte i of the keystream is key[(offset + i) % 8] ^ offset (as reolink_aio and neolink make it).
        let zeros = [UInt8](repeating: 0, count: 8)
        #expect(BaichuanClient.xor(zeros, offset: 0) == BaichuanClient.xmlKey)
        #expect(BaichuanClient.xor(zeros, offset: 1)[0] == BaichuanClient.xmlKey[1] ^ 1)
    }

    @Test func aesCFBRoundTrips() {
        let key = Array("0123456789ABCDEF".utf8)
        let text = Array("<?xml version=\"1.0\" ?><body><sleep>1</sleep></body>".utf8)
        let sealed = BaichuanClient.aesCFB(text, key: key, encrypt: true)
        #expect(sealed.count == text.count && sealed != text)
        #expect(BaichuanClient.aesCFB(sealed, key: key, encrypt: false) == text)
    }

    @Test func theLoginHashIsMD5InCapitalsCutTo31() {
        // MD5("admin") = 21232f297a57a5a743894a0e4a801fc3.
        #expect(BaichuanClient.md5Modern("admin") == "21232F297A57A5A743894A0E4A801FC")
    }

    @Test func headersAreTwentyOrTwentyFourBytesByClass() throws {
        #expect(try BaichuanClient.headerLength([0x14, 0x66]) == 20)
        #expect(try BaichuanClient.headerLength([0x14, 0x64]) == 24)
        #expect(try BaichuanClient.headerLength([0x00, 0x00]) == 24)
        #expect(throws: BaichuanClient.Failure.self) { try BaichuanClient.headerLength([0x12, 0x34]) }
    }

    @Test func valuesAreReadFromTheXML() {
        #expect(BaichuanClient.value("sleep", in: "<sleepState><sleep>1</sleep></sleepState>") == "1")
        #expect(BaichuanClient.value("nonce", in: "<body/>") == nil)
    }

    static func event(_ status: String, ai: String = "none", channel: Int = 0) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body><AlarmEventList version="1.1"><AlarmEvent version="1.1">
        <channelId>\(channel)</channelId><status>\(status)</status><AItype>\(ai)</AItype>
        </AlarmEvent></AlarmEventList></body>
        """
    }

    @Test func pushedEventsSayMotionAndAVisitor() throws {
        let still = try #require(BaichuanSession.alarm(in: Self.event("none")))
        #expect(!still.motion && !still.visitor)
        #expect(try #require(BaichuanSession.alarm(in: Self.event("MD"))).motion)
        // A person, a vehicle or an animal is motion too.
        #expect(try #require(BaichuanSession.alarm(in: Self.event("none", ai: "people,vehicle"))).motion)
        #expect(try #require(BaichuanSession.alarm(in: Self.event("visitor"))).visitor)
        // Another channel's (an NVR's) isn't the camera's.
        #expect(BaichuanSession.alarm(in: Self.event("MD", channel: 1)) == nil)
    }
}
