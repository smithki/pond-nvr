// Talking back from the Home app: during a live view, the Home app's microphone comes back over the stream's
// audio port as SRTP (the same keys as the sound sent to it), AAC-ELD at the stream's rate, a few frames to a
// packet (RFC 3640, as Pond sends them). They're decoded, resampled to the rate the camera's speaker takes, and
// handed to it (the same talking as the app's, through the camera's own way: the ONVIF backchannel, say).
//
// The camera's speaker is opened with the first sound, not with the live view (watching doesn't hold it), and
// closed after a moment without any; what arrives while it opens is held, so the first words aren't lost.
// Muted in the Home app (its Speaker's Mute), nothing is sent; its Volume scales what is.
import Devices
import Foundation

final class Talkback: @unchecked Sendable {
    let socket: UDPSocket
    let open: @Sendable () async -> (any TalkSession)?
    let muted: @Sendable () -> Bool
    let volume: @Sendable () -> Double
    let log: @Sendable (String) -> Void
    private let sampleRate: Int
    private var receiver: SRTPReceiver
    private let lock = NSLock()
    private var stopped = false
    private var speaker: (any TalkSession)?
    private var opening = false
    /// Decoded while the speaker opens, at its rate once known (held as the stream's until then).
    private var held: [[UInt8]] = []
    private var decoder: ELDDecoder?
    private var lastSound = Date.distantPast
    private var packets = 0

    /// Silence this long, and the camera's speaker is let go.
    static let idle: TimeInterval = 2
    /// The most held while it opens: about two seconds of frames.
    static let holdFrames = 70

    init(socket: UDPSocket, masterKey: [UInt8], masterSalt: [UInt8], sampleRate: Int,
         open: @escaping @Sendable () async -> (any TalkSession)?, muted: @escaping @Sendable () -> Bool,
         volume: @escaping @Sendable () -> Double, log: @escaping @Sendable (String) -> Void) {
        self.socket = socket
        self.sampleRate = sampleRate
        receiver = SRTPReceiver(masterKey: masterKey, masterSalt: masterSalt)
        self.open = open
        self.muted = muted
        self.volume = volume
        self.log = log
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "homekit talkback"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        let speaker = lock.withLock { () -> (any TalkSession)? in
            stopped = true
            defer { self.speaker = nil }
            return self.speaker
        }
        speaker?.close()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func run() {
        while !isStopped {
            if let packet = socket.receive() { heard(packet) }
            // Quiet a while: the speaker is let go (opened again with the next sound).
            let idle = lock.withLock { () -> (any TalkSession)? in
                guard speaker != nil, Date().timeIntervalSince(lastSound) > Self.idle else { return nil }
                defer { speaker = nil; decoder = nil }
                return speaker
            }
            if let idle {
                idle.close()
                log("… HomeKit talkback: done (\(lock.withLock { packets }) packets)")
                lock.withLock { packets = 0 }
            }
        }
    }

    private func heard(_ packet: [UInt8]) {
        // Its reports (RTCP, types 200–204) aren't sound.
        guard packet.count > 12, !(200 ... 204).contains(packet[1]) else { return }
        guard let rtp = receiver.unprotect(packet) else { return }
        let headerLength = 12 + 4 * Int(rtp[0] & 0x0F)
        let frames = RTPPacketizer.aacFrames(inPayload: Array(rtp[headerLength...]))
        guard !frames.isEmpty, !muted() else { return }
        let (speaker, startOpening) = lock.withLock { () -> ((any TalkSession)?, Bool) in
            lastSound = Date()
            packets += 1
            guard self.speaker == nil else { return (self.speaker, false) }
            // Held until it opens (the oldest let go past a couple of seconds).
            held += frames
            if held.count > Self.holdFrames { held.removeFirst(held.count - Self.holdFrames) }
            defer { opening = true }
            return (nil, !opening)
        }
        if let speaker {
            send(frames, to: speaker)
        } else if startOpening {
            log("… HomeKit talkback: the Home app is talking; opening the camera's speaker")
            Task { [self] in await opened(await open()) }
        }
    }

    private func opened(_ speaker: (any TalkSession)?) async {
        guard let speaker else {
            log("! HomeKit talkback: the camera's speaker didn't open")
            lock.withLock {
                opening = false
                held = []
            }
            return
        }
        let waiting = lock.withLock { () -> [[UInt8]]? in
            opening = false
            guard !stopped else { return nil }
            self.speaker = speaker
            defer { held = [] }
            return held
        }
        guard let waiting else {
            speaker.close()
            return
        }
        log("✓ HomeKit talkback: talking through the camera's speaker at \(Int(speaker.sampleRate)) Hz")
        send(waiting, to: speaker)
    }

    private func send(_ frames: [[UInt8]], to speaker: any TalkSession) {
        let decoder = lock.withLock { () -> ELDDecoder? in
            if decoder == nil { decoder = ELDDecoder(sampleRate: sampleRate, outputRate: Int(speaker.sampleRate)) }
            return decoder
        }
        guard let decoder else {
            log("! HomeKit talkback: the Home app's sound can't be decoded")
            return
        }
        let gain = max(0, min(1, volume()))
        var samples: [Int16] = []
        for frame in frames { samples += decoder.decode(frame) }
        if gain < 1 { samples = samples.map { Int16(Double($0) * gain) } }
        guard !samples.isEmpty else { return }
        do throws(ControlFailure) {
            try speaker.send(samples)
        } catch {
            log("! HomeKit talkback: the camera's speaker stopped: \(error)")
            let lost = lock.withLock { () -> (any TalkSession)? in
                defer { self.speaker = nil; self.decoder = nil }
                return self.speaker
            }
            lost?.close()
        }
    }
}
