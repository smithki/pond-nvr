import Testing
@testable import Ingest

@Suite struct DepacketizerTests {
    static let sps: [UInt8] = [0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0, 0x28, 0x00, 0xB5, 0x90]
    static let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0xB0]

    static func packet(_ seq: UInt16, _ ts: UInt32, _ payload: [UInt8], marker: Bool = false) -> RTPPacket {
        RTPPacket(payloadType: 96, marker: marker, sequence: seq, timestamp: ts, ssrc: 1, payload: payload)
    }

    @Test func rtpHeaderWithPaddingAndExtension() throws {
        // V=2, P=1, X=1, CC=0; one extension word; 2 bytes of padding.
        let bytes: [UInt8] = [0xB0, 0xE0, 0x00, 0x05, 0, 0, 0x01, 0x00, 0, 0, 0, 7,
                              0xBE, 0xDE, 0x00, 0x01, 1, 2, 3, 4,
                              0xAA, 0xBB, 0x00, 0x02]
        let p = try #require(RTPPacket(bytes))
        #expect(p.marker)
        #expect(p.payloadType == 96)
        #expect(p.sequence == 5)
        #expect(p.timestamp == 256)
        #expect(p.payload == [0xAA, 0xBB])
        #expect(RTPPacket([0x80, 0x60]) == nil)
    }

    @Test func stapAThenFragmentedKeyframe() {
        var d = H264Depacketizer()
        let stap: [UInt8] = [0x18, 0x00, UInt8(Self.sps.count)] + Self.sps + [0x00, UInt8(Self.pps.count)] + Self.pps
        let idr: [UInt8] = [0x65] + (1 ... 300).map { UInt8($0 & 0xFF) }
        // FU-A: indicator keeps F|NRI with type 28; header has S/E and the real type.
        let fu1: [UInt8] = [0x7C, 0x85] + idr[1 ..< 150]
        let fu2: [UInt8] = [0x7C, 0x45] + idr[150...]
        #expect(d.push(Self.packet(1, 1000, stap)).isEmpty)
        #expect(d.push(Self.packet(2, 1000, fu1)).isEmpty)
        let units = d.push(Self.packet(3, 1000, fu2, marker: true))
        #expect(units == [H264AccessUnit(timestamp: 1000, nalus: [idr], isKeyframe: true, damaged: false)])
        #expect(d.sps == Self.sps)
        #expect(d.pps == Self.pps)
    }

    @Test func timestampChangeEndsAFrameWithoutAMarker() {
        var d = H264Depacketizer()
        #expect(d.push(Self.packet(1, 1000, [0x41, 1])).isEmpty)
        let units = d.push(Self.packet(2, 5500, [0x41, 2]))
        #expect(units.map(\.timestamp) == [1000])
        #expect(units.first?.isKeyframe == false)
    }

    @Test func lossDropsTheBrokenNALAndMarksTheFrame() {
        var d = H264Depacketizer()
        _ = d.push(Self.packet(1, 1000, [0x41, 9]))                // a whole slice
        _ = d.push(Self.packet(2, 1000, [0x7C, 0x81, 1, 2]))       // FU-A start of another
        // Packet 3 is lost: the fragment cannot be completed.
        let units = d.push(Self.packet(4, 1000, [0x7C, 0x41, 5, 6], marker: true))
        #expect(units == [H264AccessUnit(timestamp: 1000, nalus: [[0x41, 9]], isKeyframe: false, damaged: true)])
        #expect(d.lostPackets == 1)
    }

    @Test func parameterSetsFromTheDescription() {
        let d = H264Depacketizer(spropParameterSets: "Z2QAM6wVFKAoALWQ,aO48sA==")
        #expect(d.sps == Self.sps)
        #expect(d.pps == [0x68, 0xEE, 0x3C, 0xB0])
    }

    @Test func aacHbrWithTwoFrames() {
        // AU-headers-length 32 bits: two headers of 13-bit size + 3-bit index.
        let a: [UInt8] = [1, 2, 3], b: [UInt8] = [4, 5]
        let headers: [UInt8] = [0x00, 0x20, UInt8(a.count >> 5), UInt8((a.count & 0x1F) << 3), UInt8(b.count >> 5), UInt8((b.count & 0x1F) << 3)]
        let aac = AACDepacketizer(format: ["sizelength": "13", "indexlength": "3", "indexdeltalength": "3"])
        let frames = aac.push(Self.packet(1, 16000, headers + a + b))
        #expect(frames == [AACFrame(timestamp: 16000, data: a), AACFrame(timestamp: 17024, data: b)])
    }

    @Test func unwrapAndClock() throws {
        var u = TimestampUnwrapper()
        #expect(u.unwrap(UInt32.max - 10) == Int64(UInt32.max) - 10)
        #expect(u.unwrap(5) == Int64(UInt32.max) + 6)
        var clock = RTPClock(rate: 90000)
        #expect(clock.wallTime(0) == nil)
        // Sender report: NTP 2026-01-01 00:00:00.5 UTC ↔ RTP 900000.
        let ntp = UInt32(1_767_225_600 + 2_208_988_800)
        let sr: [UInt8] = [0x80, 200, 0x00, 0x06, 0, 0, 0, 1] + MP4Bytes.u32(ntp) + MP4Bytes.u32(0x8000_0000)
            + MP4Bytes.u32(900_000) + [UInt8](repeating: 0, count: 8)
        clock.noteRTCP(sr)
        #expect(clock.isSynchronized)
        #expect(abs(try #require(clock.wallTime(990_000)) - 1_767_225_601.5) < 1e-6)
        #expect(abs(try #require(clock.wallTime(810_000)) - 1_767_225_599.5) < 1e-6)
    }
}

enum MP4Bytes {
    static func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
