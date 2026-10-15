// A camera's H.264, re-encoded for one HomeKit viewer (a camera's "Re-encoded by Pond" setting): decoded on
// the Mac's video hardware, scaled to fit the size the viewer asked for (keeping the camera's shape), and
// encoded again at the bitrate and frame rate it asked for: no frame reordering (for low delay), a keyframe
// every 2 seconds, and one at once when the viewer joins or asks for something else. The camera's main
// stream goes in, so the picture is far sharper than its small sub-stream at the same bitrate, and it fits
// what the viewer can take (a phone on cellular asks for about 130 kbit/s).
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class VideoTranscoder: @unchecked Sendable {
    /// What the viewer asked for.
    public struct Target: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// kbit/s.
        public var bitrate: Int
        public var fps: Int
        /// HomeKit's profile: 0 baseline, 1 main, 2 high.
        public var profile: Int

        public init(width: Int, height: Int, bitrate: Int, fps: Int, profile: Int) {
            self.width = width
            self.height = height
            self.bitrate = bitrate
            self.fps = fps
            self.profile = profile
        }

        /// The camera's picture scaled to fit inside the asked size, keeping its shape (even sides, never
        /// larger than the camera's own).
        func fitting(width w: Int, height h: Int) -> (width: Int, height: Int) {
            let scale = min(1, min(Double(width) / Double(w), Double(height) / Double(h)))
            func even(_ v: Double) -> Int { max(2, Int(v.rounded(.down)) & ~1) }
            return (even(Double(w) * scale), even(Double(h) * scale))
        }
    }

    /// An encoded frame: its NAL units (SPS and PPS first on a keyframe), whether it is a keyframe, and its
    /// time on the camera's 90 kHz clock.
    public struct Frame: Sendable {
        public var nalus: [[UInt8]]
        public var keyframe: Bool
        public var time: Int64
        /// The size it was encoded at (carried with it, so a reader needn't ask the transcoder, whose lock
        /// may be held while this is handed over).
        public var width = 0
        public var height = 0
    }

    private let lock = NSLock()
    private var target: Target
    private let output: @Sendable (Frame) -> Void
    private var decoder: VTDecompressionSession?
    private var decoderSPS: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var encoder: VTCompressionSession?
    private var encoderSize: (width: Int, height: Int)?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var forceKeyframe = true
    private var lastEncoded: Int64?
    /// Frames come as the camera sends them (the encoder may drop one that comes too soon); off in tests,
    /// which push a whole video at once.
    let realTime: Bool
    /// A keyframe exactly this often (90 kHz units), for recordings cut into fragments of a set length; nil:
    /// every 2 seconds, and whenever asked.
    let keyframeInterval: Int64?

    public init(target: Target, realTime: Bool = true, keyframeInterval: Int64? = nil,
                output: @escaping @Sendable (Frame) -> Void) {
        self.target = target
        self.realTime = realTime
        self.keyframeInterval = keyframeInterval
        self.output = output
    }



    /// Waits for the frames being encoded to come out.
    public func finish() {
        lock.withLock {
            if let encoder { VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid) }
        }
    }

    deinit {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }

    /// Another size, bitrate or frame rate (a reconfigure): a new size makes a new encoder; either way the
    /// next frame is a keyframe.
    public func retarget(_ next: Target) {
        lock.withLock {
            guard next != target else { return }
            if next.width != target.width || next.height != target.height || next.profile != target.profile {
                if let encoder { VTCompressionSessionInvalidate(encoder) }
                encoder = nil
                encoderSize = nil
            } else if let encoder {
                Self.setRate(encoder, next)
            }
            target = next
            forceKeyframe = true
        }
    }

    /// A camera frame (an access unit), decoded; encoded too unless `encode` is false (a replayed frame from
    /// before the viewer joined, decoded only so the frames after it can be).
    public func push(_ nalus: [[UInt8]], sps: [UInt8], pps: [UInt8], time: Int64, encode: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if decoder == nil || sps != decoderSPS { makeDecoder(sps: sps, pps: pps) }
        guard let decoder, let format, let sample = Self.sample(nalus, format: format, time: time) else { return }
        if encode { toEncode.insert(time) }
        // Decoded on this thread before the call returns. Live cameras send frames in order (no B-frames);
        // a frame older than the last one encoded is decoded but not sent.
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [self] status, _, buffer, time, _ in
            guard status == noErr, let buffer else { return }
            decoded(buffer, time: time.convertScale(90000, method: .default).value)
        }
        if status != noErr { toEncode.remove(time) }
    }

    /// Times of frames to encode once decoded (the others are only decoded).
    private var toEncode: Set<Int64> = []

    /// A decoded picture (called under the lock, from inside a decode): encoded if it was asked for and the
    /// viewer's frame rate has room for it.
    private func decoded(_ picture: CVImageBuffer, time: Int64) {
        guard toEncode.remove(time) != nil else { return }
        let spacing = Int64(90000 / max(1, target.fps))
        if let interval = keyframeInterval {
            onClock(picture, time: time, spacing: spacing, interval: interval)
            return
        }
        if let last = lastEncoded, time - last < spacing * 9 / 10 { return }
        lastEncoded = time
        compress(picture, time: time)
    }

    /// For recordings: frames at the asked rate on an exact clock (each slot shows the picture current then,
    /// repeated where the camera is slower), a keyframe on every `interval`; so each fragment is exactly its
    /// length, as the home hub takes it (a maximum: a frame over, and the hub keeps nothing).
    private var held: (picture: CVImageBuffer, from: Int64)?
    private var nextSlot: Int64 = 0
    private var firstSlot: Int64?

    private func onClock(_ picture: CVImageBuffer, time: Int64, spacing: Int64, interval: Int64) {
        if firstSlot == nil {
            firstSlot = time
            nextSlot = time
        }
        // The slots before this picture show the one before it.
        if let held {
            while nextSlot < time {
                if (nextSlot - firstSlot!) % interval == 0 { forceKeyframe = true }
                compress(held.picture, time: nextSlot)
                nextSlot += spacing
            }
        }
        held = (picture, time)
    }

    // MARK: - Decoding

    private func makeDecoder(sps: [UInt8], pps: [UInt8]) {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
        var made: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: [s.baseAddress!, p.baseAddress!],
                    parameterSetSizes: [s.count, p.count], nalUnitHeaderLength: 4, formatDescriptionOut: &made)
            }
        }
        guard let made else { return }
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: made, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr else { return }
        decoder = session
        format = made
        decoderSPS = sps
        forceKeyframe = true
    }

    /// The access unit as a sample buffer: each NAL unit with a 4-byte length, timed on the 90 kHz clock.
    static func sample(_ nalus: [[UInt8]], format: CMVideoFormatDescription, time: Int64) -> CMSampleBuffer? {
        var bytes: [UInt8] = []
        for nal in nalus {
            let n = UInt32(nal.count)
            bytes += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + nal
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block,
              bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                    offsetIntoDestination: 0, dataLength: $0.count) }) == noErr
        else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: time, timescale: 90000),
                                        decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    // MARK: - Encoding

    private func compress(_ picture: CVImageBuffer, time: Int64) {
        let size = target.fitting(width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture))
        if encoder == nil || encoderSize.map({ $0.width != size.width || $0.height != size.height }) ?? true {
            makeEncoder(size)
        }
        guard let encoder, let scaled = scale(picture, to: size) else { return }
        let options: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        forceKeyframe = false
        let output = self.output
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: scaled, presentationTimeStamp: CMTime(value: time, timescale: 90000),
                                        duration: .invalid, frameProperties: options, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, var frame = Self.frame(sample, time: time) else { return }
            frame.width = size.width
            frame.height = size.height
            output(frame)
        }
    }

    private func makeEncoder(_ size: (width: Int, height: Int)) {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        pool = nil
        var session: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
                                         codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                         refcon: nil, compressionSessionOut: &session) == noErr, let session else { return }
        let profile: CFString = switch target.profile {
        case 0: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        case 1: kVTProfileLevel_H264_Main_AutoLevel
        default: kVTProfileLevel_H264_High_AutoLevel
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: realTime ? kCFBooleanTrue : kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Keyframes on our clock when an interval is set (the encoder's own only as a backstop, after it).
        let keyframeSeconds = keyframeInterval.map { Double($0) / 90000 * 1.5 } ?? 2
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: keyframeSeconds as CFNumber)
        Self.setRate(session, target)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        encoderSize = size
        forceKeyframe = true
    }

    /// The asked bitrate on average, and no more than half again over any second, at the asked frame rate.
    static func setRate(_ session: VTCompressionSession, _ target: Target) {
        let bits = max(64, target.bitrate) * 1000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bits as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [bits * 3 / 2 / 8, 1] as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: max(1, target.fps) as CFNumber)
    }

    /// The decoded picture at the encoder's size (the same buffer if it already is).
    private func scale(_ picture: CVImageBuffer, to size: (width: Int, height: Int)) -> CVImageBuffer? {
        if CVPixelBufferGetWidth(picture) == size.width, CVPixelBufferGetHeight(picture) == size.height { return picture }
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            transfer = session
        }
        if pool == nil {
            let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
                              kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
            CVPixelBufferPoolCreate(nil, nil, attributes, &pool)
        }
        guard let transfer, let pool else { return nil }
        var scaled: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled) == kCVReturnSuccess, let scaled,
              VTPixelTransferSessionTransferImage(transfer, from: picture, to: scaled) == noErr else { return nil }
        return scaled
    }

    /// An encoded sample's NAL units (with the SPS and PPS before a keyframe's).
    static func frame(_ sample: CMSampleBuffer, time: Int64) -> Frame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        let bytes = [UInt8](UnsafeRawBufferPointer(start: pointer, count: length))
        var nalus: [[UInt8]] = []
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            for index in 0 ..< 2 {
                var set: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &set,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let set {
                    nalus.append([UInt8](UnsafeBufferPointer(start: set, count: size)))
                }
            }
        }
        var at = 0
        while at + 4 <= bytes.count {
            let n = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            guard n > 0, at + 4 + n <= bytes.count else { break }
            nalus.append(Array(bytes[at + 4 ..< at + 4 + n]))
            at += 4 + n
        }
        return Frame(nalus: nalus, keyframe: keyframe, time: time)
    }
}
