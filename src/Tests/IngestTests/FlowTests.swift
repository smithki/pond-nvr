import Testing
@testable import Ingest

@Suite struct FlowTests {
    static let idr: [UInt8] = [0x65, 0x88]                 // IDR slice, single NAL
    static let slice: [UInt8] = [0x41, 0x9A]               // non-IDR slice
    static let fuIDRStart: [UInt8] = [0x7C, 0x85, 0x00]    // FU-A, start bit, type 5
    static let fuIDRMiddle: [UInt8] = [0x7C, 0x05, 0x00]   // FU-A, no start bit

    @Test func recognisesKeyframes() {
        #expect(FlowAnalyzer.containsIDR(Self.idr))
        #expect(!FlowAnalyzer.containsIDR(Self.slice))
        #expect(FlowAnalyzer.containsIDR(Self.fuIDRStart))
        #expect(!FlowAnalyzer.containsIDR(Self.fuIDRMiddle))
        // STAP-A with SPS, PPS, IDR.
        #expect(FlowAnalyzer.containsIDR([0x18, 0x00, 0x02, 0x67, 0x64, 0x00, 0x02, 0x68, 0xEE, 0x00, 0x02, 0x65, 0x88]))
        #expect(!FlowAnalyzer.containsIDR([0x18, 0x00, 0x02, 0x67, 0x64]))
    }

    /// 20 fps for `seconds`, a keyframe every 40 frames, each frame in two packets.
    static func stream(seconds: Int, startTS: UInt32 = 1000) -> FlowResult {
        var a = FlowAnalyzer()
        var seq: UInt16 = 0
        for frame in 0 ..< seconds * 20 {
            let ts = startTS &+ UInt32(frame * 4500)
            let first = frame % 40 == 0 ? fuIDRStart : slice
            for payload in [first, fuIDRMiddle] {
                a.add(InterleavedPacket(channel: 0, data: Fixtures.rtp(seq: seq, ts: ts, payload: payload)),
                      at: Double(frame) / 20)
                seq &+= 1
            }
        }
        return a.result(seconds: Double(seconds))
    }

    @Test func frameRateAndKeyframeInterval() throws {
        guard case let .flowing(stats) = Self.stream(seconds: 6) else { Issue.record("no flow"); return }
        #expect(abs(try #require(stats.fps) - 20) < 0.01)
        #expect(abs(try #require(stats.keyframeInterval) - 2) < 0.01)
        #expect(stats.keyframes == 3)
        #expect(stats.firstVideoAfter == 0)
    }

    @Test func timestampWrapAround() throws {
        guard case let .flowing(stats) = Self.stream(seconds: 6, startTS: UInt32.max - 100_000) else {
            Issue.record("no flow"); return
        }
        #expect(abs(try #require(stats.fps) - 20) < 0.01)
    }

    @Test func privacyModeIsSenderReportsSayingNothingWasSent() {
        var a = FlowAnalyzer()
        a.add(InterleavedPacket(channel: 1, data: Fixtures.senderReport(packets: 0)), at: 0.1)
        #expect(a.result(seconds: 8) == .privacyMode)
    }

    @Test func silenceIsNoVideo() {
        #expect(FlowAnalyzer().result(seconds: 8) == .noVideo)
        var a = FlowAnalyzer()
        a.add(InterleavedPacket(channel: 1, data: Fixtures.senderReport(packets: 500)), at: 0.1)
        #expect(a.result(seconds: 8) == .noVideo)
    }
}

@Suite struct InBandSPSTests {
    static let mainSPS: [UInt8] = [0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0, 0x28, 0x00, 0xB5, 0x90]   // Z2QAM6wVFKAoALWQ

    @Test func singleAndAggregated() {
        #expect(FlowAnalyzer.inBandSPS(Self.mainSPS)?.width == 2560)
        let stap: [UInt8] = [0x18, 0x00, UInt8(Self.mainSPS.count)] + Self.mainSPS + [0x00, 0x02, 0x68, 0xEE]
        #expect(FlowAnalyzer.inBandSPS(stap)?.height == 1440)
        #expect(FlowAnalyzer.inBandSPS([0x65, 0x88]) == nil)
    }

    @Test func statsCarryTheFirstSPS() {
        var a = FlowAnalyzer()
        for (n, payload) in [Self.mainSPS, [0x65, 0x88], [0x41, 0x9A], [0x41, 0x9A]].enumerated() {
            a.add(InterleavedPacket(channel: 0, data: Fixtures.rtp(seq: UInt16(n), ts: UInt32(n * 4500), payload: payload)), at: 0)
        }
        guard case let .flowing(stats) = a.result(seconds: 1) else { Issue.record("no flow"); return }
        #expect(stats.sps?.width == 2560)
    }
}
