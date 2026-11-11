// Collects frames and cuts them into fragments: a new fragment starts at the first keyframe after
// `fragmentDuration`. A sample's duration is the gap to the next one, so the last frame is held back until
// the next arrives. Audio follows video: a fragment takes the audio that starts before its end.
//
// An AAC frame is 1024 samples, whatever its timestamp says: each lasts that long, one after another, and
// only a real gap in the sound (the next frame more than two frames late) is kept as a longer one. A camera
// that sends its sound in bursts (a doorbell's frames 3 ms apart, then a pause) otherwise made frames of
// 54 and 59 samples, and the home hub kept none of its recordings.

public final class FragmentWriter {
    public let video: VideoTrack
    public let audio: AudioTrack?
    /// In video timescale units (90 kHz).
    let fragmentDuration: Int64
    private var sequence: UInt32 = 0
    private var pendingVideo: [(time: Int64, data: [UInt8], key: Bool)] = []
    private var pendingAudio: [(time: Int64, data: [UInt8])] = []
    private var lastVideoDuration: Int64 = 3000
    /// Where the audio written so far ends (sample-rate units): the next fragment's sound carries on from it.
    private var audioEnd: Int64?
    static let aacFrame: Int64 = 1024

    /// Frames written so far, for reporting.
    public private(set) var videoFrames = 0
    public private(set) var audioFrames = 0
    /// End of the last frame written, in seconds from the start.
    public private(set) var writtenSeconds = 0.0

    public init(video: VideoTrack, audio: AudioTrack?, fragmentSeconds: Double = 2) {
        self.video = video
        self.audio = audio
        fragmentDuration = Int64(fragmentSeconds * Double(VideoTrack.timescale))
    }

    public var initSegment: [UInt8] { MP4.initSegment(video: video, audio: audio) }

    /// A video frame at `time` (90 kHz units from the start, increasing). Frames before the first keyframe
    /// are dropped. Returns a finished fragment when this keyframe starts a new one.
    public func addVideo(time: Int64, nalus: [[UInt8]], isKeyframe: Bool) -> [UInt8]? {
        if pendingVideo.isEmpty, !isKeyframe { return nil }
        if let last = pendingVideo.last, time <= last.time { return nil }   // out of order or repeated
        var out: [UInt8]?
        if isKeyframe, let first = pendingVideo.first, time - first.time >= fragmentDuration {
            out = flush(until: time)
        }
        pendingVideo.append((time, MP4.avcc(nalus), isKeyframe))
        return out
    }

    /// An audio frame at `time` (sample-rate units from the start). Frames before 0 are dropped.
    public func addAudio(time: Int64, data: [UInt8]) {
        guard audio != nil, time >= 0 else { return }
        if let last = pendingAudio.last, time <= last.time { return }
        pendingAudio.append((time, data))
    }

    /// Writes out everything held. The last frame lasts until `end` (in video units) when the next frame's
    /// time is known, as when a new segment starts at it; otherwise its duration is guessed from the one
    /// before. Nil if there is nothing.
    public func finish(until end: Int64? = nil) -> [UInt8]? {
        guard let last = pendingVideo.last else { return nil }
        let end = end.flatMap { $0 > last.time ? $0 : nil } ?? last.time + lastVideoDuration
        return flush(until: end)
    }

    private func flush(until end: Int64) -> [UInt8] {
        var videoSamples: [MP4Sample] = []
        for (i, frame) in pendingVideo.enumerated() {
            let next = i + 1 < pendingVideo.count ? pendingVideo[i + 1].time : end
            let duration = next - frame.time
            if i + 1 < pendingVideo.count { lastVideoDuration = duration }
            videoSamples.append(MP4Sample(data: frame.data, duration: UInt32(duration), isSync: frame.key))
        }
        let videoTime = pendingVideo[0].time
        var audioSamples: [MP4Sample] = []
        var audioTime: Int64 = 0
        if let audio {
            let endInAudio = end * Int64(audio.sampleRate) / Int64(VideoTrack.timescale)
            let take = Array(pendingAudio.prefix { $0.time < endInAudio })
            // Carrying on from the last fragment's sound, unless this one starts after a gap.
            var running = take.first.map { first in audioEnd.map { $0 >= first.time - 2 * Self.aacFrame ? max($0, first.time) : first.time } ?? first.time } ?? 0
            audioTime = running
            for (i, frame) in take.enumerated() {
                // A frame's length, longer only to bridge a real gap before the next.
                let next = i + 1 < take.count ? take[i + 1].time : running + Self.aacFrame
                let gap = next - running
                let duration = gap > 2 * Self.aacFrame ? gap : Self.aacFrame
                audioSamples.append(MP4Sample(data: frame.data, duration: UInt32(duration), isSync: true))
                running += duration
            }
            if !take.isEmpty { audioEnd = running }
            pendingAudio.removeFirst(take.count)
        }
        sequence += 1
        let bytes = MP4.fragment(sequence: sequence, video: videoSamples, videoTime: UInt64(videoTime),
                                 audio: audioSamples, audioTime: UInt64(max(0, audioTime)))
        videoFrames += videoSamples.count
        audioFrames += audioSamples.count
        writtenSeconds = Double(end) / Double(VideoTrack.timescale)
        pendingVideo = []
        return bytes
    }
}
