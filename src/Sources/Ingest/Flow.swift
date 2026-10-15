// Watches the packets of one H.264 video track for a few seconds: is video arriving, at what frame rate,
// how far apart are the keyframes, what bitrate. Also recognises privacy mode: the camera's RTCP sender
// reports arrive but say it has sent nothing.
import Foundation

public struct FlowStats: Sendable, Equatable, Codable {
    public var videoPackets: Int
    public var videoBytes: Int
    public var seconds: Double
    public var firstVideoAfter: Double?
    public var fps: Double?
    /// Average seconds between keyframes; nil if fewer than two were seen.
    public var keyframeInterval: Double?
    public var keyframes: Int
    /// The first SPS sent inside the video, for when the stream description leaves it out.
    public var sps: H264SPS?

    public init(videoPackets: Int, videoBytes: Int, seconds: Double, firstVideoAfter: Double?, fps: Double?,
                keyframeInterval: Double?, keyframes: Int, sps: H264SPS?) {
        self.videoPackets = videoPackets
        self.videoBytes = videoBytes
        self.seconds = seconds
        self.firstVideoAfter = firstVideoAfter
        self.fps = fps
        self.keyframeInterval = keyframeInterval
        self.keyframes = keyframes
        self.sps = sps
    }

    public var megabitsPerSecond: Double { seconds > 0 ? Double(videoBytes) * 8 / seconds / 1e6 : 0 }
}

public enum FlowResult: Sendable, Equatable, Codable {
    case flowing(FlowStats)
    /// Sender reports came, saying 0 packets sent: the camera is in privacy mode (or its lens is off).
    case privacyMode
    /// Nothing at all arrived.
    case noVideo
}

public struct FlowAnalyzer: Sendable {
    let rtpChannel: UInt8
    let clockRate: Double
    private var started: Double?
    private var packets = 0
    private var bytes = 0
    private var firstVideo: Double?
    private var lastArrival: Double = 0
    private var currentTimestamp: UInt32?
    private var currentIsKey = false
    /// Timestamps of complete frames, unwrapped to 64 bits, and whether each was a keyframe.
    private var frames: [(ts: Int64, key: Bool)] = []
    private var lastRaw: UInt32?
    private var unwrapped: Int64 = 0
    private var senderReports = 0
    private var senderPacketsMax: UInt32 = 0
    private var sps: H264SPS?

    public init(rtpChannel: UInt8 = 0, clockRate: Int = 90000) {
        self.rtpChannel = rtpChannel
        self.clockRate = Double(clockRate)
    }

    /// One interleaved packet, `at` seconds after PLAY.
    public mutating func add(_ packet: InterleavedPacket, at time: Double) {
        if started == nil { started = 0 }
        lastArrival = max(lastArrival, time)
        if packet.channel == rtpChannel + 1 {
            noteRTCP(packet.data)
            return
        }
        guard packet.channel == rtpChannel, packet.data.count > 12, packet.data[0] >> 6 == 2 else { return }
        let d = packet.data
        let csrcCount = Int(d[0] & 0x0F)
        var offset = 12 + 4 * csrcCount
        if d[0] & 0x10 != 0, d.count >= offset + 4 {   // header extension
            offset += 4 + 4 * (Int(d[offset + 2]) << 8 | Int(d[offset + 3]))
        }
        guard offset < d.count else { return }
        packets += 1
        bytes += d.count - offset
        if firstVideo == nil { firstVideo = time }
        let ts = UInt32(d[4]) << 24 | UInt32(d[5]) << 16 | UInt32(d[6]) << 8 | UInt32(d[7])
        if ts != currentTimestamp {
            if let current = currentTimestamp { frames.append((unwrap(current), currentIsKey)) }
            currentTimestamp = ts
            currentIsKey = false
        }
        let payload = Array(d[offset...])
        if Self.containsIDR(payload) { currentIsKey = true }
        if sps == nil { sps = Self.inBandSPS(payload) }
    }

    private mutating func unwrap(_ ts: UInt32) -> Int64 {
        if let last = lastRaw { unwrapped += Int64(Int32(bitPattern: ts &- last)) } else { unwrapped = Int64(ts) }
        lastRaw = ts
        return unwrapped
    }

    /// RTCP compound packet: look for sender reports (type 200) and their sender packet count.
    private mutating func noteRTCP(_ d: [UInt8]) {
        var i = 0
        while i + 4 <= d.count {
            let type = d[i + 1]
            let length = (Int(d[i + 2]) << 8 | Int(d[i + 3]) + 1) * 4
            if type == 200, i + 28 <= d.count {
                senderReports += 1
                let count = UInt32(d[i + 20]) << 24 | UInt32(d[i + 21]) << 16 | UInt32(d[i + 22]) << 8 | UInt32(d[i + 23])
                senderPacketsMax = max(senderPacketsMax, count)
            }
            guard length > 0 else { break }
            i += length
        }
    }

    /// Whether an H.264 RTP payload carries the start of an IDR slice (single NAL, STAP-A or FU-A start).
    static func containsIDR(_ payload: [UInt8]) -> Bool {
        guard let first = payload.first else { return false }
        switch first & 0x1F {
        case 5:
            return true
        case 24:   // STAP-A: 2-byte sizes, then NAL units
            var i = 1
            while i + 2 < payload.count {
                let size = Int(payload[i]) << 8 | Int(payload[i + 1])
                if payload[i + 2] & 0x1F == 5 { return true }
                i += 2 + size
            }
            return false
        case 28:   // FU-A: the start fragment carries the type
            return payload.count > 1 && payload[1] & 0x80 != 0 && payload[1] & 0x1F == 5
        default:
            return false
        }
    }

    /// An SPS carried whole in this payload (single NAL or inside STAP-A). Fragmented SPSs are not joined:
    /// they are a few dozen bytes, and cameras send them whole.
    static func inBandSPS(_ payload: [UInt8]) -> H264SPS? {
        guard let first = payload.first else { return nil }
        switch first & 0x1F {
        case 7:
            return H264SPS(nal: payload)
        case 24:
            var i = 1
            while i + 2 < payload.count {
                let size = Int(payload[i]) << 8 | Int(payload[i + 1])
                guard i + 2 + size <= payload.count else { return nil }
                if payload[i + 2] & 0x1F == 7 { return H264SPS(nal: Array(payload[i + 2 ..< i + 2 + size])) }
                i += 2 + size
            }
            return nil
        default:
            return nil
        }
    }

    public func result(seconds: Double) -> FlowResult {
        guard packets > 0 else {
            return senderReports > 0 && senderPacketsMax == 0 ? .privacyMode : .noVideo
        }
        var stats = FlowStats(videoPackets: packets, videoBytes: bytes, seconds: seconds, firstVideoAfter: firstVideo,
                              fps: nil, keyframeInterval: nil, keyframes: frames.filter(\.key).count, sps: sps)
        if frames.count >= 3, let first = frames.first, let last = frames.last, last.ts > first.ts {
            stats.fps = Double(frames.count - 1) / (Double(last.ts - first.ts) / clockRate)
        }
        let keys = frames.filter(\.key).map(\.ts)
        if keys.count >= 2, let first = keys.first, let last = keys.last {
            stats.keyframeInterval = Double(last - first) / clockRate / Double(keys.count - 1)
        }
        return .flowing(stats)
    }
}
