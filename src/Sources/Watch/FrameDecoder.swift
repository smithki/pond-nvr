// A camera's H.264 pictures decoded one after another (VideoToolbox, on the media engine), as 32BGRA. Every
// picture is decoded, as each needs the ones before it; after a damaged one, nothing until the next keyframe.
import CoreMedia
import Foundation
import VideoToolbox

final class FrameDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameters: (sps: [UInt8], pps: [UInt8])?
    private var waitingForKeyframe = true

    deinit { close() }

    func close() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameters = nil
        waitingForKeyframe = true
    }

    /// The picture in these NAL units (one access unit), or nil (not decodable yet, or damaged).
    func decode(_ nalus: [[UInt8]], keyframe: Bool, damaged: Bool, sps: [UInt8]?, pps: [UInt8]?) -> CVPixelBuffer? {
        if damaged {
            waitingForKeyframe = true
            return nil
        }
        if keyframe, let sps, let pps, parameters.map({ $0.sps != sps || $0.pps != pps }) ?? true {
            close()
            guard open(sps: sps, pps: pps) else { return nil }
        }
        if keyframe { waitingForKeyframe = false }
        guard !waitingForKeyframe, let session, let format else { return nil }
        let units = nalus.filter { nal in
            // The parameter sets went into the format.
            guard let first = nal.first else { return false }
            let type = first & 0x1F
            return type != 7 && type != 8
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

    private func open(sps: [UInt8], pps: [UInt8]) -> Bool {
        var format: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: [s.baseAddress!, p.baseAddress!],
                    parameterSetSizes: [s.count, p.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard let format else { return false }
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                          kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return false }
        self.session = session
        self.format = format
        parameters = (sps, pps)
        return true
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
