// A camera's health, as Pond sees it (no extra requests to the camera): what happened (incidents: connected,
// stalled, unreachable, private…) and how its video flowed, five minutes at a time (samples: frames, packets
// lost, bytes, keyframes, the camera's clock). The service records them (HealthLog, into the database the
// Health module keeps); the doctor turns them into findings (HealthDiagnosis).
import Foundation

public struct HealthIncident: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Its video started (after connecting, or again after a problem).
        case connected
        /// Video stopped arriving while connected.
        case stalled
        /// It didn't answer (no route, timed out, refused the connection).
        case unreachable
        /// It answered but turned the login down.
        case loginRefused
        /// Any other failure to connect or read.
        case failed
        /// The camera's own privacy mode (it sends nothing).
        case privacyMode
        /// Made private in Pond, and public again.
        case madePrivate, madePublic
        /// A control asked of it failed.
        case controlFailed
        /// The service started (this Mac's side: everything reconnects).
        case serviceStarted
        /// Its own privacy mode turned off, it didn't start its video again in its make's time (its video
        /// server stuck; its controls may still answer).
        case wakeFailed
    }

    public var camera: String
    public var time: Date
    public var kind: Kind
    public var detail: String?

    public init(camera: String, time: Date = Date(), kind: Kind, detail: String? = nil) {
        self.camera = camera
        self.time = time
        self.kind = kind
        self.detail = detail
    }
}

/// How a camera's main stream flowed over five minutes (added to as it goes: several meters' parts make one).
public struct HealthSample: Codable, Equatable, Sendable {
    public static let seconds: TimeInterval = 300

    public var camera: String
    /// The start of its five minutes.
    public var start: Date
    /// Seconds with video arriving.
    public var flowing: Double = 0
    public var frames: Int = 0
    public var keyframes: Int = 0
    /// RTP packets received, and those that never came (gaps in their sequence numbers).
    public var received: Int = 0
    public var lost: Int = 0
    public var bytes: Int = 0
    /// Controls asked of it that worked, and failed.
    public var controlsOK: Int = 0
    public var controlsFailed: Int = 0
    /// The camera's clock less this Mac's, from its sender reports (the latest); nil if it gave none.
    public var clockOffset: Double?

    public init(camera: String, start: Date) {
        self.camera = camera
        self.start = Self.bucket(start)
    }

    /// The five minutes `time` falls in.
    public static func bucket(_ time: Date) -> Date {
        Date(timeIntervalSince1970: (time.timeIntervalSince1970 / seconds).rounded(.down) * seconds)
    }

    public var isEmpty: Bool { flowing == 0 && received == 0 && controlsOK == 0 && controlsFailed == 0 }

    /// Another part of the same five minutes added in.
    public mutating func add(_ other: HealthSample) {
        flowing += other.flowing
        frames += other.frames
        keyframes += other.keyframes
        received += other.received
        lost += other.lost
        bytes += other.bytes
        controlsOK += other.controlsOK
        controlsFailed += other.controlsFailed
        clockOffset = other.clockOffset ?? clockOffset
    }

    public var fps: Double? { flowing > 0 ? Double(frames) / flowing : nil }
    /// Seconds between keyframes, on average.
    public var keyframeInterval: Double? { keyframes > 1 ? flowing / Double(keyframes) : nil }
    public var lossRate: Double? { received + lost > 0 ? Double(lost) / Double(received + lost) : nil }
    public var kilobitsPerSecond: Double? { flowing > 0 ? Double(bytes) * 8 / 1000 / flowing : nil }
}

/// Where the service's health records go (the Health module's store); none outside the service.
public protocol HealthSink: AnyObject, Sendable {
    func record(_ incident: HealthIncident)
    func add(_ sample: HealthSample)
}

/// The service's: everything records here, and it hands on to the sink (if any).
public final class HealthLog: @unchecked Sendable {
    public static let shared = HealthLog()

    private let lock = NSLock()
    private var _sink: HealthSink?

    public var sink: HealthSink? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    public func record(_ camera: String, _ kind: HealthIncident.Kind, _ detail: String? = nil) {
        sink?.record(HealthIncident(camera: camera, kind: kind, detail: detail))
    }

    public func add(_ sample: HealthSample) {
        guard !sample.isEmpty else { return }
        sink?.add(sample)
    }

    /// A control's outcome, counted in its camera's five minutes (and a failure noted).
    public func control(_ camera: String, ok: Bool, action: String, detail: String? = nil) {
        var sample = HealthSample(camera: camera, start: Date())
        if ok { sample.controlsOK = 1 } else { sample.controlsFailed = 1 }
        add(sample)
        if !ok { record(camera, .controlFailed, [action, detail].compactMap { $0 }.joined(separator: ": ")) }
    }
}

/// Measures a stream's video as its packets pass (the recorder's own, so nothing more is asked of the
/// camera), handing over a sample each five minutes.
public struct VideoMeter: Sendable {
    let camera: String
    let videoChannel: UInt8
    private var sample: HealthSample?
    private var lastSequence: UInt16?
    private var lastTimestamp: UInt32?
    private var lastArrival: Date?

    public init(camera: String, videoChannel: UInt8 = 0) {
        self.camera = camera
        self.videoChannel = videoChannel
    }

    /// Video counted as flowing between packets this close together.
    static let flowGap: TimeInterval = 2

    /// One packet (`data` on `channel`, as the camera interleaves them) at `now`; returns a finished sample when
    /// its five minutes are over.
    public mutating func add(channel: UInt8, data: [UInt8], at now: Date = Date()) -> HealthSample? {
        var finished: HealthSample?
        let bucket = HealthSample.bucket(now)
        if let current = sample, current.start != bucket {
            finished = current
            sample = nil
        }
        if sample == nil { sample = HealthSample(camera: camera, start: bucket) }
        if channel == videoChannel + 1 {
            if let offset = Self.clockOffset(rtcp: data, now: now) { sample?.clockOffset = offset }
            return finished
        }
        guard channel == videoChannel, data.count > 12, data[0] >> 6 == 2 else { return finished }
        // Flowing since the last packet, if that was lately.
        if let last = lastArrival, now.timeIntervalSince(last) < Self.flowGap { sample?.flowing += now.timeIntervalSince(last) }
        lastArrival = now
        let sequence = UInt16(data[2]) << 8 | UInt16(data[3])
        if let last = lastSequence {
            let step = Int(sequence &- last)
            // A small step forward: those between never came. (A large one is a restart, not a loss.)
            if step > 1, step < 1000 { sample?.lost += step - 1 }
        }
        lastSequence = sequence
        sample?.received += 1
        sample?.bytes += data.count - 12
        let timestamp = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 | UInt32(data[7])
        if timestamp != lastTimestamp {
            sample?.frames += 1
            lastTimestamp = timestamp
        }
        if Self.startsKeyframe(data) { sample?.keyframes += 1 }
        return finished
    }

    /// What's been measured so far (the connection ending): handed over, and begun afresh.
    public mutating func finish() -> HealthSample? {
        defer {
            sample = nil
            lastSequence = nil
            lastTimestamp = nil
            lastArrival = nil
        }
        return sample
    }

    /// Whether an H.264 RTP packet starts an IDR slice (single NAL type 5, STAP-A holding one, FU-A start).
    static func startsKeyframe(_ d: [UInt8]) -> Bool {
        let csrc = Int(d[0] & 0x0F)
        var offset = 12 + 4 * csrc
        if d[0] & 0x10 != 0, d.count >= offset + 4 { offset += 4 + 4 * (Int(d[offset + 2]) << 8 | Int(d[offset + 3])) }
        guard offset + 1 < d.count else { return false }
        switch d[offset] & 0x1F {
        case 5: return true
        case 28: return d[offset + 1] & 0x80 != 0 && d[offset + 1] & 0x1F == 5
        case 24:
            // STAP-A: a 2-byte size, then each NAL.
            var i = offset + 1
            while i + 2 < d.count {
                let size = Int(d[i]) << 8 | Int(d[i + 1])
                if d[i + 2] & 0x1F == 5 { return true }
                i += 2 + size
            }
            return false
        default: return false
        }
    }

    /// The camera's clock less `now`, from a sender report's NTP time (seconds since 1900); nil if there's none.
    static func clockOffset(rtcp d: [UInt8], now: Date) -> Double? {
        var i = 0
        while i + 4 <= d.count {
            let length = ((Int(d[i + 2]) << 8 | Int(d[i + 3])) + 1) * 4
            if d[i + 1] == 200, i + 16 <= d.count {
                let seconds = UInt32(d[i + 8]) << 24 | UInt32(d[i + 9]) << 16 | UInt32(d[i + 10]) << 8 | UInt32(d[i + 11])
                let fraction = UInt32(d[i + 12]) << 24 | UInt32(d[i + 13]) << 16 | UInt32(d[i + 14]) << 8 | UInt32(d[i + 15])
                guard seconds > 0 else { return nil }
                let unix = Double(seconds) - 2_208_988_800 + Double(fraction) / 4_294_967_296
                return unix - now.timeIntervalSince1970
            }
            guard length > 0 else { break }
            i += length
        }
        return nil
    }
}
