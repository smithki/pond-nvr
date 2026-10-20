// One connection per camera stream, shared. A camera serves only a few RTSP clients at once, so the
// recorder, HomeKit's live view and its snapshots all read the same session: the first to open a stream
// connects it, a reader thread hands every packet to each one reading it, and the last to close it hangs up.
// A reader that joins late can ask for a replay: the packets since the latest keyframe come first (marked
// `replayed`), so its picture starts at once instead of at the next keyframe; for live views and snapshots,
// not the recorder (which would record them twice).
// When the camera drops, every reader is told and opens again, which connects again.
import Foundation

/// What reads a camera stream: a `CameraSession` of its own, or a share of one (`StreamHub`).
public protocol PacketSource: AnyObject {
    var video: SDP.Media { get }
    var audio: SDP.Media? { get }
    /// The next packet, or nil if none arrived within `timeout` seconds.
    func next(timeout: Double) throws(RTSPError) -> InterleavedPacket?
    func close()
}

extension CameraSession: PacketSource {}

public final class StreamHub: @unchecked Sendable {
    public static let shared = StreamHub()

    private let lock = NSLock()
    private var upstreams: [String: Upstream] = [:]
    /// Opens a camera connection; tests replace it.
    let connect: (String, String, String) throws(RTSPError) -> PacketSource

    public init(connect: @escaping (String, String, String) throws(RTSPError) -> PacketSource = { url, user, password throws(RTSPError) in
        try CameraSession(url: url, username: user, password: password)
    }) {
        self.connect = connect
    }

    /// Reads the stream at `url` (with its sound, if any), sharing the connection if one is open. With
    /// `replay`, a late reader first gets the video since the latest keyframe, marked as replayed.
    public func open(url: String, username: String, password: String, replay: Bool = false) throws(RTSPError) -> PacketSource {
        while true {
            let upstream = lock.withLock {
                if let u = upstreams[url], !u.isFinished { return u }
                let u = Upstream(url: url, hub: self)
                upstreams[url] = u
                return u
            }
            // Nil: it finished meanwhile (its last reader left, or connecting failed); take a fresh one.
            if let source = try upstream.subscribe(username: username, password: password, replay: replay) { return source }
        }
    }

    /// How many readers share the stream at `url` now.
    public func readers(of url: String) -> Int {
        lock.withLock { upstreams[url].map { $0.isFinished ? 0 : $0.count } ?? 0 }
    }

    fileprivate func finished(_ upstream: Upstream) {
        lock.withLock { if upstreams[upstream.url] === upstream { upstreams[upstream.url] = nil } }
    }
}

/// One camera connection and the readers of it.
private final class Upstream: @unchecked Sendable {
    let url: String
    weak var hub: StreamHub?
    private let condition = NSCondition()
    private var session: PacketSource?
    private var connecting = false
    private var readers: [ObjectIdentifier: Subscription] = [:]
    private var finished = false
    var isFinished: Bool { condition.withLock { finished } }
    /// The video since the latest keyframe, for a reader joining late (H.264 only). Emptied if it outgrows
    /// `cacheLimit` (a long gap between keyframes), until the next one.
    private var cache: [InterleavedPacket] = []
    private var cachedKeyframe: UInt32?
    private var caches = false
    static let cacheLimit = 2500

    init(url: String, hub: StreamHub) {
        self.url = url
        self.hub = hub
    }

    var count: Int { condition.withLock { readers.count } }

    /// A share of the stream, connecting it if this is the first reader; nil if it has finished.
    func subscribe(username: String, password: String, replay: Bool) throws(RTSPError) -> PacketSource? {
        condition.lock()
        // Another reader is connecting it: wait for that.
        while connecting { condition.wait() }
        if finished {
            condition.unlock()
            return nil
        }
        if let session {
            let s = Subscription(upstream: self, video: session.video, audio: session.audio)
            // Under the lock the reader thread caches and hands out under: each packet is either in this
            // replay or delivered to it live, never both or neither.
            if replay { for p in cache { s.deliver(InterleavedPacket(channel: p.channel, data: p.data, replayed: true)) } }
            readers[ObjectIdentifier(s)] = s
            condition.unlock()
            return s
        }
        connecting = true
        condition.unlock()
        let opened: PacketSource
        do throws(RTSPError) {
            guard let hub else { throw .malformed("the stream hub is gone") }
            opened = try hub.connect(url, username, password)
        } catch {
            // Those waiting find it finished and try for themselves.
            condition.withLock {
                connecting = false
                finished = true
                condition.broadcast()
            }
            hub?.finished(self)
            throw error
        }
        let s = Subscription(upstream: self, video: opened.video, audio: opened.audio)
        condition.withLock {
            session = opened
            connecting = false
            caches = opened.video.encoding.uppercased() == "H264"
            readers[ObjectIdentifier(s)] = s
            condition.broadcast()
        }
        // Only the reader thread uses the session from here on.
        nonisolated(unsafe) let source = opened
        let reader = Thread { [self] in read(source) }
        reader.name = "stream \(url)"
        reader.qualityOfService = .userInitiated
        reader.start()
        return s
    }

    /// Hands every packet to every reader until the last one leaves or the camera fails.
    private func read(_ session: PacketSource) {
        var left: [Subscription] = []
        var error: RTSPError?
        while true {
            // Finishing under the same lock that sees no readers, so none can join a closing stream.
            let anyone = condition.withLock { () -> Bool in
                if readers.isEmpty {
                    finished = true
                    self.session = nil
                    return false
                }
                return true
            }
            guard anyone else { break }
            do throws(RTSPError) {
                if let packet = try session.next(timeout: 0.5) {
                    // Cached and handed out in one go, under the lock a joining reader takes.
                    let readers = condition.withLock { () -> [Subscription] in
                        remember(packet)
                        return Array(self.readers.values)
                    }
                    for r in readers { r.deliver(packet) }
                }
            } catch let e {
                error = e
                left = condition.withLock {
                    finished = true
                    self.session = nil
                    defer { readers.removeAll() }
                    return Array(readers.values)
                }
                break
            }
        }
        session.close()
        // Readers still there learn why; they open again, which connects again.
        if let error { for r in left { r.fail(error) } }
        hub?.finished(self)
    }

    /// Keeps the video since the latest keyframe (called under the lock).
    private func remember(_ packet: InterleavedPacket) {
        guard caches, packet.channel == CameraSession.videoChannel, let rtp = RTPPacket(packet.data) else { return }
        if rtp.startsH264Keyframe, cachedKeyframe != rtp.timestamp {
            cache = [packet]
            cachedKeyframe = rtp.timestamp
        } else if !cache.isEmpty {
            cache.append(packet)
            if cache.count > Self.cacheLimit {
                cache = []
                cachedKeyframe = nil
            }
        }
    }

    func leave(_ s: Subscription) {
        condition.withLock { _ = readers.removeValue(forKey: ObjectIdentifier(s)) }
    }
}

/// One reader's share: packets queue up for it until read (the oldest dropped if it falls far behind).
private final class Subscription: PacketSource, @unchecked Sendable {
    let video: SDP.Media
    let audio: SDP.Media?
    private weak var upstream: Upstream?
    private let condition = NSCondition()
    private var queue: [InterleavedPacket] = []
    private var head = 0
    private var failure: RTSPError?
    private var closed = false
    /// About 20 s of a main stream: a reader that slow has stalled anyway.
    static let limit = 4000

    init(upstream: Upstream, video: SDP.Media, audio: SDP.Media?) {
        self.upstream = upstream
        self.video = video
        self.audio = audio
    }

    func deliver(_ packet: InterleavedPacket) {
        condition.withLock {
            guard !closed else { return }
            queue.append(packet)
            if queue.count - head > Self.limit { head += 1 }
            if head > 1024 {
                queue.removeFirst(head)
                head = 0
            }
            condition.signal()
        }
    }

    func fail(_ error: RTSPError) {
        condition.withLock {
            failure = error
            condition.broadcast()
        }
    }

    func next(timeout: Double) throws(RTSPError) -> InterleavedPacket? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while head == queue.count, failure == nil, !closed {
            if !condition.wait(until: deadline) { break }
        }
        if head < queue.count {
            let packet = queue[head]
            head += 1
            return packet
        }
        if let failure { throw failure }
        return nil
    }

    func close() {
        condition.withLock {
            closed = true
            queue.removeAll()
            head = 0
            condition.broadcast()
        }
        upstream?.leave(self)
    }
}
