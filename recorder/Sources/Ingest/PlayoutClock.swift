// When a live view shows each picture: on the camera's own clock, a little behind the fastest its pictures have
// lately arrived, so the camera's uneven delivery doesn't reach the screen. A Wi-Fi camera's big keyframes can take
// half a second to come through, holding up the pictures behind them, which then come all at once: shown as they
// arrive, that's a freeze and a jump every keyframe; shown on the camera's clock, behind by that half second, it's
// smooth. The delay is each stream's own, learnt as it plays: enough to cover how late its pictures came over the
// last few seconds (the worst of them), up at once when they come later, down slowly when they don't, never past
// `cap`. A camera that delivers evenly is shown almost as it arrives.
import Foundation
import Synchronization

public struct PlayoutClock: Sendable {
    /// How far back lateness is looked at.
    public static let window = 10.0
    /// The most a picture is held back.
    public static let cap = 1.0
    /// Beyond the latest lateness seen: room for a little more.
    public static let margin = 0.03
    /// How fast the delay comes down when pictures come more evenly (seconds per second).
    public static let easing = 0.1

    let rate: Double
    /// Each picture's arrival and its time on the camera's clock (seconds, unwrapped), over the window.
    private var recent: [(arrival: Double, media: Double)] = []
    private var lastTimestamp: UInt32?
    private var media = 0.0
    private var lastArrival: Double?
    private var lastShown: Double?
    /// How far behind the fastest arrivals pictures are shown now.
    public private(set) var delay: Double

    public init(rate: Double = 90000, delay: Double = 0) {
        self.rate = rate
        self.delay = min(max(0, delay), Self.cap)
    }

    /// When to show a picture stamped `timestamp` that arrived at `arrival` (both on one clock, in seconds): never
    /// before it arrived, and never before the picture before it.
    public mutating func time(arrival: Double, timestamp: UInt32) -> Double {
        if let lastTimestamp {
            let step = Double(Int32(bitPattern: timestamp &- lastTimestamp)) / rate
            // A jump on the camera's clock (it restarted, or the stream did): learnt afresh from here.
            if abs(step) > 5 { recent = [] }
            media += abs(step) > 5 ? 0 : step
        }
        lastTimestamp = timestamp
        recent.append((arrival, media))
        recent.removeAll { arrival - $0.arrival > Self.window }
        // The fastest path, lately: where the camera's clock sits on ours.
        let offset = recent.map { $0.arrival - $0.media }.min() ?? (arrival - media)
        let worst = recent.map { $0.arrival - $0.media - offset }.max() ?? 0
        let target = min(Self.cap, worst + Self.margin)
        if target > delay {
            delay = target
        } else if let lastArrival {
            delay = max(target, delay - Self.easing * max(0, arrival - lastArrival))
        }
        lastArrival = arrival
        var shown = max(arrival, offset + media + delay)
        if let lastShown { shown = max(shown, lastShown + 0.001) }
        lastShown = shown
        return shown
    }
}

extension PlayoutClock {
    private static let delays = Mutex<[String: Double]>([:])

    /// A stream's delay as last learnt in this process (by its address): where its next view starts.
    public static func learnt(_ url: String) -> Double { delays.withLock { $0[url] ?? 0 } }
    public static func learnt(_ url: String, _ delay: Double) { delays.withLock { $0[url] = delay } }
}
