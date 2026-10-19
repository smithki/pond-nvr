// A camera's main stream, decoded only while it's wanted: the watcher asks for it while something moves, for a
// closer look at full resolution. Opened through the StreamHub (the recorder's connection, shared: nothing more
// is asked of the camera), with a replay of the video since its latest keyframe, so a picture is at hand within
// a moment; let go a few seconds after it was last asked for.
import CoreVideo
import Foundation
import Ingest

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
    /// Not H.264 (or it failed to open): not tried again.
    private var unusable = false

    init(url: String, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }

    /// Asked for now: its latest picture, if one is fresh; opened (for the next ask) if it isn't running.
    func picture() -> CVPixelBuffer? {
        let (start, current) = lock.withLock { () -> (Bool, CVPixelBuffer?) in
            wantedUntil = Date().addingTimeInterval(Self.linger)
            let start = !running && !stopped && !unusable
            if start { running = true }
            let current = latest.flatMap { Date().timeIntervalSince($0.at) < Self.fresh ? $0.picture : nil }
            return (start, current)
        }
        if start {
            let thread = Thread { [self] in run() }
            thread.name = "tap \(url)"
            thread.qualityOfService = .utility
            thread.start()
        }
        return current
    }

    func stop() { lock.withLock { stopped = true } }

    private var wanted: Bool { lock.withLock { !stopped && Date() < wantedUntil } }

    private func run() {
        defer { lock.withLock { running = false; latest = nil } }
        guard let source = try? StreamHub.shared.open(url: url, username: username, password: password, replay: true) else { return }
        defer { source.close() }
        guard source.video.encoding.uppercased() == "H264" else {
            lock.withLock { unusable = true }
            return
        }
        var depacketizer = H264Depacketizer(spropParameterSets: source.video.format["sprop-parameter-sets"])
        let decoder = FrameDecoder()
        defer { decoder.close() }
        while wanted {
            guard let packet = try? source.next(timeout: 1) else {
                // Nothing in a second, or the stream ended: let go (asked again, it opens again).
                return
            }
            guard packet.channel == CameraSession.videoChannel, let rtp = RTPPacket(packet.data) else { continue }
            for unit in depacketizer.push(rtp) {
                if let picture = decoder.decode(unit.nalus, keyframe: unit.isKeyframe, damaged: unit.damaged,
                                                sps: depacketizer.sps, pps: depacketizer.pps) {
                    lock.withLock { latest = (picture, Date()) }
                }
            }
        }
    }
}
