// One HomeKit Secure Video recording, as the home hub asked for it (dataSend `open`): the camera's prebuffer
// and then its live frames, re-encoded to the hub's choice (size, bitrate, frame rate, a keyframe exactly
// every fragment), written as fragmented MP4 (Media's FragmentWriter) and sent over the data stream in
// `dataSend` `data` events: the initialization segment, then each fragment, in chunks of at most 256 KB,
// numbered as HAP-NodeJS's CameraRecordingStream numbers them. Until the hub closes it (or its connection).
// The camera's AAC-LC goes along unchanged when the hub chose AAC-LC at the camera's own sample rate.
import Foundation
import HAP
import Media
import NVRCore

final class RecordingSession: @unchecked Sendable {
    let camera: String?
    let streamID: Int64
    let connection: DataStreamConnection
    let selected: SelectedRecording
    let audio: AudioTrack?
    let prebuffer: Prebuffer
    let log: @Sendable (String) -> Void

    private let lock = NSLock()
    private var transcoder: VideoTranscoder?
    private var token: UUID?
    private var writer: FragmentWriter?
    private var closed = false
    /// The recording's start on the camera's clocks, and in wall time.
    private var videoStart: Int64?
    private var startWall = 0.0
    /// The last frame's time on the camera's clock: a jump from it (the stream opened again, on a new clock) is
    /// taken up by placing the recording's clock again by wall time.
    private var lastVideo: Int64?
    /// Further than this from the last frame (or back from it) is a new clock, not a late frame.
    static let clockJump: Int64 = 5 * 90000
    private var audioOffset: Int64?
    /// Sound that came before the first encoded frame, to add once the writer exists.
    private var heldAudio: [(time: Int64, data: [UInt8])] = []
    /// Live frames that came while the prebuffer was still going in: they follow it, in order (taken
    /// straight away, they overtook it, and the older frames were then dropped as out of order).
    private var catchingUp = true
    private var waiting: [Prebuffer.Item] = []
    /// `dataSequenceNumber`: the initialization segment is 1, each fragment one more.
    private var sequence: Int64 = 0
    private var sentBytes = 0, sentFragments = 0

    /// Told when it ends: the clip sent (if any), and the hub's reason (0 or nil: normal).
    var finished: (@Sendable (HomeKitStatus.Recording.Clip?, Int64?) -> Void)?
    private let began = Date()

    /// The largest chunk of a fragment in one event.
    static let maxChunk = 0x40000

    /// For looking into what the hub is sent: while a folder `hksv-dump` is beside the settings, each recording
    /// is also written there whole (its initialization segment and fragments, a playable MP4), named by its
    /// camera's id, when it began and its stream. Nothing is written without the folder.
    static var dumpFolder: String {
        (NSString(string: Brand.supportFolder).expandingTildeInPath as NSString).appendingPathComponent("hksv-dump")
    }
    private lazy var dumpFile: FileHandle? = {
        // Only a real camera's (a test's recordings are made up).
        guard let camera else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: Self.dumpFolder, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        let path = (Self.dumpFolder as NSString).appendingPathComponent("\(camera)-\(Int(began.timeIntervalSince1970))-\(streamID).mp4")
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    init(camera: String? = nil, streamID: Int64, connection: DataStreamConnection, selected: SelectedRecording, audio: AudioTrack?,
         prebuffer: Prebuffer, log: @escaping @Sendable (String) -> Void) {
        self.camera = camera
        self.streamID = streamID
        self.connection = connection
        self.selected = selected
        self.audio = audio
        self.prebuffer = prebuffer
        self.log = log
    }

    func start() {
        let target = VideoTranscoder.Target(width: selected.width, height: selected.height, bitrate: selected.bitrate,
                                            fps: selected.fps, profile: selected.profile)
        let interval = Int64(max(500, selected.keyframeInterval)) * 90
        let transcoder = VideoTranscoder(target: target, realTime: false, keyframeInterval: interval) { [weak self] frame in
            self?.encoded(frame)
        }
        lock.withLock { self.transcoder = transcoder }
        let (backlog, token) = prebuffer.subscribe(back: Double(selected.prebuffer) / 1000) { [weak self] item in
            self?.arrived(item)
        }
        lock.withLock { self.token = token }
        for item in backlog { take(item) }
        // Then what came meanwhile, until there is none left over.
        while true {
            let next = lock.withLock { () -> [Prebuffer.Item] in
                defer { waiting = [] }
                if waiting.isEmpty { catchingUp = false }
                return waiting
            }
            if next.isEmpty { break }
            for item in next { take(item) }
        }
    }

    /// A live frame or sound: taken now, or held while the prebuffer is still going in.
    private func arrived(_ item: Prebuffer.Item) {
        let held = lock.withLock { () -> Bool in
            if catchingUp { waiting.append(item) }
            return catchingUp
        }
        if !held { take(item) }
    }

    /// A camera frame or sound: video into the transcoder (from a keyframe on), sound held for the writer.
    private func take(_ item: Prebuffer.Item) {
        switch item {
        case let .video(v):
            let time: Int64? = lock.withLock {
                if closed { return nil }
                if videoStart == nil {
                    guard v.keyframe else { return nil }
                    videoStart = v.time
                    startWall = v.wall
                } else if let last = lastVideo, v.time <= last - Self.clockJump || v.time > last + Self.clockJump {
                    // A new clock (the camera's stream opened again, its times starting anywhere): this frame placed by
                    // wall time, as long after the start as it really is; the sound placed again the same way. Left
                    // as it was, the time leapt by up to 13 hours, and the encoder was given a picture for every
                    // fragment in between (gigabytes at once), or nothing more at all for a leap back.
                    videoStart = v.time - Int64(((v.wall - startWall) * 90000).rounded())
                    audioOffset = nil
                    log("HomeKit: recording stream \(streamID): the camera's clock jumped; placed again by wall time")
                }
                lastVideo = v.time
                return v.time - videoStart!
            }
            guard let time, let transcoder = lock.withLock({ self.transcoder }) else { return }
            transcoder.push(v.nalus, sps: v.sps, pps: v.pps, time: time, encode: true)
        case let .audio(a):
            guard let audio else { return }
            lock.withLock {
                guard !closed, videoStart != nil else { return }
                if audioOffset == nil {
                    audioOffset = Int64(((a.wall - startWall) * Double(audio.sampleRate)).rounded()) - a.time
                }
                let time = a.time + audioOffset!
                if let writer { writer.addAudio(time: time, data: a.data) } else { heldAudio.append((time, a.data)) }
            }
        }
    }

    /// An encoded frame: the writer is made with the first keyframe (its SPS and PPS), and fragments go out
    /// as they complete.
    private func encoded(_ frame: VideoTranscoder.Frame) {
        let parameterSets = frame.nalus.filter { [7, 8].contains($0.first.map { $0 & 0x1F } ?? 0) }
        let nalus = frame.nalus.filter { ![7, 8].contains($0.first.map { $0 & 0x1F } ?? 0) }
        var sends: [(type: String, data: [UInt8])] = []
        lock.withLock {
            guard !closed else { return }
            if writer == nil {
                guard frame.keyframe, parameterSets.count == 2 else { return }
                let w = FragmentWriter(video: VideoTrack(sps: parameterSets[0], pps: parameterSets[1], width: frame.width,
                                                         height: frame.height),
                                       audio: audio, fragmentSeconds: Double(selected.fragmentLength) / 1000)
                writer = w
                for (time, data) in heldAudio { w.addAudio(time: time, data: data) }
                heldAudio = []
                sends.append(("mediaInitialization", w.initSegment))
            }
            if let fragment = writer?.addVideo(time: frame.time, nalus: nalus, isKeyframe: frame.keyframe) {
                sends.append(("mediaFragment", fragment))
            }
        }
        for s in sends { send(s.data, type: s.type) }
    }

    /// One packet (the initialization segment or a fragment), in chunks.
    private func send(_ data: [UInt8], type: String) {
        let number = lock.withLock { () -> Int64 in
            sequence += 1
            if type == "mediaFragment" { sentFragments += 1 }
            sentBytes += data.count
            return sequence
        }
        lock.withLock { try? dumpFile?.write(contentsOf: data) }
        if number == 1 { log("✓ HomeKit: recording stream \(streamID) under way: \(selected.width)×\(selected.height) at \(selected.bitrate) kbit/s\(audio == nil ? ", no sound" : "")") }
        var offset = 0, chunk: Int64 = 1
        while offset < data.count {
            let piece = Array(data[offset ..< min(data.count, offset + Self.maxChunk)])
            offset += piece.count
            var metadata: [(String, Opack)] = [
                ("dataType", .string(type)),
                ("dataSequenceNumber", .int(number)),
                ("dataChunkSequenceNumber", .int(chunk)),
                ("isLastDataChunk", .bool(offset >= data.count)),
            ]
            if chunk == 1 { metadata.append(("dataTotalSize", .int(Int64(data.count)))) }
            let body = Opack.dictionary([
                ("streamId", .int(streamID)),
                ("packets", .array([.dictionary([("data", .data(piece)), ("metadata", .dictionary(metadata))])])),
            ])
            connection.send(DataStream.Message(kind: .event, protocol: "dataSend", topic: "data", body: body))
            chunk += 1
        }
    }

    /// The hub closed it (or its connection went): no more frames.
    func close(reason: Int64?) {
        // The transcoder let go outside the lock: stopping it waits for frames in flight, which take the lock.
        let (token, fragments, bytes, stopping) = lock.withLock { () -> (UUID?, Int, Int, VideoTranscoder?) in
            defer { closed = true; transcoder = nil; writer = nil }
            return (closed ? nil : self.token, sentFragments, sentBytes, transcoder)
        }
        _ = stopping
        guard let token else { return }
        prebuffer.unsubscribe(token)
        let clip = fragments > 0
            ? HomeKitStatus.Recording.Clip(at: began, seconds: Double(fragments * selected.fragmentLength) / 1000, bytes: bytes)
            : nil
        finished?(clip, reason)
        log("HomeKit: recording stream \(streamID) closed\(reason.map { " (reason \($0))" } ?? ""): \(fragments) fragments, \(bytes / 1000) kB sent")
    }
}
