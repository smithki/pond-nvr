// Collects frames and cuts them into fragments: a new fragment starts at the first keyframe after
// `fragmentDuration`. A sample's duration is the gap to the next one, so the last frame is held back until
// the next arrives. Audio follows video: a fragment takes the audio that starts before its end.

public final class FragmentWriter {
    public let video: VideoTrack
    public let audio: AudioTrack?
    /// In video timescale units (90 kHz).
    let fragmentDuration: Int64
    private var sequence: UInt32 = 0
    private var pendingVideo: [(time: Int64, data: [UInt8], key: Bool)] = []
    private var pendingAudio: [(time: Int64, data: [UInt8])] = []
    private var lastVideoDuration: Int64 = 3000

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
            let take = pendingAudio.prefix { $0.time < endInAudio }
            audioTime = take.first?.time ?? 0
            for (i, frame) in take.enumerated() {
                let next = i + 1 < take.count ? take[take.startIndex + i + 1].time : frame.time + 1024
                audioSamples.append(MP4Sample(data: frame.data, duration: UInt32(max(1, next - frame.time)), isSync: true))
            }
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
