// Recorded minutes as one piece of video: each segment at its recorded offset from the first one's start (or from a
// moment asked, what's before it left out), gaps kept as gaps. What the app plays (the timeline, an event's details)
// and what the service copies an event's clip from.
import AVFoundation
import Foundation
import Recorder

public enum RecordingComposition {
    /// A segment's file, readable while it's still being written (".mp4.partial" said to be MP4).
    public static func asset(_ path: String) -> AVURLAsset {
        AVURLAsset(url: URL(fileURLWithPath: path),
                   options: path.hasSuffix(".partial") ? [AVURLAssetOverrideMIMETypeKey: "video/mp4"] : nil)
    }

    /// The segments at their recorded offsets from the first one's start (or from `from`, what's before it left
    /// out; `to`, what's after it); a segment longer than the gap to the next is trimmed to it. And where it ends.
    public static func make(_ spans: [RecordedSpan], from: Date? = nil, to: Date? = nil) async -> (composition: AVMutableComposition, end: Date)? {
        guard let origin = from ?? spans.first?.start else { return nil }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var audio: AVMutableCompositionTrack?
        var end = origin
        for (i, span) in spans.enumerated() {
            let asset = Self.asset(span.path)
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            var length = duration.seconds
            if i + 1 < spans.count { length = min(length, spans[i + 1].start.timeIntervalSince(span.start)) }
            if let to { length = min(length, to.timeIntervalSince(span.start)) }
            // What's before the origin left out.
            let skip = max(0, origin.timeIntervalSince(span.start))
            guard length - skip > 0.05 else { continue }
            let range = CMTimeRange(start: CMTime(seconds: skip, preferredTimescale: 90000),
                                    duration: CMTime(seconds: length - skip, preferredTimescale: 90000))
            let offset = CMTime(seconds: max(0, span.start.timeIntervalSince(origin)), preferredTimescale: 90000)
            insert(range, of: sourceVideo, into: video, at: offset)
            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                if audio == nil {
                    audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                if let audio { insert(range, of: sourceAudio, into: audio, at: offset) }
            }
            end = max(end, span.start.addingTimeInterval(length))
        }
        guard !video.segments.isEmpty else { return nil }
        return (composition, end)
    }

    static func insert(_ range: CMTimeRange, of source: AVAssetTrack, into track: AVMutableCompositionTrack, at offset: CMTime) {
        let trackEnd = track.timeRange.end
        var at = offset
        if track.segments.isEmpty || trackEnd < at {
            let from = track.segments.isEmpty ? .zero : trackEnd
            if from < at { track.insertEmptyTimeRange(CMTimeRange(start: from, end: at)) }
        } else {
            at = trackEnd   // rounding: never insert into what is already there
        }
        try? track.insertTimeRange(range, of: source, at: at)
    }
}
