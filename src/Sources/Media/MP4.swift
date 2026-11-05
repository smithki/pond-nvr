// Fragmented MP4 (ISO/IEC 14496-12 and -15), the format recordings are written in: an init segment
// (ftyp + moov, describing the tracks) followed by fragments (moof + mdat), each starting at a keyframe.
// A file cut off mid-write is still playable up to its last whole fragment, and HomeKit Secure Video wants
// exactly this format, so the same writer serves both.

public struct VideoTrack: Sendable, Equatable {
    public var sps: [UInt8]
    public var pps: [UInt8]
    public var width: Int
    public var height: Int
    /// H.265's: its VPS, and what its `hvcC` says of the SPS. Nil: H.264.
    public var hevc: HEVC?
    public static let timescale: UInt32 = 90000

    public init(sps: [UInt8], pps: [UInt8], width: Int, height: Int, hevc: HEVC? = nil) {
        self.sps = sps
        self.pps = pps
        self.width = width
        self.height = height
        self.hevc = hevc
    }

    /// An H.265 track's VPS, and from its SPS: general_profile_tier_level's twelve bytes, chroma format, bit depths and
    /// temporal layers, as `hvcC` carries them.
    public struct HEVC: Sendable, Equatable {
        public var vps: [UInt8]
        public var profileTierLevel: [UInt8]
        public var chromaFormat: Int
        public var bitDepthLuma: Int
        public var bitDepthChroma: Int
        public var temporalLayers: Int
        public var temporalIDNested: Bool

        public init(vps: [UInt8], profileTierLevel: [UInt8], chromaFormat: Int, bitDepthLuma: Int, bitDepthChroma: Int,
                    temporalLayers: Int, temporalIDNested: Bool) {
            self.vps = vps
            self.profileTierLevel = profileTierLevel
            self.chromaFormat = chromaFormat
            self.bitDepthLuma = bitDepthLuma
            self.bitDepthChroma = bitDepthChroma
            self.temporalLayers = temporalLayers
            self.temporalIDNested = temporalIDNested
        }
    }
}

public struct AudioTrack: Sendable, Equatable {
    /// The AAC AudioSpecificConfig, e.g. [0x14, 0x08] for AAC-LC 16 kHz mono.
    public var config: [UInt8]
    public var sampleRate: Int
    public var channels: Int

    public init(config: [UInt8], sampleRate: Int, channels: Int) {
        self.config = config
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public struct MP4Sample: Sendable, Equatable {
    public var data: [UInt8]
    public var duration: UInt32
    public var isSync: Bool

    public init(data: [UInt8], duration: UInt32, isSync: Bool) {
        self.data = data
        self.duration = duration
        self.isSync = isSync
    }
}

public enum MP4 {
    static let videoTrackID: UInt32 = 1
    static let audioTrackID: UInt32 = 2

    // MARK: - Boxes

    static func box(_ type: String, _ parts: [UInt8]...) -> [UInt8] {
        let payload = parts.flatMap { $0 }
        return u32(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }

    static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ parts: [UInt8]...) -> [UInt8] {
        box(type, [version, UInt8(flags >> 16 & 0xFF), UInt8(flags >> 8 & 0xFF), UInt8(flags & 0xFF)] + parts.flatMap { $0 })
    }

    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func u64(_ v: UInt64) -> [UInt8] { u32(UInt32(v >> 32)) + u32(UInt32(v & 0xFFFF_FFFF)) }
    static func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }

    static let matrix: [UInt8] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000].flatMap { u32($0) }

    // MARK: - Init segment

    public static func initSegment(video: VideoTrack, audio: AudioTrack?) -> [UInt8] {
        let ftyp = box("ftyp", Array("isom".utf8), u32(0x200), Array("isomiso6iso2\(video.hevc == nil ? "avc1" : "hvc1")mp41".utf8))
        let nextTrack = audio == nil ? audioTrackID : audioTrackID + 1
        let mvhd = fullBox("mvhd", u32(0), u32(0), u32(1000), u32(0), u32(0x0001_0000), u16(0x0100), zeros(10),
                           matrix, zeros(24), u32(nextTrack))
        var traks = videoTrak(video)
        var trexes = trex(videoTrackID)
        if let audio {
            traks += audioTrak(audio)
            trexes += trex(audioTrackID)
        }
        return ftyp + box("moov", mvhd, traks, box("mvex", trexes))
    }

    static func trex(_ track: UInt32) -> [UInt8] {
        fullBox("trex", u32(track), u32(1), u32(0), u32(0), u32(0))
    }

    static func tkhd(_ track: UInt32, volume: UInt16, width: Int, height: Int) -> [UInt8] {
        fullBox("tkhd", flags: 3, u32(0), u32(0), u32(track), u32(0), u32(0), zeros(8), u16(0), u16(0),
                u16(volume), u16(0), matrix, u32(UInt32(width) << 16), u32(UInt32(height) << 16))
    }

    static func mdia(timescale: UInt32, handler: String, name: String, header: [UInt8], sampleEntry: [UInt8]) -> [UInt8] {
        let mdhd = fullBox("mdhd", u32(0), u32(0), u32(timescale), u32(0), u16(0x55C4), u16(0))   // language "und"
        let hdlr = fullBox("hdlr", u32(0), Array(handler.utf8), zeros(12), Array(name.utf8), [0])
        let dinf = box("dinf", fullBox("dref", u32(1), fullBox("url ", flags: 1)))
        let stbl = box("stbl", fullBox("stsd", u32(1), sampleEntry), fullBox("stts", u32(0)), fullBox("stsc", u32(0)),
                       fullBox("stsz", u32(0), u32(0)), fullBox("stco", u32(0)))
        return box("mdia", mdhd, hdlr, box("minf", header, dinf, stbl))
    }

    static func videoTrak(_ v: VideoTrack) -> [UInt8] {
        let config: [UInt8]
        if let hevc = v.hevc {
            config = box("hvcC", hvcC(v, hevc))
        } else {
            var avcC: [UInt8] = [1, v.sps[1], v.sps[2], v.sps[3], 0xFF, 0xE1] + u16(UInt16(v.sps.count)) + v.sps
                + [1] + u16(UInt16(v.pps.count)) + v.pps
            if [100, 110, 122, 144].contains(v.sps[1]) {
                avcC += [UInt8(0xFC | 1), 0xF8, 0xF8, 0]   // 4:2:0, 8-bit, no SPS extensions
            }
            config = box("avcC", avcC)
        }
        // (hvc1: the parameter sets only in the sample entry, as the pictures have them taken out; what QuickTime plays.)
        let entry = box(v.hevc == nil ? "avc1" : "hvc1", zeros(6), u16(1), zeros(16), u16(UInt16(v.width)), u16(UInt16(v.height)),
                        u32(0x0048_0000), u32(0x0048_0000), u32(0), u16(1), zeros(32), u16(0x18), u16(0xFFFF), config)
        return box("trak", tkhd(videoTrackID, volume: 0, width: v.width, height: v.height),
                   mdia(timescale: VideoTrack.timescale, handler: "vide", name: "Video", header: fullBox("vmhd", flags: 1, zeros(8)),
                        sampleEntry: entry))
    }

    /// The HEVCDecoderConfigurationRecord (ISO/IEC 14496-15 8.3.3): the profile, tier and level, the picture's format,
    /// 4-byte NAL lengths, and the VPS, SPS and PPS an array each.
    static func hvcC(_ v: VideoTrack, _ h: VideoTrack.HEVC) -> [UInt8] {
        var out: [UInt8] = [1] + h.profileTierLevel
        out += [0xF0, 0x00]                                       // min_spatial_segmentation_idc: none
        out += [0xFC]                                             // parallelismType: unknown
        out += [0xFC | UInt8(h.chromaFormat & 3)]
        out += [0xF8 | UInt8((h.bitDepthLuma - 8) & 7), 0xF8 | UInt8((h.bitDepthChroma - 8) & 7)]
        out += u16(0)                                             // avgFrameRate: unknown
        out += [UInt8((h.temporalLayers & 7) << 3) | (h.temporalIDNested ? 0x04 : 0) | 3]
        let arrays: [(UInt8, [UInt8])] = [(32, h.vps), (33, v.sps), (34, v.pps)]
        out += [UInt8(arrays.count)]
        for (type, nal) in arrays { out += [0x80 | type] + u16(1) + u16(UInt16(nal.count)) + nal }
        return out
    }

    static func audioTrak(_ a: AudioTrack) -> [UInt8] {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, UInt8(body.count)] + body }
        let decoderSpecific = descriptor(0x05, a.config)
        let decoderConfig = descriptor(0x04, [0x40, 0x15] + zeros(3) + u32(0) + u32(0) + decoderSpecific)
        let es = descriptor(0x03, u16(0) + [0] + decoderConfig + descriptor(0x06, [0x02]))
        let mp4a = box("mp4a", zeros(6), u16(1), zeros(8), u16(UInt16(a.channels)), u16(16), u16(0), u16(0),
                       u32(UInt32(a.sampleRate) << 16), fullBox("esds", es))
        return box("trak", tkhd(audioTrackID, volume: 0x0100, width: 0, height: 0),
                   mdia(timescale: UInt32(a.sampleRate), handler: "soun", name: "Audio", header: fullBox("smhd", zeros(4)),
                        sampleEntry: mp4a))
    }

    // MARK: - Fragments

    /// One fragment: video samples (the first should be a keyframe) and audio samples covering the same
    /// time, with each track's decode time at the first sample in its own timescale.
    public static func fragment(sequence: UInt32, video: [MP4Sample], videoTime: UInt64,
                                audio: [MP4Sample], audioTime: UInt64) -> [UInt8] {
        func traf(_ track: UInt32, _ samples: [MP4Sample], _ time: UInt64, dataOffset: Int32) -> [UInt8] {
            var run = u32(UInt32(samples.count)) + u32(UInt32(bitPattern: dataOffset))
            for s in samples {
                // sync: sample_depends_on = 2 (no other sample); otherwise depends_on = 1 and non-sync.
                run += u32(s.duration) + u32(UInt32(s.data.count)) + u32(s.isSync ? 0x0200_0000 : 0x0101_0000)
            }
            return box("traf", fullBox("tfhd", flags: 0x02_0000, u32(track)), fullBox("tfdt", version: 1, u64(time)),
                       fullBox("trun", flags: 0x701, run))
        }
        func moof(_ videoOffset: Int32, _ audioOffset: Int32) -> [UInt8] {
            var parts = fullBox("mfhd", u32(sequence))
            if !video.isEmpty { parts += traf(videoTrackID, video, videoTime, dataOffset: videoOffset) }
            if !audio.isEmpty { parts += traf(audioTrackID, audio, audioTime, dataOffset: audioOffset) }
            return box("moof", parts)
        }
        let videoBytes = video.reduce(0) { $0 + $1.data.count }
        let size = moof(0, 0).count   // offsets do not change the size
        let mdatPayload = video.flatMap(\.data) + audio.flatMap(\.data)
        return moof(Int32(size + 8), Int32(size + 8 + videoBytes)) + box("mdat", mdatPayload)
    }

    /// NAL units in the length-prefixed form MP4 stores (4-byte big-endian lengths).
    public static func avcc(_ nalus: [[UInt8]]) -> [UInt8] {
        nalus.flatMap { u32(UInt32($0.count)) + $0 }
    }
}
