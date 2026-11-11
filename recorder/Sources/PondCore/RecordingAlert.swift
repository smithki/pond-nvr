// When Pond's own HomeKit sensor goes off: recording isn't going as it should, for long enough that it isn't a
// camera reconnecting or a segment changing over. A camera not recording (not private, not in its own privacy
// mode) for `cameraAfter`; the recordings drive unusable for `driveAfter`; this Mac going to sleep, at once (it
// records nothing asleep, and can say so only before). What it can't say: this Mac off, or Pond's recorder not
// running (the Home app then shows the sensor as not responding, which it doesn't notify about).
import Foundation

public struct RecordingAlert: Sendable {
    /// What a camera's recorder is doing, as far as the alert cares.
    public enum CameraState: Equatable, Sendable {
        case recording
        /// Not recording, and should be (why, in words).
        case notRecording(String)
        /// Its recordings drive can't be written to.
        case driveUnusable
        /// Not expected to record: private, or its own privacy mode.
        case excused
    }

    public static let cameraAfter: TimeInterval = 300
    public static let driveAfter: TimeInterval = 60

    /// Since when each camera has been in trouble (nil: it isn't).
    private var since: [String: Date] = [:]
    private var driveSince: Date?

    public init() {}

    /// What's wrong now, in words, or nil when all's well: from each camera's (id, name, state) at `now`.
    public mutating func check(_ cameras: [(id: String, name: String, state: CameraState)], now: Date = Date(),
                               asleep: Bool = false) -> String? {
        var down: [String] = []
        var drive = false
        let ids = Set(cameras.map(\.id))
        since = since.filter { ids.contains($0.key) }
        for camera in cameras {
            switch camera.state {
            case .recording, .excused:
                since[camera.id] = nil
            case .driveUnusable:
                since[camera.id] = nil
                drive = true
            case let .notRecording(why):
                let start = since[camera.id] ?? now
                since[camera.id] = start
                if now.timeIntervalSince(start) >= Self.cameraAfter { down.append("\(camera.name) (\(why))") }
            }
        }
        if drive { driveSince = driveSince ?? now } else { driveSince = nil }
        if asleep { return "This Mac is going to sleep: nothing is recorded until it wakes." }
        if let driveSince, now.timeIntervalSince(driveSince) >= Self.driveAfter {
            return "The recordings drive can\u{2019}t be written to: nothing is being recorded."
        }
        guard !down.isEmpty else { return nil }
        return (down.count == 1 ? "Not recording " : "Not recording \(down.count) cameras: ")
            + (down.count == 1 ? down[0] : down.joined(separator: ", ")) + "."
    }
}
