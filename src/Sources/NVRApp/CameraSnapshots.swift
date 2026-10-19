// A still of each camera for the live view's rail: the last frame of its latest recorded segment, read from
// disk, so it needs no connection to the camera (nor its password) and costs nothing while the camera is
// off screen. Refreshed every half minute while the live view is open; each says how old it is.
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import Recorder

@MainActor
@Observable
final class CameraSnapshots {
    struct Snapshot {
        var image: CGImage
        /// When the frame was recorded.
        var time: Date
    }

    private(set) var snapshots: [String: Snapshot] = [:]

    subscript(camera: String) -> Snapshot? { snapshots[camera] }

    /// Reads the latest frame of each camera, one at a time, off the main thread.
    func refresh(base: String, cameras: [String]) async {
        for camera in cameras {
            guard !Task.isCancelled else { return }
            if let shot = await Self.latest(base: base, camera: camera) {
                snapshots[camera] = shot
                CameraAspect.remember(camera, shot.image)
            }
        }
    }

    nonisolated static func latest(base: String, camera: String, size: CGSize = CGSize(width: 640, height: 360)) async -> Snapshot? {
        let now = Date()
        // Look back a little first, to avoid listing the whole week; further for a camera that has gone
        // quiet, whose old snapshot (and its age) then says so.
        var latest: RecordedSpan?
        for hours: Double in [2, 24, 192] where latest == nil {
            latest = RecordingIndex.spans(base: base, camera: camera, from: now.addingTimeInterval(-hours * 3600), to: now).last
        }
        guard let span = latest else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: span.path))
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = size
        generator.appliesPreferredTrackTransform = true
        let at = CMTime(seconds: max(0, duration.seconds - 0.5), preferredTimescale: 600)
        guard let (image, actual) = try? await generator.image(at: at) else { return nil }
        return Snapshot(image: image, time: span.start.addingTimeInterval(actual.seconds))
    }
}

/// Each camera's picture shape (width over height), as last seen: for a place to show its picture at the right
/// shape before the picture itself has loaded. Kept per Mac (a convenience, not a setting).
enum CameraAspect {
    static func known(_ camera: String) -> Double? {
        let value = UserDefaults.standard.double(forKey: "cameraAspect.\(camera)")
        return value > 0 ? value : nil
    }

    static func remember(_ camera: String, _ image: CGImage) {
        guard image.height > 0 else { return }
        UserDefaults.standard.set(Double(image.width) / Double(image.height), forKey: "cameraAspect.\(camera)")
    }
}
