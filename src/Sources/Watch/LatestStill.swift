// A camera's latest picture, from its recordings: the last frame of its newest segment, read from disk, so it needs no
// connection to the camera. The app's camera rail shows them; another Pond is sent them (the remote API's `still`).
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Recorder

public enum LatestStill {
    /// The picture, and when it was recorded; nil if the camera has nothing recorded in the last week.
    public static func of(camera: String, recordings base: String, size: CGSize = CGSize(width: 640, height: 360)) async
        -> (image: CGImage, time: Date)? {
        let now = Date()
        // Look back a little first, to avoid listing the whole week; further for a camera that has gone quiet, whose
        // old picture (and its age) then says so.
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
        return (image, span.start.addingTimeInterval(actual.seconds))
    }

    /// As JPEG, to send.
    public static func jpeg(_ image: CGImage, quality: Double = 0.7) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
