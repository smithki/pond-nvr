import AudioToolbox
import Foundation
import Testing
@testable import HAPCamera

@Suite struct AudioTranscoderTests {
    /// A second of a 440 Hz tone as AAC-LC frames at 16 kHz mono, as a Reolink sends (config "1408").
    static func cameraFrames(seconds: Double = 1) throws -> [[UInt8]] {
        var pcm = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var aac = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var converter: AudioConverterRef?
        #expect(AudioConverterNew(&pcm, &aac, &converter) == noErr)
        let encoder = try #require(converter)
        defer { AudioConverterDispose(encoder) }
        let count = Int(16000 * seconds)
        let samples: [Int16] = (0 ..< count).map { Int16(8000 * sin(2 * Double.pi * 440 * Double($0) / 16000)) }
        let source = Source(samples.withUnsafeBytes { Array($0) })
        var frames: [[UInt8]] = []
        var out = [UInt8](repeating: 0, count: 2048)
        while true {
            var packets: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = out.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(encoder, Source.input, Unmanaged.passUnretained(source).toOpaque(),
                                                       &packets, &list, &description)
            }
            guard packets == 1 else { break }
            let start = Int(description.mStartOffset)
            frames.append(Array(out[start ..< start + Int(description.mDataByteSize)]))
            if status != noErr { break }
        }
        return frames
    }

    final class Source {
        var bytes: [UInt8]
        var held: [UInt8] = []
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        static let input: AudioConverterComplexInputDataProc = { _, count, list, _, user in
            let s = Unmanaged<Source>.fromOpaque(user!).takeUnretainedValue()
            let n = min(Int(count.pointee), s.bytes.count / 2)
            guard n > 0 else { count.pointee = 0; return 0x6E6F_6D6F }
            s.held = Array(s.bytes[0 ..< n * 2])
            s.bytes.removeFirst(n * 2)
            count.pointee = UInt32(n)
            s.held.withUnsafeMutableBytes { raw in
                list.pointee.mBuffers.mData = raw.baseAddress
                list.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
            }
            return noErr
        }
    }

    @Test func cameraAACBecomesELDFrames() throws {
        let input = try Self.cameraFrames(seconds: 2)
        #expect(input.count >= 30)
        let transcoder = try #require(AudioTranscoder(config: "1408", outputRate: 16000, bitrate: 24000))
        let output = input.flatMap { transcoder.push($0) }
        // 2 s at 16 kHz is about 66 frames of 480 samples; the codecs' delays hold a few back.
        #expect(output.count >= 55 && output.count <= 67)
        #expect(output.allSatisfy { !$0.isEmpty && $0.count < 400 })
        // About 24 kbit/s: 90 bytes per 30 ms frame on average, give or take.
        let average = Double(output.reduce(0) { $0 + $1.count }) / Double(output.count)
        #expect(average > 30 && average < 200)
    }

    @Test func resamplesTo24kHz() throws {
        let input = try Self.cameraFrames(seconds: 2)
        let transcoder = try #require(AudioTranscoder(config: "1408", outputRate: 24000, bitrate: 32000))
        let output = input.flatMap { transcoder.push($0) }
        // 2 s at 24 kHz is 100 frames of 480 samples.
        #expect(output.count >= 85 && output.count <= 101)
    }

    @Test func noTranscoderWithoutAConfig() {
        #expect(AudioTranscoder(config: "", outputRate: 16000, bitrate: 24000) == nil)
    }
}
