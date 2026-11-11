// RTP packets (RFC 3550) and the two payload formats the cameras use: H.264 (RFC 6184) and AAC in
// MPEG4-GENERIC "AAC-hbr" mode (RFC 3640). The depacketizers turn packets back into whole video frames
// (access units) and audio frames, with the RTP timestamp of each.

public struct RTPPacket: Sendable, Equatable {
    public var payloadType: UInt8
    public var marker: Bool
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var payload: [UInt8]

    public init(payloadType: UInt8, marker: Bool, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: [UInt8]) {
        self.payloadType = payloadType
        self.marker = marker
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    public init?(_ d: [UInt8]) {
        guard d.count >= 12, d[0] >> 6 == 2 else { return nil }
        var start = 12 + 4 * Int(d[0] & 0x0F)
        if d[0] & 0x10 != 0 {
            guard d.count >= start + 4 else { return nil }
            start += 4 + 4 * (Int(d[start + 2]) << 8 | Int(d[start + 3]))
        }
        var end = d.count
        if d[0] & 0x20 != 0, let pad = d.last { end -= Int(pad) }
        guard start <= end else { return nil }
        payloadType = d[1] & 0x7F
        marker = d[1] & 0x80 != 0
        sequence = UInt16(d[2]) << 8 | UInt16(d[3])
        timestamp = UInt32(d[4]) << 24 | UInt32(d[5]) << 16 | UInt32(d[6]) << 8 | UInt32(d[7])
        ssrc = UInt32(d[8]) << 24 | UInt32(d[9]) << 16 | UInt32(d[10]) << 8 | UInt32(d[11])
        payload = Array(d[start ..< end])
    }

    /// The packet starts an H.264 keyframe: its SPS, a STAP-A holding the SPS or an IDR slice, or the first
    /// piece (or whole) of an IDR slice.
    public var startsH264Keyframe: Bool {
        guard let first = payload.first else { return false }
        switch first & 0x1F {
        case 7, 5: return true
        case 24:   // STAP-A: each NAL after a 2-byte size
            var at = 1
            while at + 2 < payload.count {
                let size = Int(payload[at]) << 8 | Int(payload[at + 1])
                let type = payload[at + 2] & 0x1F
                if type == 7 || type == 5 { return true }
                at += 2 + size
            }
            return false
        case 28:   // FU-A: the first piece of a fragmented IDR slice
            return payload.count > 1 && payload[1] & 0x80 != 0 && payload[1] & 0x1F == 5
        default: return false
        }
    }
}

/// One H.264 frame: its NAL units without start codes. Parameter sets and access unit delimiters are taken
/// out (they go in the MP4's track header, from `sps`/`pps`).
public struct H264AccessUnit: Sendable, Equatable {
    public var timestamp: UInt32
    public var nalus: [[UInt8]]
    public var isKeyframe: Bool
    /// Packets were lost while this frame arrived; it may show damage until the next keyframe.
    public var damaged: Bool
}

public struct H264Depacketizer: Sendable {
    public private(set) var sps: [UInt8]?
    public private(set) var pps: [UInt8]?
    /// Counts packets missing from the sequence, for logging.
    public private(set) var lostPackets = 0

    private var nalus: [[UInt8]] = []
    private var timestamp: UInt32?
    private var fragment: [UInt8]?
    private var lastSequence: UInt16?
    private var damaged = false

    public init(sps: [UInt8]? = nil, pps: [UInt8]? = nil) {
        self.sps = sps
        self.pps = pps
    }

    /// Parameter sets from the stream description's sprop-parameter-sets, if it has them.
    public init(spropParameterSets: String?) {
        self.init()
        for nal in Self.decodeSprop(spropParameterSets ?? "") { note(nal) }
    }

    static func decodeSprop(_ value: String) -> [[UInt8]] {
        value.split(separator: ",").compactMap { part -> [UInt8]? in
            var b64 = String(part)
            while b64.count % 4 != 0 { b64 += "=" }
            return Data(base64Encoded: b64).map(Array.init)
        }
    }

    /// Adds a packet; returns the frames it completed (usually none or one).
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
        guard let first = p.first else { return done }
        switch first & 0x1F {
        case 1 ... 23:
            nalus.append(p)
        case 24:   // STAP-A
            var i = 1
            while i + 2 <= p.count {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                guard size > 0, i + 2 + size <= p.count else { break }
                nalus.append(Array(p[i + 2 ..< i + 2 + size]))
                i += 2 + size
            }
        case 28:   // FU-A
            guard p.count > 2 else { break }
            let header = p[1]
            if header & 0x80 != 0 {
                fragment = [first & 0xE0 | header & 0x1F] + p[2...]
            } else if fragment != nil {
                fragment! += p[2...]
            }
            if header & 0x40 != 0, let nal = fragment {
                nalus.append(nal)
                fragment = nil
            }
        default:
            break   // STAP-B, MTAP, FU-B: not used by these cameras
        }
        if packet.marker, let unit = finish() { done.append(unit) }
        return done
    }

    private mutating func note(_ nal: [UInt8]) {
        guard let first = nal.first else { return }
        switch first & 0x1F {
        case 7: sps = nal
        case 8: pps = nal
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
            switch first & 0x1F {
            case 7, 8: note(nal)
            case 9: break   // access unit delimiter
            case 5: key = true; kept.append(nal)
            default: kept.append(nal)
            }
        }
        guard !kept.isEmpty else { return nil }
        return H264AccessUnit(timestamp: ts, nalus: kept, isKeyframe: key, damaged: damaged)
    }
}

public struct AACFrame: Sendable, Equatable {
    public var timestamp: UInt32
    public var data: [UInt8]
}

/// RFC 3640 AAC-hbr: a 16-bit AU-headers-length (in bits), the AU headers, then the frames back to back.
/// Each AAC frame is 1024 samples, so the n-th frame in a packet is at timestamp + n * 1024.
public struct AACDepacketizer: Sendable {
    let sizeLength: Int
    let indexLength: Int
    let indexDeltaLength: Int

    public init(format: [String: String]) {
        sizeLength = format["sizelength"].flatMap { Int($0) } ?? 13
        indexLength = format["indexlength"].flatMap { Int($0) } ?? 3
        indexDeltaLength = format["indexdeltalength"].flatMap { Int($0) } ?? 3
    }

    public func push(_ packet: RTPPacket) -> [AACFrame] {
        let p = packet.payload
        guard p.count >= 2 else { return [] }
        let headerBits = Int(p[0]) << 8 | Int(p[1])
        let headerBytes = (headerBits + 7) / 8
        guard p.count >= 2 + headerBytes else { return [] }
        var reader = BitReader(Array(p[2 ..< 2 + headerBytes]))
        var sizes: [Int] = []
        var used = 0
        while used + sizeLength <= headerBits {
            guard let size = reader.bits(sizeLength) else { break }
            let indexBits = sizes.isEmpty ? indexLength : indexDeltaLength
            guard reader.bits(indexBits) != nil else { break }
            used += sizeLength + indexBits
            sizes.append(size)
        }
        var frames: [AACFrame] = []
        var offset = 2 + headerBytes
        for (n, size) in sizes.enumerated() {
            guard offset + size <= p.count else { break }   // a frame split over packets: not used at these sizes
            frames.append(AACFrame(timestamp: packet.timestamp &+ UInt32(n * 1024), data: Array(p[offset ..< offset + size])))
            offset += size
        }
        return frames
    }
}

/// Turns 32-bit RTP timestamps into a 64-bit count that keeps increasing across wrap-around.
public struct TimestampUnwrapper: Sendable {
    private var last: UInt32?
    private var value: Int64 = 0

    public init() {}

    public mutating func unwrap(_ ts: UInt32) -> Int64 {
        if let last { value += Int64(Int32(bitPattern: ts &- last)) } else { value = Int64(ts) }
        last = ts
        return value
    }
}

public enum RTCP {
    /// The sender's packet count from the first sender report in a compound RTCP packet. Zero while
    /// connected means the camera is sending nothing: privacy mode on Reolink.
    public static func senderPacketCount(_ d: [UInt8]) -> UInt32? {
        var i = 0
        while i + 4 <= d.count {
            let length = ((Int(d[i + 2]) << 8 | Int(d[i + 3])) + 1) * 4
            if d[i + 1] == 200, i + 24 <= d.count {
                return UInt32(d[i + 20]) << 24 | UInt32(d[i + 21]) << 16 | UInt32(d[i + 22]) << 8 | UInt32(d[i + 23])
            }
            i += length
        }
        return nil
    }
}

/// Maps a track's RTP timestamps to wall-clock time, from the camera's RTCP sender reports.
public struct RTPClock: Sendable {
    public let rate: Double
    private var reference: (rtp: UInt32, seconds: Double)?

    public init(rate: Int) { self.rate = Double(rate) }

    public var isSynchronized: Bool { reference != nil }

    /// Reads any sender report in an RTCP compound packet.
    public mutating func noteRTCP(_ d: [UInt8]) {
        var i = 0
        while i + 4 <= d.count {
            let length = ((Int(d[i + 2]) << 8 | Int(d[i + 3])) + 1) * 4
            if d[i + 1] == 200, i + 20 <= d.count {
                let ntpSeconds = UInt32(d[i + 8]) << 24 | UInt32(d[i + 9]) << 16 | UInt32(d[i + 10]) << 8 | UInt32(d[i + 11])
                let ntpFraction = UInt32(d[i + 12]) << 24 | UInt32(d[i + 13]) << 16 | UInt32(d[i + 14]) << 8 | UInt32(d[i + 15])
                let rtp = UInt32(d[i + 16]) << 24 | UInt32(d[i + 17]) << 16 | UInt32(d[i + 18]) << 8 | UInt32(d[i + 19])
                // NTP counts from 1900; Unix time from 1970.
                let unix = Double(ntpSeconds) - 2_208_988_800 + Double(ntpFraction) / 4_294_967_296
                reference = (rtp, unix)
            }
            guard length > 0 else { break }
            i += length
        }
    }

    /// Seconds since 1970 for this timestamp, or nil before the first sender report.
    public func wallTime(_ ts: UInt32) -> Double? {
        guard let reference else { return nil }
        return reference.seconds + Double(Int32(bitPattern: ts &- reference.rtp)) / rate
    }
}

import Foundation
