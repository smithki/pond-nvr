import Foundation
import Testing
@testable import Ingest
#if canImport(VideoToolbox)
import CoreMedia
import CoreVideo
import VideoToolbox
#endif

@Suite struct H265Tests {
    static func packet(_ payload: [UInt8], sequence: UInt16, timestamp: UInt32 = 9000, marker: Bool = true) -> RTPPacket {
        let first: [UInt8] = [0x80, (marker ? 0x80 : 0) | 96, UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        let time: [UInt8] = [UInt8(timestamp >> 24), UInt8(timestamp >> 16 & 0xFF), UInt8(timestamp >> 8 & 0xFF), UInt8(timestamp & 0xFF)]
        let ssrc: [UInt8] = [0, 0, 0, 1]
        return RTPPacket(first + time + ssrc + payload)!
    }

    /// A NAL unit of `type`: its two-byte header, then `body`.
    static func nal(_ type: UInt8, _ body: [UInt8]) -> [UInt8] { [type << 1, 1] + body }

    @Test func anAggregationPacketsUnitsAreTakenApartAndItsParameterSetsKept() {
        let vps = Self.nal(32, [1, 2]), sps = Self.nal(33, [3, 4, 5]), pps = Self.nal(34, [6]), idr = Self.nal(19, [7, 8, 9])
        var payload: [UInt8] = [48 << 1, 1]
        for unit in [vps, sps, pps, idr] { payload += [0, UInt8(unit.count)] + unit }
        var d = H265Depacketizer()
        let units = d.push(Self.packet(payload, sequence: 1))
        #expect(units.count == 1)
        #expect(units.first?.isKeyframe == true)
        #expect(units.first?.nalus == [idr])
        #expect(d.vps == vps && d.sps == sps && d.pps == pps)
        #expect(Self.packet(payload, sequence: 1).startsKeyframe(.h265))
    }

    @Test func aLostFragmentMarksThePictureDamaged() {
        let body = [UInt8](repeating: 0xAB, count: 30)
        let header: [UInt8] = [49 << 1, 1]
        var d = H265Depacketizer()
        _ = d.push(Self.packet(header + [UInt8(0x80 | 1)] + Array(body[0 ..< 10]), sequence: 1, marker: false))
        // (The middle one lost.)
        let units = d.push(Self.packet(header + [UInt8(0x40 | 1)] + Array(body[20...]), sequence: 3))
        #expect(d.lostPackets == 1)
        #expect(units.isEmpty || units.allSatisfy { $0.damaged })
    }

    #if canImport(VideoToolbox)
    /// A few pictures of H.265 from the Mac's own encoder, with their parameter sets.
    static func encoded(width: Int = 1280, height: Int = 720, count: Int = 8) throws -> (sets: [[UInt8]], pictures: [[[UInt8]]]) {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else {
            throw CancellationError()
        }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        final class Out: @unchecked Sendable { var samples: [CMSampleBuffer] = [] }
        let out = Out()
        for i in 0 ..< count {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
            guard let buffer else { throw CancellationError() }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0), Int32(40 + i * 10), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * height)
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * height / 2)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(i), timescale: 15),
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, sample in
                if let sample { out.samples.append(sample) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard let format = out.samples.first.flatMap(CMSampleBufferGetFormatDescription) else { throw CancellationError() }
        var sets: [[UInt8]] = []
        for index in 0 ..< 3 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let pointer { sets.append(Array(UnsafeBufferPointer(start: pointer, count: size))) }
        }
        let pictures = out.samples.map { sample -> [[UInt8]] in
            guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
            var length = 0
            var data: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &data)
            let bytes = UnsafeRawBufferPointer(start: data, count: length)
            var units: [[UInt8]] = []
            var i = 0
            while i + 4 <= length {
                let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
                units.append(Array(bytes[i + 4 ..< i + 4 + n]))
                i += 4 + n
            }
            return units
        }
        return (sets, pictures)
    }

    @Test func theMacsOwnH265ComesBackWholeThroughRTP() throws {
        let (sets, pictures) = try Self.encoded()
        #expect(sets.count == 3)
        var packetizer = H265Packetizer(payloadType: 96, ssrc: 7, maxPayload: 1200)
        var depacketizer = VideoDepacketizer(codec: .h265)
        var units: [VideoAccessUnit] = []
        for (i, picture) in pictures.enumerated() {
            let nalus = i == 0 ? sets + picture : picture
            for bytes in packetizer.packetize(nalus, timestamp: UInt32(i * 6000)) {
                units += depacketizer.push(try #require(RTPPacket(bytes)))
            }
        }
        #expect(units.count == pictures.count)
        #expect(units.first?.isKeyframe == true)
        #expect(units.map(\.nalus) == pictures)
        let found = try #require(depacketizer.parameterSets)
        #expect(found.all == sets)
        #expect(found.size?.width == 1280 && found.size?.height == 720)
        #expect(found.formatDescription() != nil)
        let sps = try #require(H265SPS(nal: sets[1]))
        #expect(sps.profileName == "Main" && sps.bitDepthLuma == 8 && sps.chromaFormat == 1)
    }

    @Test func theFirstPacketOfAKeyframeIsKnownForTheReplay() throws {
        let (sets, pictures) = try Self.encoded(count: 2)
        var packetizer = H265Packetizer(payloadType: 96, ssrc: 7, maxPayload: 1200)
        let first = try #require(packetizer.packetize(sets + pictures[0], timestamp: 0).first.flatMap(RTPPacket.init))
        #expect(first.startsKeyframe(.h265))
        let later = try #require(packetizer.packetize(pictures[1], timestamp: 6000).first.flatMap(RTPPacket.init))
        #expect(!later.startsKeyframe(.h265))
    }
    #endif
}
