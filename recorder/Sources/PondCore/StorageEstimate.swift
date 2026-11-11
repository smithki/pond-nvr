// How long the storage lasts: from the room pond may use on the drive and each camera's rate, the days of
// continuous recording that fit once event clips and snapshots (kept for their own number of days) have
// their share. Pure, for the app to show next to the storage folder.
import Foundation

public struct StorageEstimate: Equatable, Sendable {
    /// Where a camera's rate came from, so the app can say how sure the estimate is.
    public enum Source: Equatable, Sendable {
        /// Its own recordings of the last day.
        case recorded
        /// The video rate seen in its last connection check.
        case checked
        /// Neither yet: a typical rate.
        case assumed
    }

    public struct Camera: Equatable, Sendable {
        public var id: String
        /// Bytes per second of continuous recording.
        public var rate: Double
        public var source: Source

        public init(id: String, rate: Double, source: Source) {
            self.id = id
            self.rate = rate
            self.source = source
        }
    }

    /// A typical main stream (2560×1440 H.264) with sound: about 2.5 Mbit/s.
    public static let typicalRate = 2.5e6 / 8
    /// Until detection runs, events are a stated guess: this many a day per camera, each this long, each
    /// with a snapshot of about this size.
    public static let eventsPerCameraPerDay = 20.0
    public static let eventSeconds = 30.0
    public static let snapshotBytes = 300_000.0

    /// Bytes a day of continuous recording, all cameras.
    public var continuousPerDay: Double
    /// Bytes a day of event clips and snapshots, all cameras (estimated).
    public var eventsPerDay: Double
    /// Bytes set aside for event clips and snapshots over the days they are kept.
    public var eventsReserved: Double
    /// Days of continuous recording that fit.
    public var continuousDays: Double
    /// The weakest source among the cameras' rates.
    public var source: Source

    /// - Parameters:
    ///   - room: bytes pond may use: the drive's free space, plus what pond already keeps there, less the
    ///     reserve to keep free.
    ///   - maxContinuous: the limit on continuous recording, if one is set.
    public init?(cameras: [Camera], room: Double, eventDays: Int, maxContinuous: Double? = nil) {
        guard !cameras.isEmpty else { return nil }
        continuousPerDay = cameras.reduce(0) { $0 + $1.rate } * 86400
        eventsPerDay = cameras.reduce(0) { total, camera in
            total + Self.eventsPerCameraPerDay * (camera.rate * Self.eventSeconds + Self.snapshotBytes)
        }
        eventsReserved = eventsPerDay * Double(eventDays)
        var forContinuous = max(0, room - eventsReserved)
        if let maxContinuous { forContinuous = min(forContinuous, maxContinuous) }
        continuousDays = continuousPerDay > 0 ? forContinuous / continuousPerDay : 0
        source = cameras.contains { $0.source == .assumed } ? .assumed
            : cameras.contains { $0.source == .checked } ? .checked : .recorded
    }

    /// "41 days", "1 day", "18 hours", "40 minutes".
    public static func duration(days: Double) -> String {
        if days >= 2 { return "\(Int(days.rounded(.down))) days" }
        if days >= 1 { return "1 day" }
        let hours = days * 24
        if hours >= 2 { return "\(Int(hours.rounded(.down))) hours" }
        if hours >= 1 { return "1 hour" }
        let minutes = max(1, Int((hours * 60).rounded(.down)))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// "1.8 TB", "37 GB", "850 MB".
    public static func size(_ bytes: Double) -> String {
        if bytes >= 1e12 { return String(format: "%.1f TB", bytes / 1e12) }
        return bytes >= 1e9 ? String(format: "%.0f GB", bytes / 1e9) : String(format: "%.0f MB", bytes / 1e6)
    }
}
