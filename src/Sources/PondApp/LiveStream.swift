// Live video from one camera stream, straight to the screen: a background thread reads the stream, turns
// each H.264 frame into a sample buffer and hands it to an AVSampleBufferDisplayLayer, which decodes it in
// hardware. Frames go in through a render synchronizer running at normal speed, each stamped with the
// synchronizer's current time, so each is shown as it arrives.
//
// The stream comes through the background service (StreamRelay), sharing the camera connection the recorder
// and HomeKit already read. The app never connects to a camera for live view itself: that would need the
// camera's password, which only pond reads (see PasswordKeeper). Without the service, the tile says so, and
// tries again until it is there.
//
// Sound comes over the same connection. Unmuted, an AVSampleBufferAudioRenderer joins the synchronizer and
// gets the camera's AAC frames, decoded by the system, a little behind the picture (`AudioOutput.delay`) so they
// play without gaps; muted, the renderer leaves and the frames are dropped unread.
import AVFoundation
import Control
import CoreMedia
import Ingest
import Observation
import Synchronization

@MainActor
@Observable
final class LiveStream {
    enum State: Equatable {
        case connecting
        case playing
        /// Connected, but no picture: privacy mode, or the camera stopped sending.
        case noPicture
        /// Pond's background service, which live view comes through, isn't running.
        case serviceStopped
        /// It is, but started before this camera was added (or its address changed): it needs a restart.
        case serviceBehind
        case failed(String)
    }

    private(set) var state: State = .connecting
    /// The picture's size in pixels, once known.
    private(set) var size: CGSize?
    /// The stream has sound (the camera has a microphone, and sends it).
    private(set) var hasAudio = false
    /// Off by default; one camera at a time is heard (the view decides which).
    var muted = true {
        didSet { if muted != oldValue { audio.setMuted(muted) } }
    }
    /// Tried again every second when it fails, not after a growing pause: the camera is coming back (waking from
    /// its privacy mode), so it'll answer soon.
    var retriesSoon = false {
        didSet { soonFlag.set(retriesSoon) }
    }
    let layer = AVSampleBufferDisplayLayer()
    private let audio = AudioOutput()
    private let stopFlag = StopFlag()
    private let soonFlag = Flag()
    private var started = false

    let url: String
    /// The service's stream relay.
    let relay: String

    init(url: String, relay: String) {
        self.url = url
        self.relay = relay
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func start() {
        guard !started else { return }
        started = true
        audio.setMuted(muted)
        let reader = Reader(url: url, relay: relay,
                            renderer: SendableRenderer(layer.sampleBufferRenderer), audio: audio, stop: stopFlag,
                            soon: soonFlag) { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        let thread = Thread { reader.run() }
        thread.name = "live \(url)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        stopFlag.stop()
    }

    private func apply(_ event: Reader.Event) {
        switch event {
        case let .state(s): state = s
        case let .size(s): size = s
        case let .hasAudio(a): hasAudio = a
        }
    }
}

final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    func stop() { flag.store(true, ordering: .relaxed) }
    var stopped: Bool { flag.load(ordering: .relaxed) }
}

final class Flag: Sendable {
    private let flag = Atomic<Bool>(false)
    func set(_ on: Bool) { flag.store(on, ordering: .relaxed) }
    var isOn: Bool { flag.load(ordering: .relaxed) }
}

/// The reader thread attaches the renderer to its own synchronizer and feeds it from there.
struct SendableRenderer: @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer
    init(_ renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }
}

/// The blocking part, on its own thread. Reconnects with a growing pause until stopped.
private struct Reader: Sendable {
    enum Event: Sendable {
        case state(LiveStream.State)
        case size(CGSize)
        case hasAudio(Bool)
    }

    let url: String
    let relay: String
    let renderer: SendableRenderer
    let audio: AudioOutput
    let stop: StopFlag
    let soon: Flag
    let report: @Sendable (Event) -> Void

    /// Seconds without a frame before the picture counts as gone.
    static let stallSeconds = 6.0

    func run() {
        // One clock for the tile's whole life, its video renderer attached once: a renderer can be in only
        // one synchronizer, and attaching it to a new one on each reconnect raised an exception (and quit the
        // app) while the old one still held it. Reconnects flush instead.
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let receiver = synchronizer.sampleBufferReceiver(adding: renderer.renderer)
        synchronizer.setRate(1, time: .zero)
        var player = AudioPlayer(synchronizer: synchronizer)
        var pause = 1.0
        while !stop.stopped {
            report(.state(.connecting))
            var played = false
            do throws(RTSPError) {
                switch try RelaySession.connect(path: relay, url: url) {
                case let .opened(session):
                    try play(session, synchronizer: synchronizer, receiver: receiver, player: &player,
                             onFirstFrame: { played = true })
                case .noService:
                    report(.state(.serviceStopped))
                    pause = 0.5   // again in a second: the service may be starting
                case .unknownStream:
                    report(.state(.serviceBehind))
                    pause = 0.5
                }
            } catch {
                report(.state(.failed(CameraCheck.plain(error, host: URLComponents(string: url)?.host ?? url).text)))
            }
            if played || soon.isOn { pause = 1 }
            wait(pause)
            pause = soon.isOn ? 1 : min(pause * 2, 15)
        }
    }

    private func wait(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while !stop.stopped, Date() < until { Thread.sleep(forTimeInterval: 0.1) }
    }

    private func play(_ session: PacketSource, synchronizer: AVSampleBufferRenderSynchronizer,
                      receiver: AVSampleBufferVideoRenderer.Receiver, player: inout AudioPlayer,
                      onFirstFrame: () -> Void) throws(RTSPError) {
        defer { session.close() }
        // (H.264 or H.265, as the stream says: the renderer decodes either.)
        var depacketizer = VideoDepacketizer(video: session.video)
        var format: CMVideoFormatDescription?
        var formatSets: ParameterSets?
        var needKeyframe = true
        var lastFrame = Date()
        var playing = false
        var showingNoPicture = false
        // What the last connection left behind (frames, sound) goes; this one starts afresh.
        receiver.flush()
        let aac = session.audio.map { AACDepacketizer(format: $0.format) }
        player.begin(format: session.audio.flatMap { AudioOutput.format(config: $0.format["config"]) })
        report(.hasAudio(player.format != nil))

        while !stop.stopped {
            guard let packet = try session.next(timeout: 0.5) else {
                if Date().timeIntervalSince(lastFrame) > Self.stallSeconds, !showingNoPicture {
                    report(.state(.noPicture))
                    showingNoPicture = true
                    playing = false
                }
                continue
            }
            if packet.channel == CameraSession.audioChannel {
                // Sound from before the tile joined (the service's replay) would lag the picture: dropped.
                if packet.replayed { continue }
                if audio.muted {
                    player.mute()
                } else if let aac, player.format != nil, let rtp = RTPPacket(packet.data) {
                    for frame in aac.push(rtp) { player.play(frame) }
                }
                continue
            }
            guard packet.channel == CameraSession.videoChannel, let rtp = RTPPacket(packet.data) else { continue }
            for unit in depacketizer.push(rtp) {
                if unit.damaged {
                    needKeyframe = true
                    continue
                }
                if needKeyframe {
                    guard unit.isKeyframe else { continue }
                    needKeyframe = false
                }
                if let sets = depacketizer.parameterSets, sets != formatSets {
                    format = sets.formatDescription()
                    formatSets = sets
                    if let format {
                        let d = CMVideoFormatDescriptionGetDimensions(format)
                        report(.size(CGSize(width: Int(d.width), height: Int(d.height))))
                    }
                }
                guard let format,
                      let sample = Self.sample(unit.nalus, format: format, at: synchronizer.currentTime()) else { continue }
                switch receiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: sample)) {
                case .enqueued, .enqueuedWithDecodeFailures:
                    break
                default:
                    // Start again from the next keyframe.
                    receiver.flush()
                    needKeyframe = true
                    continue
                }
                lastFrame = Date()
                if !playing {
                    playing = true
                    showingNoPicture = false
                    onFirstFrame()
                    report(.state(.playing))
                }
            }
        }
    }

    /// One frame as length-prefixed NAL units, to be shown at `time` (and at once, as soon as it is decoded).
    static func sample(_ nalus: [[UInt8]], format: CMVideoFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(nalus.reduce(0) { $0 + $1.count + 4 })
        for nal in nalus {
            let n = UInt32(nal.count)
            bytes += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            bytes += nal
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
        guard bytes.withUnsafeBytes({ raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: raw.count)
        }) == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// A stream's sound: muted or not (set on the main thread), and how the reader plays it.
final class AudioOutput: Sendable {
    /// How far behind the picture the sound plays: room for the camera's uneven packet timing.
    static let delay = 0.15

    private let mutedFlag = Atomic<Bool>(true)
    func setMuted(_ value: Bool) { mutedFlag.store(value, ordering: .relaxed) }
    var muted: Bool { mutedFlag.load(ordering: .relaxed) }

    /// AAC as the camera describes it: the AudioSpecificConfig (hex, from the SDP) is the decoder's cookie.
    static func format(config hex: String?) -> CMAudioFormatDescription? {
        guard let hex, let config = AACConfig(hex: hex) else { return nil }
        let cookie: [UInt8] = stride(from: 0, to: hex.count - 1, by: 2).compactMap { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16)
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(config.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(config.objectType), mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, config.channels)), mBitsPerChannel: 0, mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: raw.count, magicCookie: raw.baseAddress,
                                           extensions: nil, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    static func sample(_ data: [UInt8], format: CMAudioFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block,
            data.withUnsafeBytes({ raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                              dataLength: raw.count)
            }) == noErr else { return nil }
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                  mDataByteSize: UInt32(data.count))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            presentationTimeStamp: time, packetDescriptions: &packet, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

/// The reader's side of the sound: an audio renderer in the tile's synchronizer, added on the first unmute
/// and kept for the tile's life (like the video's, it can be in one synchronizer only); muted, it is flushed
/// and gets nothing. Each connection says its format with `begin`.
private struct AudioPlayer {
    let synchronizer: AVSampleBufferRenderSynchronizer
    /// The current connection's sound; nil if it has none.
    private(set) var format: CMAudioFormatDescription?
    private var rate = 16000.0
    private var receiver: AVSampleBufferAudioRenderer.Receiver?
    /// The synchronizer time of the first frame since unmuting, and that frame's RTP timestamp.
    private var start: (time: CMTime, timestamp: UInt32)?

    init(synchronizer: AVSampleBufferRenderSynchronizer) {
        self.synchronizer = synchronizer
    }

    /// A new connection: its format, and timing from scratch.
    mutating func begin(format: CMAudioFormatDescription?) {
        receiver?.flush()
        start = nil
        self.format = format
        if let format { rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate ?? 16000 }
    }

    mutating func mute() {
        guard start != nil else { return }
        receiver?.flush()
        start = nil
    }

    /// One AAC frame (1024 samples), placed on the synchronizer's clock by its RTP timestamp.
    mutating func play(_ frame: AACFrame) {
        if receiver == nil { receiver = synchronizer.sampleBufferReceiver(adding: AVSampleBufferAudioRenderer()) }
        let now = synchronizer.currentTime()
        func time(_ start: (time: CMTime, timestamp: UInt32)) -> CMTime {
            let ticks = Int64(Int32(bitPattern: frame.timestamp &- start.timestamp))
            return start.time + CMTime(value: ticks, timescale: CMTimeScale(rate))
        }
        // Begin (or begin again, after falling behind) a little after now.
        if start == nil || time(start!) < now {
            if start != nil { receiver?.flush() }
            start = (now + CMTime(seconds: AudioOutput.delay, preferredTimescale: 90000), frame.timestamp)
        }
        guard let start, let format, let sample = AudioOutput.sample(frame.data, format: format, at: time(start)) else { return }
        _ = receiver?.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: sample))
    }
}

extension AppModel {
    /// Where the background service offers its camera streams to live views.
    var streamRelay: String { StreamRelay.path(nextTo: store.path) }
}

/// A stream is its own identity: its view stays with it, whichever place it has on the tile.
extension LiveStream: Identifiable {}
