// The last few seconds of a camera's main stream, kept for HomeKit Secure Video: a recording the home hub asks
// for starts this far before the motion that set it off. Read from the shared camera connection (StreamHub),
// the one the recorder reads, so no more of the camera's connections; kept as the camera sent it (no decoding
// until a recording wants it), from the keyframe at or before the time asked for.
import Foundation
import Ingest

public final class Prebuffer: @unchecked Sendable {
    /// A video frame: its NAL units, on the camera's clock unwrapped (90 kHz), and its wall time.
    public struct Video: Sendable {
        public var nalus: [[UInt8]]
        public var keyframe: Bool
        public var sps: [UInt8]
        public var pps: [UInt8]
        public var time: Int64
        public var wall: Double
    }

    /// An AAC frame: on the audio clock unwrapped (the sample rate), and its wall time.
    public struct Audio: Sendable {
        public var data: [UInt8]
        public var time: Int64
        public var wall: Double
    }

    public enum Item: Sendable {
        case video(Video)
        case audio(Audio)

        var wall: Double {
            switch self {
            case let .video(v): v.wall
            case let .audio(a): a.wall
            }
        }
    }

    let source: (url: String, username: String, password: String)
    /// Seconds kept: what a recording may ask for, and a keyframe's worth more.
    let seconds: Double
    let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var items: [Item] = []
    private var listeners: [UUID: @Sendable (Item) -> Void] = [:]
    private var stopped = false
    private var pausedWhen: @Sendable () -> Bool = { false }
    /// Not to be read just now (the camera is private): the stream let go and what was kept dropped, until it
    /// may be read again.
    public var paused: @Sendable () -> Bool {
        get { lock.withLock { pausedWhen } }
        set { lock.withLock { pausedWhen = newValue } }
    }
    /// The camera's sound (its AAC AudioSpecificConfig as hex), once the stream is open.
    public private(set) var audioConfig: String?

    public init(source: (url: String, username: String, password: String), seconds: Double,
                log: @escaping @Sendable (String) -> Void) {
        self.source = source
        self.seconds = seconds
        self.log = log
    }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "prebuffer \(source.url)"
        thread.qualityOfService = .utility
        thread.start()
    }

    public func stop() { lock.withLock { stopped = true } }

    var isStopped: Bool { lock.withLock { stopped } }

    /// What is kept from `back` seconds ago (from the keyframe at or before then), and then everything that
    /// comes, to `listener`, until `unsubscribe`. In one go, so nothing is missed or given twice.
    public func subscribe(back: Double, _ listener: @escaping @Sendable (Item) -> Void) -> (backlog: [Item], token: UUID) {
        lock.withLock {
            let token = UUID()
            listeners[token] = listener
            let from = (items.last?.wall ?? 0) - back
            // The last keyframe at or before `from` (or the first kept, if none is that old).
            var start = 0
            for (i, item) in items.enumerated() {
                if case let .video(v) = item, v.keyframe {
                    if v.wall <= from { start = i } else { break }
                }
            }
            return (Array(items[start...]), token)
        }
    }

    public func unsubscribe(_ token: UUID) {
        _ = lock.withLock { listeners.removeValue(forKey: token) }
    }

    private func run() {
        var pause = 2.0
        while !isStopped {
            if paused() {
                lock.withLock { items = [] }
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            if read() { pause = 2 }
            if paused() { continue }
            let until = Date().addingTimeInterval(pause)
            while !isStopped, Date() < until { Thread.sleep(forTimeInterval: 0.2) }
            pause = min(pause * 2, 30)
        }
    }

    /// Reads the stream until it fails or the buffer stops; true if anything came.
    private func read() -> Bool {
        guard let session = try? StreamHub.shared.open(url: source.url, username: source.username, password: source.password)
        else { return false }
        defer { session.close() }
        var depacketizer = H264Depacketizer(spropParameterSets: session.video.format["sprop-parameter-sets"])
        let aac = session.audio.map { AACDepacketizer(format: $0.format) }
        lock.withLock { audioConfig = session.audio?.format["config"] }
        var videoClock = RTPClock(rate: session.video.clockRate > 0 ? session.video.clockRate : 90000)
        var audioClock = session.audio.map { RTPClock(rate: $0.clockRate > 0 ? $0.clockRate : 16000) }
        var videoUnwrap = TimestampUnwrapper(), audioUnwrap = TimestampUnwrapper()
        var any = false
        let paused = self.paused
        while !isStopped, !paused() {
            guard let packet = try? session.next(timeout: 1) else { return any }
            let now = Date().timeIntervalSince1970
            switch packet.channel {
            case CameraSession.videoChannel + 1:
                videoClock.noteRTCP(packet.data)
            case CameraSession.audioChannel + 1:
                audioClock?.noteRTCP(packet.data)
            case CameraSession.videoChannel:
                guard let rtp = RTPPacket(packet.data) else { continue }
                for unit in depacketizer.push(rtp) where !unit.damaged {
                    guard let sps = depacketizer.sps, let pps = depacketizer.pps else { continue }
                    any = true
                    keep(.video(Video(nalus: unit.nalus, keyframe: unit.isKeyframe, sps: sps, pps: pps,
                                      time: videoUnwrap.unwrap(unit.timestamp),
                                      wall: videoClock.wallTime(unit.timestamp) ?? now)))
                }
            case CameraSession.audioChannel:
                guard let aac, let rtp = RTPPacket(packet.data) else { continue }
                for frame in aac.push(rtp) {
                    keep(.audio(Audio(data: frame.data, time: audioUnwrap.unwrap(frame.timestamp),
                                      wall: audioClock?.wallTime(frame.timestamp) ?? now)))
                }
            default:
                break
            }
        }
        return any
    }

    /// Kept, and handed to those reading; the oldest goes once a later keyframe is old enough.
    func keep(_ item: Item) {
        let listening = lock.withLock { () -> [@Sendable (Item) -> Void] in
            items.append(item)
            let cutoff = item.wall - seconds
            if let keep = items.lastIndex(where: { if case let .video(v) = $0 { v.keyframe && v.wall <= cutoff } else { false } }),
               keep > 0 {
                items.removeFirst(keep)
            }
            return Array(listeners.values)
        }
        for listener in listening { listener(item) }
    }
}
