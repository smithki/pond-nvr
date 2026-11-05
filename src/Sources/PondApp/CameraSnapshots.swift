// A still of each camera for the live view's rail: the last frame of its latest recorded segment, read from
// disk (LatestStill), so it needs no connection to the camera (nor its password) and costs nothing while the camera
// is off screen; another Pond's camera's, as its Pond sends it. Refreshed every half minute while the live view is
// open; each says how old it is.
import AVFoundation
import CoreGraphics
import Foundation
import Devices
import ImageIO
import Observation
import Watch

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
        await LatestStill.of(camera: camera, recordings: base, size: size).map { Snapshot(image: $0.image, time: $0.time) }
    }

    /// Other Ponds' cameras' (ids `camera@pond`), as their Ponds send them, through the service.
    func refreshRemote(_ cameras: [String], client: ControlClient) async {
        for camera in cameras {
            guard !Task.isCancelled else { return }
            let reply = await client.ask(.init(camera: camera, action: "remote.still"), timeout: 20)
            guard let data = reply.body, let time = reply.taken,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            snapshots[camera] = Snapshot(image: image, time: time)
            CameraAspect.remember(camera, image)
        }
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
