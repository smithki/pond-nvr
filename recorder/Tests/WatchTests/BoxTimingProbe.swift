import AVFoundation
import CoreImage
import Detection
import Foundation
import Recorder
import Testing
@testable import Watch

/// Opt-in, against real recordings: POND_PROBE_BASE=<recordings> POND_PROBE_CAMERA=<id> POND_PROBE_DB=<pond.sqlite>
/// POND_MODELS=<models> swift test --filter BoxTimingProbe. For recent sightings of things moving, runs the model on
/// the recorded picture at the sighting's time shifted by -1.5…+1.5 s and finds the shift where the boxes match best:
/// how far the boxes are out from the recording.
@Suite struct BoxTimingProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POND_PROBE_DB"] != nil))
    func howFarOutAreTheBoxes() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = env["POND_PROBE_BASE"]!, camera = env["POND_PROBE_CAMERA"]!, since = Double(env["POND_PROBE_SINCE"] ?? "0") ?? 0
        let store = try #require(EventStore(path: env["POND_PROBE_DB"]!, readOnly: true))
        let all = store.sightings(camera: camera, from: Date(timeIntervalSince1970: since), to: Date())
        // Moving: the same track's box moved more than a little since its last look.
        var last: [Int: Sighting] = [:]
        var moving: [Sighting] = []
        for s in all {
            if let track = s.track, let was = last[track], abs(s.box.x - was.box.x) + abs(s.box.y - was.box.y) > 0.03,
               s.time.timeIntervalSince(was.time) < 0.6 { moving.append(s) }
            if let track = s.track { last[track] = s }
        }
        print("moving sightings:", moving.count)
        let picked = stride(from: 0, to: moving.count, by: max(1, moving.count / 15)).map { moving[$0] }
        let detector = Detector()
        try detector.use(try #require(ModelStore.choose(nil)))
        let shifts = stride(from: -2.0, through: 2.0, by: 0.1).map { $0 }
        var error = [Double](repeating: 0, count: shifts.count), counted = [Int](repeating: 0, count: shifts.count)
        let context = CIContext()
        for s in picked {
            let spans = RecordingIndex.spans(base: base, camera: camera, from: s.time.addingTimeInterval(-90), to: s.time.addingTimeInterval(90), writing: true)
            guard let span = spans.first(where: { $0.start <= s.time && s.time < $0.end }) else { continue }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: span.path),
                                                                   options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"]))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            for (i, shift) in shifts.enumerated() {
                let at = s.time.timeIntervalSince(span.start) + shift
                guard at >= 0, let (image, _) = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)) else { continue }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &buffer)
                guard let buffer else { continue }
                context.render(CIImage(cgImage: image), to: buffer)
                let found = (try? detector.detect(buffer)) ?? []
                let centre = (s.box.x + s.box.width / 2, s.box.y + s.box.height / 2)
                guard let nearest = found.filter({ $0.category == s.category }).map({ d in
                    hypot(d.box.x + d.box.width / 2 - centre.0, d.box.y + d.box.height / 2 - centre.1)
                }).min(), nearest < 0.25 else { continue }
                error[i] += nearest
                counted[i] += 1
            }
        }
        for (i, shift) in shifts.enumerated() where counted[i] > 0 {
            print(String(format: "shift %+.1f s: mean distance %.4f (%d)", shift, error[i] / Double(counted[i]), counted[i]))
        }
    }
}
