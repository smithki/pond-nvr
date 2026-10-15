import Ingest
import Testing
@testable import HAPCamera

@Suite struct RTPPacketizerTests {
    @Test func smallNALsGoWholeLargeOnesAsFUA() throws {
        var p = RTPPacketizer(payloadType: 99, ssrc: 0x01020304, maxPayload: 100, sequence: 0xFFFF)
        let sps: [UInt8] = [0x67] + Array(repeating: 1, count: 10)
        let idr: [UInt8] = [0x65] + Array(repeating: 7, count: 250)
        let packets = p.packetize([sps, idr], timestamp: 9000)
        #expect(packets.count == 1 + 3)                       // 250 bytes in 98-byte FU-A slices
        #expect(packets[0][12...] == sps[...])
        #expect(packets.map { $0[1] & 0x80 } == [0, 0, 0, 0x80])   // marker on the last
        #expect(packets.map { UInt16($0[2]) << 8 | UInt16($0[3]) } == [0xFFFF, 0, 1, 2])
        #expect(packets[1][12] == 0x7C && packets[1][13] == 0x85)    // FU indicator (NRI 3, type 28), start + type 5
        #expect(packets[3][13] == 0x45)                               // end + type 5

        // Our own depacketizer puts the frame back together.
        var d = H264Depacketizer()
        var units: [H264AccessUnit] = []
        for packet in packets { units += d.push(try #require(RTPPacket(packet))) }
        #expect(units.count == 1)
        #expect(units.first?.nalus == [idr])                  // SPS kept aside as the parameter set
        #expect(d.sps == sps)
        #expect(units.first?.isKeyframe == true)
    }

    @Test func senderReportCounts() {
        var p = RTPPacketizer(payloadType: 99, ssrc: 7, maxPayload: 1000)
        _ = p.packetize([[0x41, 1, 2, 3]], timestamp: 1)
        let sr = p.senderReport(rtpTimestamp: 1234)
        #expect(sr.count == 28 && sr[1] == 200)
        #expect(Array(sr[20 ..< 28]) == [0, 0, 0, 1, 0, 0, 0, 4])
    }
}

@Suite struct AACPacketTests {
    @Test func oneFramePerPacketWithAnAUHeader() {
        var p = RTPPacketizer(payloadType: 110, ssrc: 0x0102_0304, maxPayload: 1000, sequence: 7)
        let packet = p.packetize(aac: [UInt8](repeating: 0xAB, count: 100), timestamp: 480)
        #expect(packet[0] == 0x80)
        #expect(packet[1] == 0x80 | 110)                  // marker, payload type
        #expect(packet[2 ..< 4] == [0, 7])
        #expect(packet[4 ..< 8] == [0, 0, 0x01, 0xE0])     // 480
        #expect(packet[12 ..< 16] == [0x00, 0x10, 0x03, 0x20])   // 16 bits of headers; 100 << 3
        #expect(packet.count == 16 + 100)
    }

    @Test func severalFramesShareAPacket() {
        var p = RTPPacketizer(payloadType: 110, ssrc: 1, maxPayload: 1000)
        let packet = p.packetize(aac: [[UInt8](repeating: 0xAB, count: 100), [UInt8](repeating: 0xCD, count: 50)], timestamp: 960)
        #expect(packet[4 ..< 8] == [0, 0, 0x03, 0xC0])     // the first frame's time
        #expect(packet[12 ..< 18] == [0x00, 0x20, 0x03, 0x20, 0x01, 0x90])   // 32 bits of headers; 100 << 3; 50 << 3
        #expect(packet[18] == 0xAB && packet[118] == 0xCD)
        #expect(packet.count == 18 + 150)
    }
}
