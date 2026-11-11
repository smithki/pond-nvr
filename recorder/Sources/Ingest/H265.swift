// H.265 (HEVC) over RTP, as RFC 7798 carries it: single NAL units, aggregation packets (48) and fragmentation
// units (49), each NAL unit with a two-byte header (its type in bits 1–6 of the first byte). A picture is complete at
// the marker bit, or when the timestamp moves on, as with H.264. Keyframes are IRAP pictures (types 16–21: BLA, IDR,
// CRA); the parameter sets (VPS 32, SPS 33, PPS 34) are kept apart, as H.264's are, for the MP4's track header and
// the decoder. And what's needed of the SPS: the picture's size, and its profile, tier and level for `hvcC`.
import Foundation

public enum H265 {
    /// A NAL unit's type, from its header's first byte.
    @inline(__always) public static func type(_ first: UInt8) -> UInt8 { (first >> 1) & 0x3F }

    public static let vps: UInt8 = 32, sps: UInt8 = 33, pps: UInt8 = 34, accessUnitDelimiter: UInt8 = 35
    public static let aggregation: UInt8 = 48, fragmentation: UInt8 = 49
    /// IRAP pictures: decodable on their own.
    public static let keyframes: ClosedRange<UInt8> = 16 ... 21
}

public struct H265Depacketizer: Sendable {
    public private(set) var vps: [UInt8]?
    public private(set) var sps: [UInt8]?
    public private(set) var pps: [UInt8]?
    public private(set) var lostPackets = 0

    private var nalus: [[UInt8]] = []
    private var timestamp: UInt32?
    private var fragment: [UInt8]?
    private var lastSequence: UInt16?
    private var damaged = false

    public init(vps: [UInt8]? = nil, sps: [UInt8]? = nil, pps: [UInt8]? = nil) {
        self.vps = vps
        self.sps = sps
        self.pps = pps
    }

    /// Parameter sets from the stream description's sprop-vps, sprop-sps and sprop-pps, if it has them.
    public init(format: [String: String]) {
        self.init()
        for key in ["sprop-vps", "sprop-sps", "sprop-pps"] {
            for nal in H264Depacketizer.decodeSprop(format[key] ?? "") { note(nal) }
        }
    }

    public mutating func push(_ packet: RTPPacket) -> [H264AccessUnit] {
        var done: [H264AccessUnit] = []
        if let last = lastSequence, packet.sequence != last &+ 1 {
            lostPackets += Int(packet.sequence &- last &- 1)
            fragment = nil
            damaged = true
        }
        lastSequence = packet.sequence
        if let ts = timestamp, ts != packet.timestamp, let unit = finish() { done.append(unit) }
        timestamp = packet.timestamp

        let p = packet.payload
        guard p.count >= 2 else { return done }
        switch H265.type(p[0]) {
        case 0 ... 47:
            nalus.append(p)
        case H265.aggregation:
            // (No DONL: sprop-max-don-diff isn't used by cameras.)
            var i = 2
            while i + 2 <= p.count {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                guard size > 0, i + 2 + size <= p.count else { break }
                nalus.append(Array(p[i + 2 ..< i + 2 + size]))
                i += 2 + size
            }
        case H265.fragmentation:
            guard p.count > 3 else { break }
            let header = p[2]
            if header & 0x80 != 0 {
                // The NAL unit's own header, put back: the payload header's F bit and layer, the fragment's type.
                fragment = [p[0] & 0x81 | (header & 0x3F) << 1, p[1]] + p[3...]
            } else if fragment != nil {
                fragment! += p[3...]
            }
            if header & 0x40 != 0, let nal = fragment {
                nalus.append(nal)
                fragment = nil
            }
        default:
            break   // PACI and the rest: not used by cameras
        }
        if packet.marker, let unit = finish() { done.append(unit) }
        return done
    }

    private mutating func note(_ nal: [UInt8]) {
        guard let first = nal.first else { return }
        switch H265.type(first) {
        case H265.vps: vps = nal
        case H265.sps: sps = nal
        case H265.pps: pps = nal
        default: break
        }
    }

    private mutating func finish() -> H264AccessUnit? {
        defer {
            nalus = []
            fragment = nil
            damaged = false
        }
        guard let ts = timestamp else { return nil }
        var kept: [[UInt8]] = []
        var key = false
        for nal in nalus {
            guard let first = nal.first else { continue }
            let type = H265.type(first)
            switch type {
            case H265.vps, H265.sps, H265.pps: note(nal)
            case H265.accessUnitDelimiter: break
            default:
                if H265.keyframes.contains(type) { key = true }
                kept.append(nal)
            }
        }
        guard !kept.isEmpty else { return nil }
        return H264AccessUnit(timestamp: ts, nalus: kept, isKeyframe: key, damaged: damaged)
    }
}

/// What's needed of an H.265 SPS: the picture's size, and for an MP4's `hvcC` its profile, tier and level (the
/// twelve bytes of general_profile_tier_level as they are), chroma format, bit depths and temporal layers.
public struct H265SPS: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var profileTierLevel: [UInt8]
    public var chromaFormat: Int
    public var bitDepthLuma: Int
    public var bitDepthChroma: Int
    public var maxSubLayers: Int
    public var temporalIDNesting: Bool

    public var profileIDC: Int { Int(profileTierLevel[0] & 0x1F) }
    public var levelIDC: Int { Int(profileTierLevel[11]) }

    public var profileName: String {
        switch profileIDC {
        case 1: "Main"
        case 2: "Main 10"
        case 3: "Main Still Picture"
        case 4: "Range Extensions"
        default: "profile \(profileIDC)"
        }
    }

    /// Its level as people write it: level_idc is 30 × the level ("5.1" is 153).
    public var levelName: String {
        let tenths = levelIDC / 3
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
    }

    /// Parses an SPS NAL unit (its two-byte header included), as far as the bit depths.
    public init?(nal: [UInt8]) {
        guard nal.count >= 15, H265.type(nal[0]) == H265.sps else { return nil }
        let rbsp = H264SPS.removeEmulationPrevention(Array(nal.dropFirst(2)))
        guard rbsp.count >= 13 else { return nil }
        var r = BitReader(rbsp)
        guard r.bits(4) != nil, let subLayers = r.bits(3), let nesting = r.bits(1) else { return nil }
        maxSubLayers = subLayers + 1
        temporalIDNesting = nesting == 1
        // general_profile_tier_level: 12 bytes, kept as they are.
        profileTierLevel = Array(rbsp[1 ..< 13])
        for _ in 0 ..< 12 { guard r.bits(8) != nil else { return nil } }
        // The sub-layers' presence flags, padding to eight, then what each has.
        var present: [(profile: Bool, level: Bool)] = []
        for _ in 0 ..< subLayers {
            guard let p = r.bits(1), let l = r.bits(1) else { return nil }
            present.append((p == 1, l == 1))
        }
        if subLayers > 0 { for _ in subLayers ..< 8 { guard r.bits(2) != nil else { return nil } } }
        for layer in present {
            if layer.profile { for _ in 0 ..< 11 { guard r.bits(8) != nil else { return nil } } }
            if layer.level { guard r.bits(8) != nil else { return nil } }
        }
        guard r.ue() != nil, let chroma = r.ue() else { return nil }   // sps_seq_parameter_set_id, chroma_format_idc
        if chroma == 3 { _ = r.bits(1) }
        guard let w = r.ue(), let h = r.ue(), let window = r.bits(1) else { return nil }
        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if window == 1 {
            guard let l = r.ue(), let rr = r.ue(), let t = r.ue(), let b = r.ue() else { return nil }
            crop = (l, rr, t, b)
        }
        guard let luma = r.ue(), let chromaDepth = r.ue() else { return nil }
        let subWidth = chroma == 1 || chroma == 2 ? 2 : 1, subHeight = chroma == 1 ? 2 : 1
        width = w - subWidth * (crop.left + crop.right)
        height = h - subHeight * (crop.top + crop.bottom)
        chromaFormat = chroma
        bitDepthLuma = luma + 8
        bitDepthChroma = chromaDepth + 8
    }
}

/// H.265 into RTP packets: each NAL unit whole if it fits, else in fragmentation units; the marker on a picture's
/// last packet. (For demo mode's made-up cameras, which send it as a camera would.)
public struct H265Packetizer: Sendable {
    public let payloadType: UInt8
    public let ssrc: UInt32
    public let maxPayload: Int
    public private(set) var sequence: UInt16
    /// Sent so far, for sender reports.
    public private(set) var packets = 0
    public private(set) var octets = 0

    public init(payloadType: UInt8, ssrc: UInt32, maxPayload: Int, sequence: UInt16 = .random(in: 0 ... .max)) {
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.maxPayload = maxPayload
        self.sequence = sequence
    }

    public mutating func packetize(_ nalus: [[UInt8]], timestamp: UInt32) -> [[UInt8]] {
        var payloads: [[UInt8]] = []
        for nal in nalus where nal.count > 2 {
            if nal.count <= maxPayload {
                payloads.append(nal)
                continue
            }
            let type = H265.type(nal[0])
            let header: [UInt8] = [nal[0] & 0x81 | H265.fragmentation << 1, nal[1]]
            var at = 2
            while at < nal.count {
                let end = min(nal.count, at + maxPayload - 3)
                let fu = (at == 2 ? 0x80 : 0) | (end == nal.count ? 0x40 : 0) | type
                payloads.append(header + [fu] + nal[at ..< end])
                at = end
            }
        }
        packets += payloads.count
        octets += payloads.reduce(0) { $0 + $1.count }
        return payloads.enumerated().map { i, payload in
            defer { sequence &+= 1 }
            let marker: UInt8 = i == payloads.count - 1 ? 0x80 : 0
            return [0x80, marker | payloadType, UInt8(sequence >> 8), UInt8(sequence & 0xFF),
                    UInt8(timestamp >> 24), UInt8(timestamp >> 16 & 0xFF), UInt8(timestamp >> 8 & 0xFF), UInt8(timestamp & 0xFF),
                    UInt8(ssrc >> 24), UInt8(ssrc >> 16 & 0xFF), UInt8(ssrc >> 8 & 0xFF), UInt8(ssrc & 0xFF)] + payload
        }
    }
}
