import AudioToolbox
import Foundation
import Testing
@testable import HAPCamera

/// The Home app's microphone coming back: its SRTP read, its AAC-ELD frames found and decoded.
@Suite struct TalkbackTests {
    static let key = [UInt8](repeating: 0x11, count: 16), salt = [UInt8](repeating: 0x22, count: 14)

    @Test func srtpFromTheViewerIsReadBack() {
        var sender = SRTPSender(masterKey: Self.key, masterSalt: Self.salt)
        var packetizer = RTPPacketizer(payloadType: 110, ssrc: 0x1234_5678, maxPayload: 1000)
        var receiver = SRTPReceiver(masterKey: Self.key, masterSalt: Self.salt)
        let frames: [[UInt8]] = [[1, 2, 3], [4, 5, 6, 7]]
        let rtp = packetizer.packetize(aac: frames, timestamp: 480)
        let back = receiver.unprotect(sender.protect(rtp: rtp))
        #expect(back == rtp)
        #expect(RTPPacketizer.aacFrames(inPayload: Array(rtp[12...])) == frames)
        // Tampered: turned away.
        var bad = sender.protect(rtp: packetizer.packetize(aac: frames, timestamp: 960))
        bad[14] ^= 1
        #expect(receiver.unprotect(bad) == nil)
    }

    @Test func theSequenceWrappingKeepsItsIndex() {
        var sender = SRTPSender(masterKey: Self.key, masterSalt: Self.salt)
        var receiver = SRTPReceiver(masterKey: Self.key, masterSalt: Self.salt)
        // Sequence numbers from 65530 on, past 65535 (the rollover counter goes to 1 on both sides).
        for sequence in UInt32(65530) ... 65540 {
            let s = UInt16(truncatingIfNeeded: sequence)
            let rtp: [UInt8] = [0x80, 110, UInt8(s >> 8), UInt8(s & 0xFF), 0, 0, 0, 0, 0, 0, 0, 1, 9, 8, 7]
            #expect(receiver.unprotect(sender.protect(rtp: rtp)) == rtp)
        }
    }

    @Test func aacEldIsDecodedAndResampled() throws {
        // A second of a 440 Hz tone at 16 kHz, encoded as the Home app sends it (480-sample ELD frames).
        let rate = 16000
        let tone = (0 ..< rate).map { Int16(8000 * sin(2 * Double.pi * 440 * Double($0) / Double(rate))) }
        let frames = try Self.encodeELD(tone, rate: rate)
        #expect(frames.count >= 30)
        let decoder = try #require(ELDDecoder(sampleRate: rate, outputRate: 8000))
        var out: [Int16] = []
        for frame in frames { out += decoder.decode(frame) }
        // About half as many samples (8 kHz), and the tone is there (not silence).
        #expect(abs(out.count - tone.count / 2) < 1000)
        let loudness = sqrt(out.suffix(4000).reduce(0.0) { $0 + Double($1) * Double($1) } / 4000)
        #expect(loudness > 2000)
    }

    /// 16-bit mono PCM to AAC-ELD frames (as the Home app's encoder makes them).
    static func encodeELD(_ samples: [Int16], rate: Int) throws -> [[UInt8]] {
        var pcm = ELDDecoder.pcm(rate)
        var eld = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0,
                                              mBytesPerPacket: 0, mFramesPerPacket: 480, mBytesPerFrame: 0,
                                              mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&pcm, &eld, &converter) == noErr, let converter else { throw Failure() }
        defer { AudioConverterDispose(converter) }
        final class Source { var bytes: [UInt8]; var held: [UInt8] = []; init(_ b: [UInt8]) { bytes = b } }
        let source = Source(samples.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })
        let input: AudioConverterComplexInputDataProc = { _, count, list, _, user in
            let source = Unmanaged<Source>.fromOpaque(user!).takeUnretainedValue()
            let n = min(Int(count.pointee), source.bytes.count / 2)
            guard n > 0 else { count.pointee = 0; return 0x6E6F_6D6F }
            source.held = Array(source.bytes.prefix(n * 2))
            source.bytes.removeFirst(n * 2)
            count.pointee = UInt32(n)
            source.held.withUnsafeMutableBytes { raw in
                list.pointee.mBuffers.mData = raw.baseAddress
                list.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
                list.pointee.mBuffers.mNumberChannels = 1
            }
            return noErr
        }
        var frames: [[UInt8]] = []
        var out = [UInt8](repeating: 0, count: 1536)
        while true {
            var packets: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = out.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count),
                                                                                    mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, input, Unmanaged.passUnretained(source).toOpaque(),
                                                       &packets, &list, &description)
            }
            guard packets == 1 else { break }
            frames.append(Array(out[Int(description.mStartOffset) ..< Int(description.mStartOffset) + Int(description.mDataByteSize)]))
            if status != noErr { break }
        }
        return frames
    }

    struct Failure: Error {}
}
