// A camera's main stream, decoded only while it's wanted: the watcher asks for it while something moves, for a
// closer look at full resolution. Opened through the StreamHub (the recorder's connection, shared: nothing more
// is asked of the camera), with a replay of the video since its latest keyframe, so a picture is at hand within
// a moment; let go a few seconds after it was last asked for. Only so many decode at once (TapSlots); decoded in
// the decoder's own 4:2:0 at no more than 2560 wide (FrameDecoder.closeUp), whatever the camera's size.
import CoreVideo
import Foundation
import Ingest
import os

final class StreamTap: @unchecked Sendable {
    let url: String
    let username: String
    let password: String
    /// Kept open this long after the last ask.
    static let linger: TimeInterval = 6
    /// A picture older than this isn't the moment being looked at.
    static let fresh: TimeInterval = 0.6

    private let lock = NSLock()
    private var wantedUntil = Date.distantPast
    private var running = false
    private var stopped = false
    private var latest: (picture: CVPixelBuffer, at: Date)?
    /// Its slot taken by a camera following someone: it closes, and opens again when there's room.
    private var yielded = false
    let slots: TapSlots
    /// Not H.264 (or it failed to open): not tried again.
    private var unusable = false

    init(url: String, username: String, password: String, slots: TapSlots = .shared) {
        self.url = url
        self.username = username
        self.password = password
        self.slots = slots
    }

    /// Every tap closed, and none opened, until then (the video decoder holding too much: see VideoMemoryGuard).
    private static let pause = OSAllocatedUnfairLock(initialState: Date.distantPast)
    static func pause(for seconds: TimeInterval) { pause.withLock { $0 = max($0, Date().addingTimeInterval(seconds)) } }
    static var paused: Bool { pause.withLock { Date() < $0 } }
    static func resume() { pause.withLock { $0 = .distantPast } }

    /// Asked for now: its latest picture, if one is fresh; opened (for the next ask) if it isn't running and there's
    /// a slot for it at `priority`. Nil while taps are paused.
    func picture(priority: TapSlots.Priority = .motion) -> CVPixelBuffer? {
        if Self.paused { return nil }
        guard slots.claim(self, priority: priority, yield: { [weak self] in self?.yield() }) else { return nil }
        let (start, idle, current) = lock.withLock { () -> (Bool, Bool, CVPixelBuffer?) in
            wantedUntil = Date().addingTimeInterval(Self.linger)
            yielded = false
            let start = !running && !stopped && !unusable
            if start { running = true }
            let current = latest.flatMap { Date().timeIntervalSince($0.at) < Self.fresh ? $0.picture : nil }
            return (start, !running, current)
        }
        // Not to run (stopped, or not H.264): its slot back.
        if idle { slots.release(self) }
        if start {
            let thread = Thread { [self] in run() }
            thread.name = "tap \(url)"
            thread.qualityOfService = .utility
            thread.start()
        }
        return current
    }

    func stop() { lock.withLock { stopped = true } }

    /// Its slot taken: closed (its thread ends at the next picture).
    private func yield() { lock.withLock { yielded = true; latest = nil } }

    private var wanted: Bool { !Self.paused && lock.withLock { !stopped && !yielded && Date() < wantedUntil } }

    private func run() {
        defer {
            lock.withLock { running = false; latest = nil }
            slots.release(self)
        }
        guard let source = try? StreamHub.shared.open(url: url, username: username, password: password, replay: true) else { return }
        defer { source.close() }
        guard source.video.encoding.uppercased() == "H264" else {
            lock.withLock { unusable = true }
            return
        }
        var depacketizer = H264Depacketizer(spropParameterSets: source.video.format["sprop-parameter-sets"])
        let decoder = FrameDecoder.closeUp()
        defer { decoder.close() }
        while wanted {
            guard let packet = try? source.next(timeout: 1) else {
                // Nothing in a second, or the stream ended: let go (asked again, it opens again).
                return
            }
            guard packet.channel == CameraSession.videoChannel, let rtp = RTPPacket(packet.data) else { continue }
            for unit in depacketizer.push(rtp) {
                // (Each picture's leftovers let go with it, not kept by this thread's pool until the tap closes.)
                autoreleasepool {
                    if let picture = decoder.decode(unit.nalus, keyframe: unit.isKeyframe, damaged: unit.damaged,
                                                    sps: depacketizer.sps, pps: depacketizer.pps) {
                        lock.withLock { latest = (picture, Date()) }
                    }
                }
            }
        }
    }
}
