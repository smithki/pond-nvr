// A demo camera's sound, as a camera's microphone gives it: AAC-LC, mono, 16 kHz, a frame (1024 samples, 64 ms) at
// a time. Made up from the scene: a hush of wind by day and a quieter one at night, birds now and then by day and
// crickets after dark, the low rumble of a car going by, and a doorbell's chime as it's pressed. A room indoors is
// nearly silent. Encoded by AudioToolbox, fed as asked (each frame's samples handed over, then "no more for now").
import AudioToolbox
import Foundation
import PondCore

final class DemoSound {
    static let rate = 16000.0
    static let frameLength = 1024
    /// Its AudioSpecificConfig, as the stream's description gives it: AAC-LC (2), 16 kHz (index 8), one channel.
    static let config = "1408"

    let camera: Demo.Camera
    let world: DemoWorld
    private let encoder: AudioConverterRef
    private let maxPacket: Int
    private let feed = SoundFeed()
    private var random = DemoRandom(seed: "sound")
    /// The wind's noise, low-passed from one sample to the next (brown noise).
    private var wind = 0.0, rumble = 0.0

    init?(camera: Demo.Camera, world: DemoWorld) {
        self.camera = camera
        self.world = world
        random = DemoRandom(seed: "sound/\(camera.id)")
        var pcm = AudioStreamBasicDescription(
            mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var aac = AudioStreamBasicDescription(
            mSampleRate: Self.rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.frameLength), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var made: AudioConverterRef?
        guard AudioConverterNew(&pcm, &aac, &made) == noErr, let made else { return nil }
        var bitrate: UInt32 = 32000
        AudioConverterSetProperty(made, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        var largest: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(made, kAudioConverterPropertyMaximumOutputPacketSize, &size, &largest)
        encoder = made
        maxPacket = Int(max(largest, 1536))
    }

    deinit { AudioConverterDispose(encoder) }

    /// The frames made from the sound starting at `t` (one frame's worth of samples in: usually one frame out).
    func frames(at t: Date) -> [[UInt8]] {
        feed.pcm += samples(at: t).flatMap { s in [UInt8(truncatingIfNeeded: s), UInt8(truncatingIfNeeded: s >> 8)] }
        var frames: [[UInt8]] = []
        var out = [UInt8](repeating: 0, count: maxPacket)
        while true {
            var packets: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = out.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(encoder, SoundFeed.input, Unmanaged.passUnretained(feed).toOpaque(),
                                                       &packets, &list, &description)
            }
            guard packets == 1 else { break }
            let start = Int(description.mStartOffset), count = Int(description.mDataByteSize)
            frames.append(Array(out[start ..< start + count]))
            if status != noErr { break }
        }
        return frames
    }

    /// A frame's samples, from what's happening at `t`.
    func samples(at t: Date) -> [Int16] {
        let (daylight, _, _) = world.light(camera.id, at: t)
        let indoors = camera.scene == .livingRoom
        let figures = world.figures(camera.id, at: t)
        // How near a passing car is (its size in the picture), for its rumble.
        let car = figures.filter { $0.visitor?.detected.category == .vehicle && $0.moving }.map(\.height).max() ?? 0
        let chime = DemoScript.rings(scenario: world.scenario.name, camera: camera, busyness: world.scenario.busyness,
                                     from: t.addingTimeInterval(-1.6), to: t).first.map { t.timeIntervalSince($0) }
        let windLevel = indoors ? 60.0 : 500 + 900 * daylight
        let start = t.timeIntervalSince1970
        var out = [Int16](repeating: 0, count: Self.frameLength)
        for i in 0 ..< Self.frameLength {
            let s = start + Double(i) / Self.rate
            wind = wind * 0.995 + (random.uniform(-1, 1)) * 0.1
            rumble = rumble * 0.98 + random.uniform(-1, 1) * 0.2
            var v = wind * windLevel + rumble * car * 9000
            if !indoors {
                if daylight > 0.3 {
                    // A bird: a chirp of a few rising notes, every few seconds.
                    let cycle = s.truncatingRemainder(dividingBy: 5.3)
                    if cycle < 0.45 {
                        let note = cycle.truncatingRemainder(dividingBy: 0.15)
                        if note < 0.09 { v += sin(2 * .pi * (2600 + 9000 * note) * note) * 1400 * daylight * sin(.pi * note / 0.09) }
                    }
                } else {
                    // Crickets: quick pulses of a high note.
                    let pulse = s.truncatingRemainder(dividingBy: 0.6)
                    if pulse < 0.12, pulse.truncatingRemainder(dividingBy: 0.03) < 0.018 { v += sin(2 * .pi * 4400 * s) * 500 * (1 - daylight) }
                }
            }
            // The chime: two notes, the second as the first fades.
            if let since = chime.map({ $0 + Double(i) / Self.rate }), since >= 0, since < 1.6 {
                let (pitch, began) = since < 0.5 ? (659.25, 0.0) : (523.25, 0.5)
                v += sin(2 * .pi * pitch * since) * 6000 * exp(-(since - began) * 2.5)
            }
            out[i] = Int16(max(-32000, min(32000, v)))
        }
        return out
    }
}

/// What the encoder's fed from, kept alive while it reads it.
private final class SoundFeed {
    /// "No more data for now": the converter keeps its state and is fed again later.
    static let empty: OSStatus = 0x6E6F_6D6F   // 'nomo'
    var pcm: [UInt8] = []
    var held: [UInt8] = []

    static let input: AudioConverterComplexInputDataProc = { _, count, list, _, user in
        let feed = Unmanaged<SoundFeed>.fromOpaque(user!).takeUnretainedValue()
        let available = feed.pcm.count / 2
        guard available > 0 else {
            count.pointee = 0
            return SoundFeed.empty
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
