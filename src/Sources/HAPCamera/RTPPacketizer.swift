// H.264 frames into RTP packets (RFC 6184, non-interleaved mode): a NAL unit that fits is sent whole, a larger
// one is cut into FU-A fragments. SPS and PPS go before each keyframe, so a viewer can start there. The last
// packet of a frame carries the marker bit.
import Foundation

public struct RTPPacketizer: Sendable {
    public let payloadType: UInt8
    public let ssrc: UInt32
    /// Payload bytes per packet at most.
    public let maxPayload: Int
    public private(set) var sequence: UInt16
    public private(set) var packets = 0
    public private(set) var octets = 0

    public init(payloadType: UInt8, ssrc: UInt32, maxPayload: Int, sequence: UInt16 = .random(in: 0 ... .max)) {
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.maxPayload = maxPayload
        self.sequence = sequence
    }

    /// One frame's packets, all with `timestamp` (90 kHz).
    public mutating func packetize(_ nalus: [[UInt8]], timestamp: UInt32) -> [[UInt8]] {
        var payloads: [[UInt8]] = []
        for nal in nalus where !nal.isEmpty {
            if nal.count <= maxPayload {
                payloads.append(nal)
                continue
            }
            // FU-A: indicator (F, NRI, type 28), header (S, E, type), then a slice of the NAL's body.
            let indicator = nal[0] & 0xE0 | 28
            let type = nal[0] & 0x1F
            var offset = 1
            let chunk = maxPayload - 2
            while offset < nal.count {
                let end = min(offset + chunk, nal.count)
                var header = type
                if offset == 1 { header |= 0x80 }
                if end == nal.count { header |= 0x40 }
                payloads.append([indicator, header] + nal[offset ..< end])
                offset = end
            }
        }
        return payloads.enumerated().map { i, payload in
            packet(payload, timestamp: timestamp, marker: i == payloads.count - 1)
        }
    }

    /// AAC frames in one packet (RFC 3640, AAC-hbr): a 16-bit AU-headers-length (in bits), an AU header per
    /// frame (13-bit size, 3-bit index 0), then the frames. The timestamp is the first frame's; the marker is set.
    public mutating func packetize(aac frames: [[UInt8]], timestamp: UInt32) -> [UInt8] {
        let headersLength = UInt16(frames.count * 16)
        var payload: [UInt8] = [UInt8(headersLength >> 8), UInt8(headersLength & 0xFF)]
        for frame in frames {
            let header = UInt16(frame.count) << 3
            payload += [UInt8(header >> 8), UInt8(header & 0xFF)]
        }
        for frame in frames { payload += frame }
        return packet(payload, timestamp: timestamp, marker: true)
    }

    public mutating func packetize(aac frame: [UInt8], timestamp: UInt32) -> [UInt8] {
        packetize(aac: [frame], timestamp: timestamp)
    }

    /// The AAC frames in an RTP payload made as `packetize(aac:)` makes it (RFC 3640, AAC-hbr: 13-bit sizes).
    public static func aacFrames(inPayload payload: [UInt8]) -> [[UInt8]] {
        guard payload.count >= 2 else { return [] }
        let headerBits = Int(payload[0]) << 8 | Int(payload[1])
        let headers = (headerBits + 7) / 8
        guard payload.count >= 2 + headers else { return [] }
        var frames: [[UInt8]] = []
        var at = 2 + headers
        for i in stride(from: 2, to: 2 + headers - 1, by: 2) {
            let size = (Int(payload[i]) << 8 | Int(payload[i + 1])) >> 3
            guard size > 0, at + size <= payload.count else { break }
            frames.append(Array(payload[at ..< at + size]))
            at += size
        }
        return frames
    }

    private mutating func packet(_ payload: [UInt8], timestamp: UInt32, marker: Bool) -> [UInt8] {
        let header: [UInt8] = [
            0x80, (marker ? 0x80 : 0) | payloadType & 0x7F,
            UInt8(sequence >> 8), UInt8(sequence & 0xFF),
            UInt8(timestamp >> 24), UInt8(timestamp >> 16 & 0xFF), UInt8(timestamp >> 8 & 0xFF), UInt8(timestamp & 0xFF),
            UInt8(ssrc >> 24), UInt8(ssrc >> 16 & 0xFF), UInt8(ssrc >> 8 & 0xFF), UInt8(ssrc & 0xFF),
        ]
        sequence &+= 1
        packets += 1
        octets += payload.count
        return header + payload
    }

    /// An RTCP sender report for this stream: wall time, the RTP time it corresponds to, and the counts so far.
    public func senderReport(rtpTimestamp: UInt32, at date: Date = Date()) -> [UInt8] {
        let ntp = date.timeIntervalSince1970 + 2_208_988_800
        let seconds = UInt32(ntp)
        let fraction = UInt32((ntp - Double(seconds)) * 4_294_967_296)
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        return [0x80, 200, 0, 6] + be(ssrc) + be(seconds) + be(fraction) + be(rtpTimestamp)
            + be(UInt32(truncatingIfNeeded: packets)) + be(UInt32(truncatingIfNeeded: octets))
    }
}
