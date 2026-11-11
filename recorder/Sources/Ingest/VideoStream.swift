// A camera's video, whichever codec it sends: H.264 or H.265 (HEVC). What every reader of a stream uses (the
// recorder, live view, detection, HomeKit's re-encoding), so none of them needs to know which it is: the codec, from
// the stream's description; its parameter sets (H.265's VPS too), from the description and in band; and pictures put
// back together from RTP by the codec's own depacketizer. And, on the Mac, the format description a decoder needs.
import Foundation
#if canImport(CoreMedia)
import CoreMedia
#endif

public enum VideoCodec: String, Sendable, Codable, Equatable {
    case h264, h265

    /// From the description's rtpmap encoding ("H264", "H265"); nil for one Pond can't read.
    public init?(encoding: String) {
        switch encoding.uppercased() {
        case "H264": self = .h264
        case "H265", "HEVC": self = .h265
        default: return nil
        }
    }

    /// As the description names it.
    public var encoding: String { self == .h264 ? "H264" : "H265" }

    /// As people read it.
    public var name: String { self == .h264 ? "H.264" : "H.265 (HEVC)" }
}

/// A picture: its NAL units without start codes, parameter sets and delimiters taken out.
public typealias VideoAccessUnit = H264AccessUnit

/// What a decoder (or an MP4's track header) needs before the pictures: H.264's SPS and PPS, H.265's VPS, SPS and PPS.
public struct ParameterSets: Sendable, Equatable {
    public var codec: VideoCodec
    public var vps: [UInt8]?
    public var sps: [UInt8]
    public var pps: [UInt8]

    public init(codec: VideoCodec, vps: [UInt8]? = nil, sps: [UInt8], pps: [UInt8]) {
        self.codec = codec
        self.vps = vps
        self.sps = sps
        self.pps = pps
    }

    /// In the order a decoder takes them.
    public var all: [[UInt8]] { [vps, sps, pps].compactMap { $0 } }

    /// The picture's size, from the SPS.
    public var size: (width: Int, height: Int)? {
        switch codec {
        case .h264: H264SPS(nal: sps).map { ($0.width, $0.height) }
        case .h265: H265SPS(nal: sps).map { ($0.width, $0.height) }
        }
    }
}

/// RTP to pictures for either codec, as the stream's description says it is.
public struct VideoDepacketizer: Sendable {
    public let codec: VideoCodec
    private var h264: H264Depacketizer
    private var h265: H265Depacketizer

    /// For a stream as its description has it (its codec, and the parameter sets it gives); H.264 if it names
    /// another (the readers that care refuse it first).
    public init(video: SDP.Media) {
        codec = VideoCodec(encoding: video.encoding) ?? .h264
        h264 = H264Depacketizer(spropParameterSets: codec == .h264 ? video.format["sprop-parameter-sets"] : nil)
        h265 = codec == .h265 ? H265Depacketizer(format: video.format) : H265Depacketizer()
    }

    public init(codec: VideoCodec) {
        self.codec = codec
        h264 = H264Depacketizer()
        h265 = H265Depacketizer()
    }

    public mutating func push(_ packet: RTPPacket) -> [VideoAccessUnit] {
        codec == .h264 ? h264.push(packet) : h265.push(packet)
    }

    /// Once all have come (from the description, or in band).
    public var parameterSets: ParameterSets? {
        switch codec {
        case .h264:
            guard let sps = h264.sps, let pps = h264.pps else { return nil }
            return ParameterSets(codec: .h264, sps: sps, pps: pps)
        case .h265:
            guard let vps = h265.vps, let sps = h265.sps, let pps = h265.pps else { return nil }
            return ParameterSets(codec: .h265, vps: vps, sps: sps, pps: pps)
        }
    }

    public var sps: [UInt8]? { codec == .h264 ? h264.sps : h265.sps }
    public var lostPackets: Int { codec == .h264 ? h264.lostPackets : h265.lostPackets }
}

extension RTPPacket {
    /// Whether this packet begins a keyframe (or the parameter sets before one), in either codec.
    public func startsKeyframe(_ codec: VideoCodec) -> Bool {
        guard codec == .h265 else { return startsH264Keyframe }
        guard payload.count >= 3 else { return false }
        let type = H265.type(payload[0])
        switch type {
        case H265.vps, H265.sps: return true
        case H265.aggregation:
            // Its first NAL unit's type (after the payload header and that unit's size).
            guard payload.count >= 5 else { return false }
            let first = H265.type(payload[4])
            return first == H265.vps || first == H265.sps || H265.keyframes.contains(first)
        case H265.fragmentation:
            return payload[2] & 0x80 != 0 && H265.keyframes.contains(payload[2] & 0x3F)
        default:
            return H265.keyframes.contains(type)
        }
    }
}

#if canImport(CoreMedia)
extension ParameterSets {
    /// For VideoToolbox (4-byte NAL lengths, as every reader's samples have them).
    public func formatDescription() -> CMVideoFormatDescription? {
        var format: CMFormatDescription?
        let sets = all
        let pointers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { for p in pointers { p.deallocate() } }
        let sizes = sets.map(\.count)
        let status: OSStatus = pointers.map { UnsafePointer($0) }.withUnsafeBufferPointer { ps in
            sizes.withUnsafeBufferPointer { ss in
                switch codec {
                case .h264:
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                        parameterSetPointers: ps.baseAddress!, parameterSetSizes: ss.baseAddress!,
                                                                        nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                case .h265:
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                        parameterSetPointers: ps.baseAddress!, parameterSetSizes: ss.baseAddress!,
                                                                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                }
            }
        }
        return status == noErr ? format : nil
    }
}
#endif
