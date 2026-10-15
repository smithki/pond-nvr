// What the stream description says about the codecs: H.264 resolution and profile from the SPS in
// sprop-parameter-sets, and AAC's AudioSpecificConfig.
import Foundation

public struct H264SPS: Sendable, Equatable, Codable {
    public var profileIDC: Int
    public var levelIDC: Int
    public var width: Int
    public var height: Int

    public init(profileIDC: Int, levelIDC: Int, width: Int, height: Int) {
        self.profileIDC = profileIDC
        self.levelIDC = levelIDC
        self.width = width
        self.height = height
    }

    public var profileName: String {
        switch profileIDC {
        case 66: "Baseline"
        case 77: "Main"
        case 88: "Extended"
        case 100: "High"
        case 110: "High 10"
        case 122: "High 4:2:2"
        case 244: "High 4:4:4"
        default: "profile \(profileIDC)"
        }
    }

    public var levelName: String {
        levelIDC % 10 == 0 ? "\(levelIDC / 10)" : "\(levelIDC / 10).\(levelIDC % 10)"
    }

    /// The first SPS in an a=fmtp sprop-parameter-sets value (base64, comma separated).
    public init?(spropParameterSets: String) {
        for part in spropParameterSets.split(separator: ",") {
            var b64 = String(part)
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64), let first = data.first, first & 0x1F == 7 else { continue }
            if let sps = H264SPS(nal: Array(data)) {
                self = sps
                return
            }
        }
        return nil
    }

    /// Parses an SPS NAL unit (header byte included). Stops before the VUI, which some cameras get wrong.
    public init?(nal: [UInt8]) {
        guard nal.count >= 4, nal[0] & 0x1F == 7 else { return nil }
        let rbsp = Self.removeEmulationPrevention(Array(nal.dropFirst()))
        var r = BitReader(rbsp)
        guard let profile = r.bits(8), r.bits(8) != nil, let level = r.bits(8), r.ue() != nil else { return nil }
        var chroma = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let c = r.ue() else { return nil }
            chroma = c
            if chroma == 3 { _ = r.bits(1) }
            guard r.ue() != nil, r.ue() != nil, r.bits(1) != nil, let scaling = r.bits(1) else { return nil }
            if scaling == 1 {
                for i in 0 ..< (chroma == 3 ? 12 : 8) {
                    guard let present = r.bits(1) else { return nil }
                    if present == 1 {
                        var last = 8, nextScale = 8
                        for _ in 0 ..< (i < 6 ? 16 : 64) {
                            if nextScale != 0 {
                                guard let delta = r.se() else { return nil }
                                nextScale = (last + delta + 256) % 256
                            }
                            last = nextScale == 0 ? last : nextScale
                        }
                    }
                }
            }
        }
        guard r.ue() != nil, let pocType = r.ue() else { return nil }   // log2_max_frame_num_minus4
        if pocType == 0 {
            guard r.ue() != nil else { return nil }
        } else if pocType == 1 {
            guard r.bits(1) != nil, r.se() != nil, r.se() != nil, let n = r.ue() else { return nil }
            for _ in 0 ..< n { guard r.se() != nil else { return nil } }
        }
        guard r.ue() != nil, r.bits(1) != nil,                          // max_num_ref_frames, gaps
              let widthMbs = r.ue(), let heightMaps = r.ue(),
              let frameMbsOnly = r.bits(1) else { return nil }
        if frameMbsOnly == 0 { _ = r.bits(1) }
        guard r.bits(1) != nil, let cropping = r.bits(1) else { return nil }
        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if cropping == 1 {
            guard let l = r.ue(), let rr = r.ue(), let t = r.ue(), let b = r.ue() else { return nil }
            crop = (l, rr, t, b)
        }
        let subWidth = chroma == 1 || chroma == 2 ? 2 : 1
        let subHeight = chroma == 1 ? 2 : 1
        let cropX = chroma == 0 ? 1 : subWidth
        let cropY = (chroma == 0 ? 1 : subHeight) * (2 - frameMbsOnly)
        profileIDC = profile
        levelIDC = level
        width = (widthMbs + 1) * 16 - cropX * (crop.left + crop.right)
        height = (2 - frameMbsOnly) * (heightMaps + 1) * 16 - cropY * (crop.top + crop.bottom)
    }

    static func removeEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for b in bytes {
            if zeros >= 2, b == 3 {
                zeros = 0
                continue
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }
}

struct BitReader {
    let bytes: [UInt8]
    var position = 0   // in bits

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func bits(_ n: Int) -> Int? {
        guard position + n <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0 ..< n {
            value = value << 1 | Int(bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1)
            position += 1
        }
        return value
    }

    /// Unsigned exp-Golomb.
    mutating func ue() -> Int? {
        var zeros = 0
        while true {
            guard let bit = bits(1) else { return nil }
            if bit == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard let rest = bits(zeros) else { return nil }
        return (1 << zeros) - 1 + rest
    }

    /// Signed exp-Golomb.
    mutating func se() -> Int? {
        guard let k = ue() else { return nil }
        return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
    }
}

public struct AACConfig: Sendable, Equatable, Codable {
    public var objectType: Int
    public var sampleRate: Int
    public var channels: Int

    public init(objectType: Int, sampleRate: Int, channels: Int) {
        self.objectType = objectType
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var profileName: String {
        switch objectType {
        case 2: "AAC-LC"
        case 5: "HE-AAC"
        case 23: "AAC-LD"
        case 39: "AAC-ELD"
        default: "AAC (type \(objectType))"
        }
    }

    static let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// From the hex `config` of an MPEG4-GENERIC a=fmtp line, e.g. "1408".
    public init?(hex: String) {
        guard hex.count >= 4, let value = Int(hex.prefix(4), radix: 16) else { return nil }
        objectType = value >> 11
        let index = value >> 7 & 0xF
        guard index < Self.rates.count else { return nil }
        sampleRate = Self.rates[index]
        channels = value >> 3 & 0xF
    }
}
