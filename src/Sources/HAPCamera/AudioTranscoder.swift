// The camera's sound for HomeKit: its AAC-LC frames decoded to PCM, then encoded as AAC-ELD, the codec the
// Home app takes, at the sample rate and bit rate it asked for. Both steps are AudioToolbox converters fed
// on demand: each is handed what has arrived and told "no more for now" when that is used up, which keeps
// its state for the next frames. Each ELD frame is 480 samples (30 ms at 16 kHz), as HomeKit expects.
import AudioToolbox
import Foundation

public final class AudioTranscoder {
    /// Samples per AAC-ELD frame.
    public static let eldFrameLength: UInt32 = 480
    public let outputRate: Int

    private let decoder: AudioConverterRef
    private let encoder: AudioConverterRef
    private let maxOutputPacket: Int
    private let decodeFeed = Feed()
    private let encodeFeed = Feed()

    /// From the camera's AudioSpecificConfig (hex, as in its SDP). Nil if AudioToolbox cannot do it.
    public init?(config hex: String, outputRate: Int, bitrate: Int) {
        let cookie = Self.bytes(hex: hex)
        guard cookie.count >= 2 else { return nil }
        let value = Int(cookie[0]) << 8 | Int(cookie[1])
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let rateIndex = value >> 7 & 0xF
        guard rateIndex < rates.count else { return nil }
        let inputRate = Double(rates[rateIndex])
        let channels = UInt32(max(1, value >> 3 & 0xF))

        // The object type (AAC-LC is 2), rate and channels say all a decoder needs for plain AAC.
        var aac = AudioStreamBasicDescription(
            mSampleRate: inputRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: AudioFormatFlags(value >> 11),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        // Mono 16-bit PCM between the two: HomeKit takes one channel.
        var pcm = AudioStreamBasicDescription(
            mSampleRate: inputRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var eld = AudioStreamBasicDescription(
            mSampleRate: Double(outputRate), mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: Self.eldFrameLength, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0,
            mReserved: 0)

        var dec: AudioConverterRef?
        guard AudioConverterNew(&aac, &pcm, &dec) == noErr, let dec else { return nil }
        var enc: AudioConverterRef?
        guard AudioConverterNew(&pcm, &eld, &enc) == noErr, let enc else {
            AudioConverterDispose(dec)
            return nil
        }
        var rate = UInt32(bitrate)
        AudioConverterSetProperty(enc, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
        var maxPacket: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(enc, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacket)
        decoder = dec
        encoder = enc
        maxOutputPacket = Int(max(maxPacket, 1536))
        self.outputRate = outputRate
    }

    deinit {
        AudioConverterDispose(decoder)
        AudioConverterDispose(encoder)
    }

    /// One AAC-LC frame from the camera in; the AAC-ELD frames that completes out (often none or one).
    public func push(_ frame: [UInt8]) -> [[UInt8]] {
        encodeFeed.pcm += decode(frame)
        return encode()
    }

    private func decode(_ frame: [UInt8]) -> [UInt8] {
        decodeFeed.packet = frame
        var out = [UInt8](repeating: 0, count: 2048 * 2)
        var produced: [UInt8] = []
        while true {
            var frames: UInt32 = 2048
            let status = out.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(decoder, Feed.packetInput, Unmanaged.passUnretained(decodeFeed).toOpaque(),
                                                       &frames, &list, nil)
            }
            produced += out[0 ..< Int(frames) * 2]
            if frames == 0 || status != noErr { break }
        }
        return produced
    }

    private func encode() -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var out = [UInt8](repeating: 0, count: maxOutputPacket)
        while true {
            var packets: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = out.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(encoder, Feed.pcmInput, Unmanaged.passUnretained(encodeFeed).toOpaque(),
                                                       &packets, &list, &description)
            }
            guard packets == 1 else { break }
            let start = Int(description.mStartOffset), count = Int(description.mDataByteSize)
            frames.append(Array(out[start ..< start + count]))
            if status != noErr { break }
        }
        return frames
    }

    static func bytes(hex: String) -> [UInt8] {
        let chars = Array(hex.utf8)
        return stride(from: 0, to: chars.count - 1, by: 2).compactMap {
            UInt8(String(decoding: chars[$0 ... $0 + 1], as: UTF8.self), radix: 16)
        }
    }
}

/// What a converter is fed from, kept alive while it reads it.
private final class Feed {
    /// "No more data for now": the converter keeps its state and is fed again later.
    static let empty: OSStatus = 0x6E6F_6D6F   // 'nomo'

    /// The decoder's one waiting AAC packet.
    var packet: [UInt8]?
    var held: [UInt8] = []
    /// Handed to the converter by address, so it has a fixed one.
    let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    deinit { description.deallocate() }
    /// The encoder's waiting PCM (16-bit mono).
    var pcm: [UInt8] = []

    static let packetInput: AudioConverterComplexInputDataProc = { _, count, list, descriptions, user in
        let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
        guard let packet = feed.packet else {
            count.pointee = 0
            return Feed.empty
        }
        feed.held = packet
        feed.packet = nil
        feed.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                mDataByteSize: UInt32(packet.count))
        count.pointee = 1
        feed.held.withUnsafeMutableBytes { raw in
            list.pointee.mBuffers.mData = raw.baseAddress
            list.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
            list.pointee.mBuffers.mNumberChannels = 1
        }
        descriptions?.pointee = feed.description
        return noErr
    }

    static let pcmInput: AudioConverterComplexInputDataProc = { _, count, list, _, user in
        let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
        let available = feed.pcm.count / 2
        guard available > 0 else {
            count.pointee = 0
            return Feed.empty
        }
        let n = min(Int(count.pointee), available)
        feed.held = Array(feed.pcm[0 ..< n * 2])
        feed.pcm.removeFirst(n * 2)
        count.pointee = UInt32(n)
        feed.held.withUnsafeMutableBytes { raw in
            list.pointee.mBuffers.mData = raw.baseAddress
            list.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
            list.pointee.mBuffers.mNumberChannels = 1
        }
        return noErr
    }
}
