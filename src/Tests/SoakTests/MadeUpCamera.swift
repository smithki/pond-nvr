// A made-up camera's H.264, as a camera sends it: a moving pattern (bands drifting across, a block crossing),
// encoded on the Mac's video hardware at the asked size and frame rate, a keyframe every 2 s, no frame
// reordering. A few seconds of it, played over and over (it starts and ends on a keyframe, so it loops cleanly).
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct MadeUpCamera: Sendable {
    var sps: [UInt8]
    var pps: [UInt8]
    /// Each picture's NAL units, and how long it lasts (90 kHz).
    var units: [(nalus: [[UInt8]], duration: Int64)]

    struct Failed: Error, CustomStringConvertible { var description: String }

    /// `seconds` of video at `width`×`height`, `fps` (a whole number of 2 s groups).
    static func make(width: Int, height: Int, fps: Int = 15, seconds: Int = 4) throws -> MadeUpCamera {
        var session: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: specification, imageBufferAttributes: nil,
                                         compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                         compressionSessionOut: &session) == noErr, let session else {
            throw Failed(description: "no H.264 encoder for \(width)×\(height)")
        }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (width * height * 2) as CFNumber)

        final class Out: @unchecked Sendable {
            let lock = NSLock()
            var samples: [(Int, CMSampleBuffer)] = []
        }
        let out = Out()
        let count = fps * seconds
        for i in 0 ..< count {
            let picture = try pattern(width: width, height: height, step: i, of: count)
            let options = i % (fps * 2) == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(session, imageBuffer: picture, presentationTimeStamp: CMTime(value: Int64(i), timescale: Int32(fps)),
                                            duration: .invalid, frameProperties: options, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample else { return }
                out.lock.withLock { out.samples.append((i, sample)) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let samples = out.lock.withLock { out.samples.sorted { $0.0 < $1.0 }.map(\.1) }
        guard samples.count == count, let format = CMSampleBufferGetFormatDescription(samples[0]) else {
            throw Failed(description: "the encoder gave \(samples.count) of \(count) pictures")
        }
        var sets: [[UInt8]] = []
        for index in 0 ..< 2 {
            var set: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &set,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let set else {
                throw Failed(description: "no parameter sets")
            }
            sets.append([UInt8](UnsafeBufferPointer(start: set, count: size)))
        }
        let duration = Int64(90000 / fps)
        return MadeUpCamera(sps: sets[0], pps: sets[1], units: samples.map { (nalus(of: $0), duration) })
    }

    /// A sample's NAL units (4-byte lengths in, units out).
    static func nalus(of sample: CMSampleBuffer) -> [[UInt8]] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return [] }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        var nalus: [[UInt8]] = []
        var i = 0
        while i + 4 <= bytes.count {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard n > 0, i + n <= bytes.count else { break }
            nalus.append(Array(bytes[i ..< i + n]))
            i += n
        }
        return nalus
    }

    /// One picture of the pattern (4:2:0): bands drifting across, a bright block crossing.
    static func pattern(width: Int, height: Int, step: Int, of count: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &made) == kCVReturnSuccess,
              let picture = made else { throw Failed(description: "no picture \(width)×\(height)") }
        CVPixelBufferLockBaseAddress(picture, [])
        defer { CVPixelBufferUnlockBaseAddress(picture, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(picture, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(picture, 1)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(picture, 0), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(picture, 1)
        let shift = step * 8
        let block = (x: (step * width) / count, y: height / 3, side: height / 4)
        for y in 0 ..< height {
            let row = luma + y * lumaRow
            for x in 0 ..< width {
                let inBlock = x >= block.x && x < block.x + block.side && y >= block.y && y < block.y + block.side
                row[x] = inBlock ? 235 : UInt8(16 + ((x + shift) / 16 % 2) * 60 + (y / 32 % 2) * 40)
            }
        }
        for y in 0 ..< height / 2 {
            let row = chroma + y * chromaRow
            for x in 0 ..< width / 2 { row[2 * x] = UInt8(96 + (x + shift / 2) % 64); row[2 * x + 1] = UInt8(128 + y % 32) }
        }
        return picture
    }
}
