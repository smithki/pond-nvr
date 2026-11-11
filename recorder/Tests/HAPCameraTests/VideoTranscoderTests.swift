import CoreMedia
import Foundation
import Testing
@testable import HAPCamera

@Suite struct VideoTranscoderTests {
    /// A five-second test pattern as a camera sends it: 160×120 H.264 at 10 fps, 50 frames, in order (no
    /// B-frames), a keyframe every 2 s, as a raw Annex B stream. Made with ffmpeg's testsrc and libx264
    /// (-bf 0 -g 20), one slice a frame.
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/in-order.h264")

    /// The fixture's frames as a camera sends them: each frame's slice, its SPS and PPS, at 10 fps on the
    /// 90 kHz clock.
    static func frames() throws -> (sps: [UInt8], pps: [UInt8], units: [(nalus: [[UInt8]], time: Int64)]) {
        let bytes = [UInt8](try Data(contentsOf: fixture))
        // NAL units between start codes (00 00 01, or 00 00 00 01).
        var nalus: [[UInt8]] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    var end = i
                    if end > s, bytes[end - 1] == 0 { end -= 1 }
                    nalus.append(Array(bytes[s ..< end]))
                }
                start = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if let s = start { nalus.append(Array(bytes[s...])) }
        var sps: [UInt8] = [], pps: [UInt8] = []
        var units: [(nalus: [[UInt8]], time: Int64)] = []
        for nal in nalus {
            switch nal[0] & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            case 1, 5: units.append(([nal], Int64(units.count) * 9000))
            default: break
            }
        }
        return (sps, pps, units)
    }

    final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var frames: [VideoTranscoder.Frame] = []
        func add(_ f: VideoTranscoder.Frame) { lock.withLock { frames.append(f) } }
        var all: [VideoTranscoder.Frame] { lock.withLock { frames } }
    }

    @Test func reencodesToTheAskedSizeAndRate() async throws {
        let (sps, pps, units) = try Self.frames()
        #expect(units.count == 50)
        let collected = Collected()
        let transcoder = VideoTranscoder(target: .init(width: 120, height: 90, bitrate: 2000, fps: 5, profile: 1), realTime: false) { collected.add($0) }
        for unit in units { transcoder.push(unit.nalus, sps: sps, pps: pps, time: unit.time, encode: true) }
        transcoder.finish()
        let frames = collected.all
        // 5 of the 10 frames a second, the first a keyframe with its SPS and PPS.
        #expect((20 ... 27).contains(frames.count))
        let first = try #require(frames.first)
        #expect(first.keyframe)
        #expect(first.nalus.first.map { $0[0] & 0x1F } == 7)
        #expect(first.nalus.dropFirst().first.map { $0[0] & 0x1F } == 8)
        var format: CMVideoFormatDescription?
        let outSPS = first.nalus[0], outPPS = first.nalus[1]
        outSPS.withUnsafeBufferPointer { s in
            outPPS.withUnsafeBufferPointer { p in
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: [s.baseAddress!, p.baseAddress!],
                    parameterSetSizes: [s.count, p.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        let size = CMVideoFormatDescriptionGetDimensions(try #require(format))
        #expect(size.width == 120 && size.height == 90)
    }

    @Test func replayedFramesAreDecodedButNotSentAndTheFirstSentIsAKeyframe() async throws {
        let (sps, pps, units) = try Self.frames()
        let collected = Collected()
        let transcoder = VideoTranscoder(target: .init(width: 160, height: 120, bitrate: 2000, fps: 10, profile: 1), realTime: false) { collected.add($0) }
        for (i, unit) in units.enumerated() { transcoder.push(unit.nalus, sps: sps, pps: pps, time: unit.time, encode: i >= 7) }
        transcoder.finish()
        let frames = collected.all
        #expect(frames.count == 43)
        #expect(frames.first?.keyframe == true)
        #expect(frames.first?.time == units[7].time)
    }

    @Test func theCamerasShapeIsKept() {
        let target = VideoTranscoder.Target(width: 1280, height: 720, bitrate: 299, fps: 30, profile: 1)
        #expect(target.fitting(width: 2560, height: 1920) == (960, 720))   // 4:3 doorbell into 16:9
        #expect(target.fitting(width: 2560, height: 1440) == (1280, 720))
        #expect(target.fitting(width: 640, height: 480) == (640, 480))     // never larger than the camera's
    }

    @Test func aClockLeapIsNotFilledPictureByPicture() throws {
        // A recording's clock leaping 13 hours (a camera's stream opened again on a new clock): at most a few
        // fragments' worth of the last picture again, not one for every 2 s in between (23,400, gigabytes at once).
        let (sps, pps, units) = try Self.frames()
        let collected = Collected()
        let transcoder = VideoTranscoder(target: .init(width: 160, height: 120, bitrate: 500, fps: 10, profile: 1),
                                         realTime: false, keyframeInterval: 2 * 90000) { collected.add($0) }
        let leap: Int64 = 13 * 3600 * 90000
        for (i, unit) in units.enumerated() {
            transcoder.push(unit.nalus, sps: sps, pps: pps, time: unit.time + (i >= 25 ? leap : 0), encode: true)
        }
        transcoder.finish()
        #expect(collected.all.count < 100)
        #expect(collected.all.count > 30)
    }
}
