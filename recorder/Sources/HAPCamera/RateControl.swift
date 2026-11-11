// How much video a re-encoded HomeKit stream sends, from what the viewer says it receives. The Home app's
// own asks are cautious starting points (about 130 kbit/s at 640×360 for a phone, even at home), far below
// what it can show; so the stream starts at a good quality, and the viewer's RTCP reports steer it: losses
// over 5% cut the rate by 30% (quickly, so a slow link recovers); 8 seconds clean raise it by 20% (slowly, so
// it settles). The picture's size and frame rate follow the rate, so each pixel gets enough bits.
import Foundation

public struct RateControl: Sendable {
    /// kbit/s: where a stream starts (1080p: sharp at once at home; a weak link is cut within 2–3 seconds),
    /// and the bounds it moves within.
    public static let start = 2200, floor = 150, ceiling = 4000
    static let cut = 0.7, raise = 1.2
    static let lossy = 0.05, clean = 0.01
    /// Seconds clean before a raise; between cuts.
    static let settle = 8.0, react = 1.0

    public private(set) var bitrate: Int
    private var lastChange: Date
    private var cleanSince: Date?

    public init(bitrate: Int, at now: Date = Date()) {
        self.bitrate = min(Self.ceiling, max(Self.floor, bitrate))
        lastChange = now
    }

    /// A viewer's report: the share of packets it lost since its last. The new rate if it changes.
    public mutating func report(lost fraction: Double, at now: Date = Date()) -> Int? {
        if fraction > Self.lossy {
            cleanSince = nil
            guard now.timeIntervalSince(lastChange) >= Self.react, bitrate > Self.floor else { return nil }
            return change(to: max(Self.floor, Int(Double(bitrate) * Self.cut)), at: now)
        }
        guard fraction < Self.clean else {
            cleanSince = nil
            return nil
        }
        let since = cleanSince ?? now
        cleanSince = since
        guard now.timeIntervalSince(since) >= Self.settle, now.timeIntervalSince(lastChange) >= Self.settle,
              bitrate < Self.ceiling else { return nil }
        cleanSince = now
        return change(to: min(Self.ceiling, Int(Double(bitrate) * Self.raise)), at: now)
    }

    /// The Home app asks for more than the stream sends (a reconfigure): up to it.
    public mutating func asked(_ kbps: Int, at now: Date = Date()) -> Int? {
        guard kbps > bitrate else { return nil }
        return change(to: min(Self.ceiling, kbps), at: now)
    }

    private mutating func change(to next: Int, at now: Date) -> Int? {
        guard next != bitrate else { return nil }
        bitrate = next
        lastChange = now
        return next
    }

    /// What to encode at `bitrate`: a size that suits it (the camera's picture fitted inside), 30 fps from
    /// 500 kbit/s, else 15 so each frame gets more of them.
    public static func target(bitrate: Int, profile: Int) -> VideoTranscoder.Target {
        let box: (Int, Int) = switch bitrate {
        case 2000...: (1920, 1080)
        case 1000...: (1280, 720)
        case 500...: (960, 540)
        case 250...: (640, 360)
        default: (480, 270)
        }
        return VideoTranscoder.Target(width: box.0, height: box.1, bitrate: bitrate, fps: bitrate >= 500 ? 30 : 15,
                                      profile: profile)
    }
}
