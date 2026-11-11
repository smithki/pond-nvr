// SRTP and SRTCP (RFC 3711) with AES_CM_128_HMAC_SHA1_80, the suite HomeKit uses for live streams: AES-128
// in counter mode over the payload, and the first 10 bytes of HMAC-SHA1 over the packet as its tag. The
// session keys are derived from the master key and salt the controller sends in Setup Endpoints.
import CommonCrypto
import CryptoKit
import Foundation

enum AESCM {
    /// AES-128 in counter mode from `iv` (the counter is the IV as a 128-bit big-endian number).
    static func keystream(key: [UInt8], iv: [UInt8], count: Int) -> [UInt8] {
        crypt(key: key, iv: iv, [UInt8](repeating: 0, count: count))
    }

    static func crypt(key: [UInt8], iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var cryptor: CCCryptorRef?
        guard CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                      CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
                                      CCModeOptions(kCCModeOptionCTR_BE), &cryptor) == kCCSuccess, let cryptor else { return data }
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        _ = CCCryptorUpdate(cryptor, data, data.count, &out, out.count, &moved)
        return out
    }
}

/// The session keys for one direction of SRTP and SRTCP.
public struct SRTPKeys: Sendable, Equatable {
    public let cipherKey: [UInt8]
    public let authKey: [UInt8]
    public let salt: [UInt8]

    /// RFC 3711 4.3.1, with key derivation rate 0. Labels 0–2 are SRTP's; 3–5, SRTCP's.
    public init(masterKey: [UInt8], masterSalt: [UInt8], rtcp: Bool = false) {
        let base: UInt8 = rtcp ? 3 : 0
        func derive(_ label: UInt8, _ count: Int) -> [UInt8] {
            var x = masterSalt + [0, 0]          // 14 bytes, times 2^16
            x[7] ^= label                        // the label sits just above the 48-bit index
            return AESCM.keystream(key: masterKey, iv: x, count: count)
        }
        cipherKey = derive(base, 16)
        authKey = derive(base + 1, 20)
        salt = derive(base + 2, 14)
    }

    /// The counter block: salt × 2^16, xor SSRC × 2^64, xor index × 2^16.
    func iv(ssrc: UInt32, index: UInt64) -> [UInt8] {
        var iv = salt + [0, 0]
        for i in 0 ..< 4 { iv[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> (24 - 8 * UInt32(i))) }
        for i in 0 ..< 6 { iv[8 + i] ^= UInt8(truncatingIfNeeded: index >> (40 - 8 * UInt64(i))) }
        return iv
    }

    func tag(_ data: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: authKey)).prefix(10))
    }
}

/// Encrypts and signs outgoing RTP packets for one stream (one SSRC).
public struct SRTPSender: Sendable {
    let keys: SRTPKeys
    let rtcpKeys: SRTPKeys
    private var rolloverCounter: UInt32 = 0
    private var lastSequence: UInt16?
    private var rtcpIndex: UInt32 = 0

    public init(masterKey: [UInt8], masterSalt: [UInt8]) {
        keys = SRTPKeys(masterKey: masterKey, masterSalt: masterSalt)
        rtcpKeys = SRTPKeys(masterKey: masterKey, masterSalt: masterSalt, rtcp: true)
    }

    /// An RTP packet (12-byte header, no CSRCs or extension) made SRTP.
    public mutating func protect(rtp packet: [UInt8]) -> [UInt8] {
        let sequence = UInt16(packet[2]) << 8 | UInt16(packet[3])
        if let last = lastSequence, sequence < last, last - sequence > 0x8000 { rolloverCounter &+= 1 }
        lastSequence = sequence
        let ssrc = UInt32(packet[8]) << 24 | UInt32(packet[9]) << 16 | UInt32(packet[10]) << 8 | UInt32(packet[11])
        let headerLength = 12 + 4 * Int(packet[0] & 0x0F)
        let index = UInt64(rolloverCounter) << 16 | UInt64(sequence)
        let encrypted = Array(packet[0 ..< headerLength])
            + AESCM.crypt(key: keys.cipherKey, iv: keys.iv(ssrc: ssrc, index: index), Array(packet[headerLength...]))
        let roc: [UInt8] = [UInt8(rolloverCounter >> 24), UInt8(rolloverCounter >> 16 & 0xFF),
                            UInt8(rolloverCounter >> 8 & 0xFF), UInt8(rolloverCounter & 0xFF)]
        return encrypted + keys.tag(encrypted + roc)
    }

    /// An RTCP packet made SRTCP: encrypted after its first 8 bytes, then E|index and the tag.
    public mutating func protect(rtcp packet: [UInt8]) -> [UInt8] {
        let ssrc = UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16 | UInt32(packet[6]) << 8 | UInt32(packet[7])
        let index = rtcpIndex
        rtcpIndex = (rtcpIndex + 1) & 0x7FFF_FFFF
        let encrypted = Array(packet[0 ..< 8])
            + AESCM.crypt(key: rtcpKeys.cipherKey, iv: rtcpKeys.iv(ssrc: ssrc, index: UInt64(index)), Array(packet[8...]))
        let e = 0x8000_0000 | index
        let trailer: [UInt8] = [UInt8(e >> 24), UInt8(e >> 16 & 0xFF), UInt8(e >> 8 & 0xFF), UInt8(e & 0xFF)]
        return encrypted + trailer + rtcpKeys.tag(encrypted + trailer)
    }
}

/// Reads the viewer's SRTP (its microphone, talking back): checks the tag, then decrypts the payload. Nil if the
/// tag is wrong. The packet index is the sequence number with a rollover count kept as it wraps (RFC 3711 3.3.1).
public struct SRTPReceiver: Sendable {
    let keys: SRTPKeys
    private var rolloverCounter: UInt32 = 0
    private var highest: UInt16?

    public init(masterKey: [UInt8], masterSalt: [UInt8]) {
        keys = SRTPKeys(masterKey: masterKey, masterSalt: masterSalt)
    }

    /// The RTP packet back (header as sent, payload decrypted).
    public mutating func unprotect(_ packet: [UInt8]) -> [UInt8]? {
        guard packet.count >= 12 + 10 else { return nil }
        let headerLength = 12 + 4 * Int(packet[0] & 0x0F)
        guard packet.count >= headerLength + 10 else { return nil }
        let sequence = UInt16(packet[2]) << 8 | UInt16(packet[3])
        // Which rollover this packet belongs to: a sequence far below the highest has wrapped; far above, is late.
        var roc = rolloverCounter
        if let highest {
            if sequence < highest, highest - sequence > 0x8000 { roc &+= 1 }
            else if sequence > highest, sequence - highest > 0x8000, roc > 0 { roc &-= 1 }
        }
        let signed = Array(packet[0 ..< packet.count - 10])
        let rocBytes: [UInt8] = [UInt8(roc >> 24), UInt8(roc >> 16 & 0xFF), UInt8(roc >> 8 & 0xFF), UInt8(roc & 0xFF)]
        guard keys.tag(signed + rocBytes) == Array(packet[packet.count - 10 ..< packet.count]) else { return nil }
        if roc > rolloverCounter || highest.map({ roc == rolloverCounter && sequence > $0 }) ?? true {
            rolloverCounter = roc
            highest = sequence
        }
        let ssrc = UInt32(packet[8]) << 24 | UInt32(packet[9]) << 16 | UInt32(packet[10]) << 8 | UInt32(packet[11])
        let index = UInt64(roc) << 16 | UInt64(sequence)
        return Array(signed[0 ..< headerLength])
            + AESCM.crypt(key: keys.cipherKey, iv: keys.iv(ssrc: ssrc, index: index), Array(signed[headerLength...]))
    }
}

/// Reads the viewer's SRTCP (its reports): checks the tag, then decrypts. Nil if the tag is wrong. HomeKit
/// streams use the same keys both ways.
public struct SRTCPReceiver: Sendable {
    let keys: SRTPKeys

    public init(masterKey: [UInt8], masterSalt: [UInt8]) {
        keys = SRTPKeys(masterKey: masterKey, masterSalt: masterSalt, rtcp: true)
    }

    public func unprotect(_ packet: [UInt8]) -> [UInt8]? {
        guard packet.count >= 8 + 4 + 10 else { return nil }
        let signed = Array(packet[0 ..< packet.count - 10])
        guard keys.tag(signed) == Array(packet[packet.count - 10 ..< packet.count]) else { return nil }
        let trailer = Array(signed[signed.count - 4 ..< signed.count])
        let e = UInt32(trailer[0]) << 24 | UInt32(trailer[1]) << 16 | UInt32(trailer[2]) << 8 | UInt32(trailer[3])
        let body = Array(signed[8 ..< signed.count - 4])
        guard e & 0x8000_0000 != 0 else { return Array(signed[0 ..< 8]) + body }   // not encrypted
        let ssrc = UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16 | UInt32(packet[6]) << 8 | UInt32(packet[7])
        return Array(signed[0 ..< 8])
            + AESCM.crypt(key: keys.cipherKey, iv: keys.iv(ssrc: ssrc, index: UInt64(e & 0x7FFF_FFFF)), body)
    }
}

/// What a receiver says about one stream in its RTCP sender or receiver report (RFC 3550 6.4).
public struct ReceptionReport: Sendable, Equatable {
    public var ssrc: UInt32
    /// Lost since its previous report, out of 256.
    public var fractionLost: UInt8
    public var cumulativeLost: Int32
    public var highestSequence: UInt32

    public var lostShare: Double { Double(fractionLost) / 256 }

    /// The report blocks in a compound RTCP packet.
    public static func parse(_ rtcp: [UInt8]) -> [ReceptionReport] {
        var reports: [ReceptionReport] = []
        var at = 0
        func u32(_ i: Int) -> UInt32 {
            UInt32(rtcp[i]) << 24 | UInt32(rtcp[i + 1]) << 16 | UInt32(rtcp[i + 2]) << 8 | UInt32(rtcp[i + 3])
        }
        while at + 4 <= rtcp.count {
            let count = Int(rtcp[at] & 0x1F)
            let type = rtcp[at + 1]
            let length = (Int(rtcp[at + 2]) << 8 | Int(rtcp[at + 3]) + 1) * 4
            guard at + length <= rtcp.count, length >= 8 else { break }
            // Report blocks follow the sender's SSRC (receiver report) or its sender info (sender report).
            if type == 200 || type == 201 {
                var block = at + (type == 200 ? 28 : 8)
                for _ in 0 ..< count where block + 24 <= at + length {
                    let lost = Int32(bitPattern: (u32(block + 4) & 0x00FF_FFFF) << 8) >> 8
                    reports.append(ReceptionReport(ssrc: u32(block), fractionLost: rtcp[block + 4], cumulativeLost: lost,
                                                   highestSequence: u32(block + 8)))
                    block += 24
                }
            }
            at += length
        }
        return reports
    }
}
