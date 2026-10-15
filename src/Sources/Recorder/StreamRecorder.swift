// Turns a camera session's packets into fragmented MP4: video frames from the H.264 depacketizer, audio from
// the AAC one, both placed on one timeline that starts at the first keyframe. The camera's RTCP sender
// reports tie each track's RTP clock to wall time, which keeps sound in step with the picture and dates
// the recording; until the first report, arrival time stands in.
//
// With `segmentSeconds`, the recording is cut into segments: at the first keyframe after that long, the
// current segment ends (its last frame lasting exactly until the keyframe) and a new one starts, with its
// own init segment, so every segment is a complete MP4 on its own.
import Foundation
import Ingest
import Media

public struct SegmentSummary: Equatable, Sendable {
    public var wallTime: Double
    public var seconds: Double
    public var videoFrames: Int
    public var audioFrames: Int
}

public final class StreamRecorder {
    public enum Output: Equatable {
        /// A new segment: the MP4 header, with the wall time of its first frame.
        case start(initSegment: [UInt8], wallTime: Double)
        case fragment([UInt8])
        /// The segment is complete.
        case end(SegmentSummary)
    }

    let videoMedia: SDP.Media
    let audioMedia: SDP.Media?
    let fragmentSeconds: Double
    let segmentLength: Int64?
    private var h264: H264Depacketizer
    private let aac: AACDepacketizer?
    private var videoClock: RTPClock
    private var audioClock: RTPClock?
    private var videoUnwrap = TimestampUnwrapper()
    private var audioUnwrap = TimestampUnwrapper()
    private var started = false
    private var videoStart: Int64 = 0
    private var startWall: Double = 0
    private var audioOffset: Int64?

    private var writer: FragmentWriter?
    /// The current segment's start on the recording's timeline (90 kHz) and in wall time.
    private var segmentStart: Int64 = 0
    private var segmentWall: Double = 0
    private var finishedSeconds = 0.0
    private var finishedVideo = 0
    private var finishedAudio = 0

    public private(set) var damagedFrames = 0
    /// Totals over every segment so far.
    public var writtenSeconds: Double { finishedSeconds + (writer?.writtenSeconds ?? 0) }
    public var videoFrames: Int { finishedVideo + (writer?.videoFrames ?? 0) }
    public var audioFrames: Int { finishedAudio + (writer?.audioFrames ?? 0) }
    public var lostPackets: Int { h264.lostPackets }
    public var videoTrack: VideoTrack? { writer?.video }

    public init(video: SDP.Media, audio: SDP.Media?, fragmentSeconds: Double = 2, segmentSeconds: Double? = nil) {
        videoMedia = video
        audioMedia = audio
        self.fragmentSeconds = fragmentSeconds
        segmentLength = segmentSeconds.map { Int64($0 * Double(VideoTrack.timescale)) }
        h264 = H264Depacketizer(spropParameterSets: video.format["sprop-parameter-sets"])
        videoClock = RTPClock(rate: video.clockRate > 0 ? video.clockRate : 90000)
        if let audio {
            aac = AACDepacketizer(format: audio.format)
            audioClock = RTPClock(rate: audio.clockRate)
        } else {
            aac = nil
        }
    }

    /// One interleaved packet, received at `now` (seconds since 1970).
    public func handle(_ packet: InterleavedPacket, now: Double) -> [Output] {
        switch packet.channel {
        case CameraSession.videoChannel + 1:
            videoClock.noteRTCP(packet.data)
        case CameraSession.audioChannel + 1:
            audioClock?.noteRTCP(packet.data)
        case CameraSession.videoChannel:
            guard let rtp = RTPPacket(packet.data) else { return [] }
            return h264.push(rtp).flatMap { addVideo($0, now: now) }
        case CameraSession.audioChannel:
            guard let aac, let rtp = RTPPacket(packet.data) else { return [] }
            for frame in aac.push(rtp) { addAudio(frame, now: now) }
        default:
            break
        }
        return []
    }

    private func audioTrack() -> AudioTrack? {
        audioMedia.flatMap { m -> AudioTrack? in
            guard let hex = m.format["config"], let config = AACConfig(hex: hex) else { return nil }
            return AudioTrack(config: Self.bytes(hex: hex), sampleRate: config.sampleRate, channels: config.channels)
        }
    }

    /// Starts a segment at `time` on the recording's timeline. Nil until the parameter sets are known.
    private func openSegment(at time: Int64) -> Output? {
        guard let sps = h264.sps, let pps = h264.pps, let info = H264SPS(nal: sps) else { return nil }
        let w = FragmentWriter(video: VideoTrack(sps: sps, pps: pps, width: info.width, height: info.height),
                               audio: audioTrack(), fragmentSeconds: fragmentSeconds)
        writer = w
        segmentStart = time
        segmentWall = startWall + Double(time) / Double(VideoTrack.timescale)
        return .start(initSegment: w.initSegment, wallTime: segmentWall)
    }

    private func closeSegment(until time: Int64?) -> [Output] {
        guard let w = writer else { return [] }
        var out: [Output] = []
        if let bytes = w.finish(until: time.map { $0 - segmentStart }) { out.append(.fragment(bytes)) }
        out.append(.end(SegmentSummary(wallTime: segmentWall, seconds: w.writtenSeconds, videoFrames: w.videoFrames,
                                       audioFrames: w.audioFrames)))
        finishedSeconds += w.writtenSeconds
        finishedVideo += w.videoFrames
        finishedAudio += w.audioFrames
        writer = nil
        return out
    }

    private func addVideo(_ unit: H264AccessUnit, now: Double) -> [Output] {
        if unit.damaged { damagedFrames += 1 }
        var out: [Output] = []
        if !started {
            guard unit.isKeyframe, h264.sps != nil, h264.pps != nil else { return [] }
            started = true
            videoStart = videoUnwrap.unwrap(unit.timestamp)
            startWall = videoClock.wallTime(unit.timestamp) ?? now
            guard let start = openSegment(at: 0) else { return [] }
            out.append(start)
            _ = writer?.addVideo(time: 0, nalus: unit.nalus, isKeyframe: true)
            return out
        }
        let time = videoUnwrap.unwrap(unit.timestamp) - videoStart
        if unit.isKeyframe, let length = segmentLength, writer != nil, time - segmentStart >= length {
            out += closeSegment(until: time)
        }
        if writer == nil {
            guard unit.isKeyframe, let start = openSegment(at: time) else { return out }
            out.append(start)
        }
        if let fragment = writer?.addVideo(time: time - segmentStart, nalus: unit.nalus, isKeyframe: unit.isKeyframe) {
            out.append(.fragment(fragment))
        }
        return out
    }

    private func addAudio(_ frame: AACFrame, now: Double) {
        guard started, let writer, let audio = writer.audio, let clock = audioClock else { return }
        let unwrapped = audioUnwrap.unwrap(frame.timestamp)
        if audioOffset == nil {
            let wall = clock.wallTime(frame.timestamp) ?? now
            audioOffset = Int64(((wall - startWall) * Double(audio.sampleRate)).rounded()) - unwrapped
        }
        let segmentStartInAudio = segmentStart * Int64(audio.sampleRate) / Int64(VideoTrack.timescale)
        writer.addAudio(time: unwrapped + audioOffset! - segmentStartInAudio, data: frame.data)
    }

    /// Ends the current segment with everything still held.
    public func finish() -> [Output] {
        closeSegment(until: nil)
    }

    static func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), i < hex.endIndex {
            if let b = UInt8(hex[i ..< j], radix: 16) { out.append(b) }
            i = j
        }
        return out
    }
}
