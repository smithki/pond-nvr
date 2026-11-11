import Foundation
import Ingest
import Media
import Testing
@testable import Recorder

@Suite struct StreamRecorderTests {
    static let sdp = SDP("""
    m=video 0 RTP/AVP 96\r
    a=rtpmap:96 H264/90000\r
    a=control:track1\r
    m=audio 0 RTP/AVP 97\r
    a=rtpmap:97 MPEG4-GENERIC/16000\r
    a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1408\r
    a=control:track2\r

    """)
    static let sps: [UInt8] = [0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0, 0x28, 0x00, 0xB5, 0x90]
    static let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0xB0]
    static let wall = 1_767_225_600.0   // 2026-01-01 00:00:00 UTC

    static func rtp(_ seq: Int, _ ts: UInt32, _ payload: [UInt8], marker: Bool = true, pt: UInt8 = 96) -> [UInt8] {
        [0x80, pt | (marker ? 0x80 : 0), UInt8(seq >> 8 & 0xFF), UInt8(seq & 0xFF)] + MP4Bytes.u32(ts) + [0, 0, 0, 1] + payload
    }

    /// A sender report tying RTP `rtp` to `seconds` after `wall`.
    static func sr(rtp: UInt32, seconds: Double) -> [UInt8] {
        let t = wall + seconds + 2_208_988_800
        let whole = UInt32(t.rounded(.down))
        let fraction = UInt32((t - t.rounded(.down)) * 4_294_967_296)
        return [0x80, 200, 0x00, 0x06, 0, 0, 0, 1] + MP4Bytes.u32(whole) + MP4Bytes.u32(fraction) + MP4Bytes.u32(rtp)
            + [UInt8](repeating: 0, count: 8)
    }

    static func aac(_ ts: UInt32) -> [UInt8] {
        rtp(0, ts, [0x00, 0x10, 0x00, 0x18, 0xAB, 0xCD, 0xEF], pt: 97)   // one 3-byte frame
    }

    @Test func recordsFromTheFirstKeyframeWithAudioInStep() throws {
        let r = StreamRecorder(video: try #require(Self.sdp.video), audio: Self.sdp.audio)
        var outputs: [StreamRecorder.Output] = []
        // Video RTP 1_000_000 is wall+0; audio RTP 50_000 is wall+0.5 (unrelated clocks, as on a real camera).
        outputs += r.handle(InterleavedPacket(channel: 1, data: Self.sr(rtp: 1_000_000, seconds: 0)), now: 0)
        outputs += r.handle(InterleavedPacket(channel: 3, data: Self.sr(rtp: 50000, seconds: 0.5)), now: 0)
        // A frame before any keyframe is skipped.
        outputs += r.handle(InterleavedPacket(channel: 0, data: Self.rtp(1, 995_500, [0x41, 0])), now: 0)
        #expect(outputs.isEmpty)
        var seq = 2
        for f in 0 ..< 100 {   // 5 s at 20 fps, keyframe every 2 s
            let ts = UInt32(1_000_000 + f * 4500)
            if f % 40 == 0 {
                let stap: [UInt8] = [0x18, 0, UInt8(Self.sps.count)] + Self.sps + [0, UInt8(Self.pps.count)] + Self.pps
                outputs += r.handle(InterleavedPacket(channel: 0, data: Self.rtp(seq, ts, stap, marker: false)), now: 0)
                seq += 1
            }
            outputs += r.handle(InterleavedPacket(channel: 0, data: Self.rtp(seq, ts, [f % 40 == 0 ? 0x65 : 0x41, UInt8(f)])), now: 0)
            seq += 1
            // Audio from wall+0.5 s on: RTP 50000 + n*1024.
            let audioWall = Double(f) / 20
            if audioWall >= 0.5, (f - 10) % 3 == 0 {
                let n = UInt32((audioWall - 0.5) * 16000 / 1024)
                outputs += r.handle(InterleavedPacket(channel: 2, data: Self.aac(50000 + n * 1024)), now: 0)
            }
        }
        outputs += r.finish()
        guard case let .start(initSegment, wallTime) = outputs.first else { Issue.record("no start"); return }
        #expect(abs(wallTime - Self.wall) < 0.001)
        #expect(Box.parseTypes(initSegment) == ["ftyp", "moov"])
        let fragments = outputs.dropFirst().compactMap { o -> [UInt8]? in if case let .fragment(f) = o { f } else { nil } }
        #expect(fragments.count == 3)   // 0-2 s, 2-4 s, 4-5 s
        #expect(r.videoFrames == 100)
        // The first audio frame was at wall+0.5 s: 8000 samples into the recording.
        let firstAudio = Box.firstAudioTime(fragments[0])
        #expect(firstAudio == 8000, "first audio at \(String(describing: firstAudio))")
    }
}

extension Box {
    static func parseTypes(_ bytes: [UInt8]) -> [String] {
        var types: [String] = []
        var i = 0
        while i + 8 <= bytes.count {
            let size = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            types.append(String(decoding: bytes[i + 4 ..< i + 8], as: UTF8.self))
            guard size >= 8 else { break }
            i += size
        }
        return types
    }

    /// The audio track's tfdt in a fragment (the second traf).
    static func firstAudioTime(_ fragment: [UInt8]) -> UInt64? {
        let moof = Box.parse(fragment)[0]
        let trafs = moof.children.filter { $0.type == "traf" }
        guard trafs.count == 2 else { return nil }
        return trafs[1].find("tfdt")?.u64(4)
    }
}

enum MP4Bytes {
    static func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}

@Suite struct SegmentingTests {
    /// Feeds `seconds` of 20 fps video (keyframe every 2 s) with a sender report, returns the outputs.
    static func record(seconds: Int, segment: Double?) throws -> (StreamRecorder, [StreamRecorder.Output]) {
        let r = StreamRecorder(video: try #require(StreamRecorderTests.sdp.video), audio: nil, segmentSeconds: segment)
        var outputs = r.handle(InterleavedPacket(channel: 1, data: StreamRecorderTests.sr(rtp: 1_000_000, seconds: 0)), now: 0)
        var seq = 0
        for f in 0 ..< seconds * 20 {
            let ts = UInt32(1_000_000 + f * 4500)
            if f % 40 == 0 {
                let stap: [UInt8] = [0x18, 0, UInt8(StreamRecorderTests.sps.count)] + StreamRecorderTests.sps
                    + [0, UInt8(StreamRecorderTests.pps.count)] + StreamRecorderTests.pps
                outputs += r.handle(InterleavedPacket(channel: 0, data: StreamRecorderTests.rtp(seq, ts, stap, marker: false)), now: 0)
                seq += 1
            }
            outputs += r.handle(InterleavedPacket(channel: 0, data: StreamRecorderTests.rtp(seq, ts, [f % 40 == 0 ? 0x65 : 0x41, UInt8(f & 0xFF)])), now: 0)
            seq += 1
        }
        outputs += r.finish()
        return (r, outputs)
    }

    @Test func cutsAtTheFirstKeyframeAfterTheSegmentLength() throws {
        let (r, outputs) = try Self.record(seconds: 25, segment: 10)
        let starts = outputs.compactMap { o -> Double? in if case let .start(_, wall) = o { wall } else { nil } }
        let ends = outputs.compactMap { o -> SegmentSummary? in if case let .end(s) = o { s } else { nil } }
        #expect(starts.map { $0 - StreamRecorderTests.wall } == [0, 10, 20])
        #expect(ends.map(\.seconds) == [10, 10, 5])
        #expect(ends.map(\.videoFrames) == [200, 200, 100])
        #expect(r.videoFrames == 500)
        // Each segment is a whole MP4: init, fragments, end.
        var expectingStart = true
        for o in outputs {
            switch o {
            case let .start(initSegment, _):
                #expect(expectingStart)
                #expect(Box.parseTypes(initSegment) == ["ftyp", "moov"])
                expectingStart = false
            case .fragment:
                #expect(!expectingStart)
            case .end:
                expectingStart = true
            }
        }
    }

    @Test func withoutASegmentLengthItIsOneRecording() throws {
        let (_, outputs) = try Self.record(seconds: 25, segment: nil)
        #expect(outputs.filter { if case .start = $0 { true } else { false } }.count == 1)
        #expect(outputs.filter { if case .end = $0 { true } else { false } }.count == 1)
    }
}
