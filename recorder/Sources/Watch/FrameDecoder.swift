// A camera's H.264 pictures decoded one after another (VideoToolbox, on the media engine): as 32BGRA at the
// camera's size (the sub-stream, for the motion gate), or in the decoder's own 4:2:0 scaled down as it decodes
// (the main stream, for a closer look: a 4K picture is 33 MB as 32BGRA, 3 MB as 4:2:0 at 2560 wide). Every
// picture is decoded, as each needs the ones before it; after a damaged one, nothing until the next keyframe.
import CoreMedia
import Foundation
import Ingest
import PondCore
import VideoToolbox

final class FrameDecoder {
    /// What it decodes to: its pixel format, and the largest size (the camera's shape kept; nil: the camera's own).
    let pixelFormat: OSType
    let largest: (width: Int, height: Int)?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameters: ParameterSets?
    private var waitingForKeyframe = true

    init(pixelFormat: OSType = kCVPixelFormatType_32BGRA, largest: (width: Int, height: Int)? = nil) {
        self.pixelFormat = pixelFormat
        self.largest = largest
    }

    /// For a closer look: the decoder's own 4:2:0, at most 2560×1920.
    static func closeUp() -> FrameDecoder {
        FrameDecoder(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, largest: (2560, 1920))
    }

    deinit { close() }

    func close() {
        if let session {
            VTDecompressionSessionInvalidate(session)
            DecoderCount.closed()
        }
        session = nil
        format = nil
        parameters = nil
        waitingForKeyframe = true
    }

    /// An H.264 picture (one access unit), or nil (not decodable yet, or damaged).
    func decode(_ nalus: [[UInt8]], keyframe: Bool, damaged: Bool, sps: [UInt8]?, pps: [UInt8]?) -> CVPixelBuffer? {
        decode(nalus, keyframe: keyframe, damaged: damaged, sets: sps.flatMap { s in pps.map { ParameterSets(codec: .h264, sps: s, pps: $0) } })
    }

    /// The picture in these NAL units (one access unit, H.264 or H.265 as `sets` say), or nil (not decodable yet, or
    /// damaged).
    func decode(_ nalus: [[UInt8]], keyframe: Bool, damaged: Bool, sets: ParameterSets?) -> CVPixelBuffer? {
        if damaged {
            waitingForKeyframe = true
            return nil
        }
        if keyframe, let sets, parameters != sets {
            close()
            guard open(sets) else { return nil }
        }
        if keyframe { waitingForKeyframe = false }
        guard !waitingForKeyframe, let session, let format, let codec = parameters?.codec else { return nil }
        let units = nalus.filter { nal in
            // The parameter sets went into the format.
            guard let first = nal.first else { return false }
            return codec == .h264 ? ![7, 8].contains(first & 0x1F) : !(H265.vps ... H265.pps).contains(H265.type(first))
        }
        guard let sample = Self.sample(units, format: format) else { return nil }
        final class Result: @unchecked Sendable { var buffer: CVPixelBuffer? }
        let result = Result()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            if status == noErr { result.buffer = buffer }
        }
        guard status == noErr else {
            waitingForKeyframe = true
            return nil
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return result.buffer
    }

    private func open(_ sets: ParameterSets) -> Bool {
        guard let format = sets.formatDescription() else { return false }
        var attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        if let largest {
            // Scaled by the decoder as it decodes (no picture at full size made first).
            let camera = CMVideoFormatDescriptionGetDimensions(format)
            let size = Self.fitting(width: Int(camera.width), height: Int(camera.height), within: largest)
            attributes[kCVPixelBufferWidthKey as String] = size.width
            attributes[kCVPixelBufferHeightKey as String] = size.height
        }
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return false }
        DecoderCount.opened()
        self.session = session
        self.format = format
        parameters = sets
        return true
    }

    /// A picture `width`×`height` scaled to fit inside `within`, its shape kept (even sides, never larger).
    static func fitting(width: Int, height: Int, within: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let scale = min(1, min(Double(within.width) / Double(max(1, width)), Double(within.height) / Double(max(1, height))))
        func even(_ v: Double) -> Int { max(2, Int(v.rounded(.down)) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// The NAL units with 4-byte lengths, as a sample.
    static func sample(_ nalus: [[UInt8]], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var bytes: [UInt8] = []
        for nal in nalus {
            let n = UInt32(nal.count)
            bytes += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + nal
        }
        guard !bytes.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block,
              bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                    offsetIntoDestination: 0, dataLength: $0.count) }) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        var size = bytes.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
