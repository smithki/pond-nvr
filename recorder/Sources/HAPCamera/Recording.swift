// HomeKit Secure Video's side of a camera: the services the Home app needs to see before it offers
// recording (Camera Recording Management, Camera Operating Mode, Data Stream Transport Management), what
// the camera can record (all as HAP-NodeJS's RecordingManagement encodes them), and what the home hub
// chooses and switches on, kept across restarts. The clips themselves go over the data stream (`dataSend`),
// recorded from the camera's prebuffer and live stream by a RecordingSession.
import Foundation
import HAP
import Ingest
import Media
import PondCore

/// What the camera offers to record.
public struct RecordingOptions: Sendable {
    /// Milliseconds of video kept from before an event, and the length of each fragment sent.
    public var prebuffer = 4000
    public var fragmentLength = 4000
    /// What starts a recording: bit 0 motion, bit 1 a doorbell's button.
    public var eventTriggers: UInt32
    /// Recording's sizes, at HomeKit's usual rates. Offered only 18 fps (about a Reolink's own), the hub
    /// chose nothing and recorded nothing: so 30, and a camera's slower frames repeated to fill it.
    public var resolutions: [(Int, Int, Int)] = CameraStreamOptions.standard.resolutions
    /// AAC-LC at 16, 24, 32 or 48 kHz (HomeKit's indices 1, 2, 3, 5).
    public var sampleRates: [UInt8] = [1, 2, 3, 5]

    public init(doorbell: Bool) {
        eventTriggers = doorbell ? 0x03 : 0x01
    }

    static func le32(_ v: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }

    /// What is offered, as a digest: when it changes, the hub's choice is dropped (it chose among the old
    /// offers) and the configuration number goes up, so it looks again and chooses anew.
    public var digest: String {
        let all = supportedCameraRecording + [0xFF] + supportedVideoRecording + [0xFF] + supportedAudioRecording
        return all.reduce(into: UInt64(1469598103934665603)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }.description
    }

    /// Supported Camera Recording Configuration: the prebuffer, the triggers (8 bytes), fMP4 with its
    /// fragment length.
    public var supportedCameraRecording: [UInt8] {
        let container = CameraTLV.item(0x01, 0) + CameraTLV.item(0x02, CameraTLV.item(0x01, Self.le32(UInt32(fragmentLength))))
        return CameraTLV.item(0x01, Self.le32(UInt32(prebuffer)))
            + CameraTLV.item(0x02, Self.le32(eventTriggers) + [0, 0, 0, 0])
            + CameraTLV.item(0x03, container)
    }

    /// Supported Video Recording Configuration: H.264, its profiles and levels, and the sizes.
    public var supportedVideoRecording: [UInt8] {
        let parameters = CameraTLV.list(0x01, [[0], [1], [2]]) + CameraTLV.list(0x02, [[0], [1], [2]])
        let attributes = CameraTLV.list(0x03, resolutions.map { w, h, fps in
            CameraTLV.item(0x01, CameraTLV.uint16(w)) + CameraTLV.item(0x02, CameraTLV.uint16(h)) + CameraTLV.item(0x03, UInt8(fps))
        })
        return CameraTLV.item(0x01, CameraTLV.item(0x01, 0) + CameraTLV.item(0x02, parameters) + attributes)
    }

    /// Supported Audio Recording Configuration: AAC-LC, mono, variable bit rate, at the sample rates.
    public var supportedAudioRecording: [UInt8] {
        let parameters = CameraTLV.item(0x01, 1) + CameraTLV.item(0x02, 0) + CameraTLV.list(0x03, sampleRates.map { [$0] })
        return CameraTLV.item(0x01, CameraTLV.item(0x01, 0) + CameraTLV.item(0x02, parameters))
    }
}

/// What the home hub chose to record (Selected Camera Recording Configuration).
public struct SelectedRecording: Equatable, Sendable {
    public var prebuffer: Int
    public var eventTriggers: UInt32
    public var fragmentLength: Int
    public var profile: Int
    public var level: Int
    /// kbit/s.
    public var bitrate: Int
    /// Milliseconds between keyframes.
    public var keyframeInterval: Int
    public var width: Int
    public var height: Int
    public var fps: Int
    /// 0 AAC-LC, 1 AAC-ELD.
    public var audioCodec: Int
    public var audioChannels: Int
    /// HomeKit's sample rate index (1: 16 kHz, 2: 24, 3: 32, 4: 44.1, 5: 48).
    public var sampleRate: Int
    /// kbit/s.
    public var audioBitrate: Int

    public init?(_ bytes: [UInt8]) {
        func tlv(_ b: [UInt8]?) -> [TLV8Item]? { b.flatMap { try? TLV8.decode($0) } }
        func i32(_ b: [UInt8]?) -> Int? {
            guard let b, b.count >= 4 else { return nil }
            return Int(Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        }
        func u16(_ b: [UInt8]?) -> Int? { guard let b, b.count >= 2 else { return nil }; return Int(b[0]) | Int(b[1]) << 8 }
        guard let top = tlv(bytes), let recording = tlv(top.value(0x01)), let video = tlv(top.value(0x02)),
              let audio = tlv(top.value(0x03)), let container = tlv(recording.value(0x03)),
              let containerParameters = tlv(container.value(0x02)), let videoParameters = tlv(video.value(0x02)),
              let attributes = tlv(video.value(0x03)), let audioParameters = tlv(audio.value(0x02)),
              let prebuffer = i32(recording.value(0x01)), let triggers = i32(recording.value(0x02)),
              let fragment = i32(containerParameters.value(0x01)), let bitrate = i32(videoParameters.value(0x03)),
              let keyframes = i32(videoParameters.value(0x04)), let width = u16(attributes.value(0x01)),
              let height = u16(attributes.value(0x02)) else { return nil }
        self.prebuffer = prebuffer
        eventTriggers = UInt32(truncatingIfNeeded: triggers)
        fragmentLength = fragment
        profile = Int(videoParameters.value(0x01)?.first ?? 1)
        level = Int(videoParameters.value(0x02)?.first ?? 2)
        self.bitrate = bitrate
        keyframeInterval = keyframes
        self.width = width
        self.height = height
        fps = Int(attributes.value(0x03)?.first ?? 30)
        audioCodec = Int(audio.value(0x01)?.first ?? 0)
        audioChannels = Int(audioParameters.value(0x01)?.first ?? 1)
        sampleRate = Int(audioParameters.value(0x03)?.first ?? 1)
        audioBitrate = i32(audioParameters.value(0x04)) ?? 32
    }
}

/// What HomeKit Secure Video has been set to for a camera, kept with its HomeKit record.
public struct RecordingState: Codable, Equatable, Sendable {
    /// The hub's choice, as it wrote it (read back as is).
    public var selected: [UInt8]?
    /// The offers it chose among (RecordingOptions.digest).
    public var offered: String?
    /// Recording on (Camera Recording Management's Active).
    public var active = false
    public var audioActive = false
    /// The camera on in HomeKit at all (Camera Operating Mode), and its snapshots.
    public var cameraActive = true
    public var eventSnapshots = true
    public var periodicSnapshots = true
    /// The last recording sent, for the app (kept across restarts).
    public var lastClip: HomeKitStatus.Recording.Clip?
    /// When the hub last turned recording off after having it on, and its latest changes (HomeKitStatus.Recording).
    public var onUntil: Date?
    public var changes: [HomeKitStatus.Recording.Change]?
    /// The most changes kept.
    static let changesKept = 10

    public init() {}
}

/// A camera's recording services and their state: answers the hub's writes, keeps them, and serves the data
/// stream they come with.
public final class RecordingController: @unchecked Sendable {
    public let options: RecordingOptions
    public let dataStream = DataStreamServer()
    private let lock = NSLock()
    private var state: RecordingState
    private var lastSetupResponse: [UInt8] = []
    /// The camera's last seconds, for recordings; nil without a stream to read. And its sub-stream's: a recording
    /// is made from it instead while the media engine is full (MediaBudget).
    let prebuffer: Prebuffer?
    let subPrebuffer: Prebuffer?
    let budget: MediaBudget
    /// The recording going on's share of the media engine.
    private var grant: MediaBudget.Grant?
    /// The recording going on (the hub records one at a time).
    private var session: RecordingSession?
    /// Called with the state whenever it changes, to keep it.
    var saved: (@Sendable (RecordingState) -> Void)?
    /// Private in Pond: off in HomeKit whatever the Home app has set (which is kept, `state.cameraActive`, and
    /// shown again when privacy ends). The Home app's own on and off stays HomeKit's: it never changes Pond's
    /// privacy (the hub writes it again whenever it reconnects, and with home and away automations).
    private var privateInPond = false
    /// Camera Operating Mode's HomeKit Camera Active and the sensors' Status Active, to change from here.
    private var cameraActiveCharacteristic: Characteristic?
    private var statusActiveCharacteristics: [Characteristic] = []
    /// Told how recording is going, for the app (HomeKitStatus).
    var statusChanged: (@Sendable (HomeKitStatus.Recording) -> Void)?
    private var status = HomeKitStatus.Recording()
    /// Whether the status has been told to a listener at all: until then it is told even unchanged.
    private var told = false

    /// The status, changed by `edit` (and told on, if it changed).
    func report(_ edit: (inout HomeKitStatus.Recording) -> Void) {
        let changed = lock.withLock { () -> HomeKitStatus.Recording? in
            var next = status
            let s = state
            next.on = s.active && s.cameraActive && !privateInPond
            next.sound = s.audioActive
            next.chosen = s.selected != nil
            if next.lastClip == nil { next.lastClip = s.lastClip }
            next.onUntil = s.onUntil
            next.changes = s.changes
            edit(&next)
            guard next != status || !told else { return nil }
            status = next
            // Told only once there is someone to tell (the setup reports before the host listens).
            told = statusChanged != nil
            return next
        }
        if let changed { statusChanged?(changed) }
    }
    let log: @Sendable (String) -> Void

    /// The camera's id (for the copies of its recordings kept while looking into them; see RecordingSession).
    /// Nil (a test's): none kept.
    var camera: String?

    init(options: RecordingOptions, state: RecordingState?, source: (url: String, username: String, password: String)? = nil,
         subSource: (url: String, username: String, password: String)? = nil, prebuffer given: Prebuffer? = nil,
         budget: MediaBudget = .shared, log: @escaping @Sendable (String) -> Void) {
        self.budget = budget
        self.options = options
        var kept = state ?? RecordingState()
        // Offers changed since the hub chose: its choice goes, and it chooses again.
        if kept.selected != nil, kept.offered != options.digest {
            kept.selected = nil
            log("HomeKit: what the camera offers to record changed; the hub will choose again")
        }
        kept.offered = options.digest
        self.state = kept
        self.log = log
        // The prebuffer the camera offers, and a keyframe's worth more to start from.
        if let given {
            prebuffer = given
            subPrebuffer = nil
        } else {
            prebuffer = source.map { Prebuffer(source: $0, seconds: Double(options.prebuffer) / 1000 + 5, log: log) }
            prebuffer?.start()
            // (Packets only, a few seconds of them: nothing decoded until a recording needs it.)
            subPrebuffer = subSource.flatMap { $0.url.isEmpty || $0.url == source?.url ? nil : Prebuffer(source: $0, seconds: Double(options.prebuffer) / 1000 + 5, log: log) }
            subPrebuffer?.start()
        }
        dataStream.log = log
        dataStream.handler = { [weak self] message, connection in self?.received(message, on: connection) }
    }

    public var current: RecordingState { lock.withLock { state } }

    /// On in HomeKit: the Home app has it on, and it isn't private in Pond.
    var cameraOn: Bool { lock.withLock { state.cameraActive && !privateInPond } }

    /// Private in Pond or not: the Home app told the camera is off, or as it had it again.
    func setPrivate(_ isPrivate: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { privateInPond = isPrivate }
            return privateInPond != isPrivate
        }
        guard changed else { return }
        tellCameraOn()
        report { _ in }
    }

    /// Tells the Home app whether the camera is on, and its sensors whether they're active.
    private func tellCameraOn() {
        let on = cameraOn
        let (characteristic, sensors) = lock.withLock { (cameraActiveCharacteristic, statusActiveCharacteristics) }
        characteristic?.update(.int(on ? 1 : 0))
        for status in sensors { status.update(.bool(on)) }
    }

    func change(_ edit: (inout RecordingState) -> Void) {
        let (next, said) = lock.withLock { () -> (RecordingState?, String?) in
            var s = state
            edit(&s)
            guard s != state else { return (nil, nil) }
            // Recording or the camera turned on or off by the hub (its Recording Options for the home's mode, home or
            // away, an automation, or someone in the Home app): kept, and said in the log, as only what's so now
            // reaches the camera.
            var said: String?
            if s.active != state.active || s.cameraActive != state.cameraActive {
                let now = Date()
                if state.active, !s.active { s.onUntil = now }
                var changes = s.changes ?? []
                changes.append(.init(at: now, recording: s.active, camera: s.cameraActive))
                s.changes = Array(changes.suffix(RecordingState.changesKept))
                said = "HomeKit: the hub set recording \(s.active ? "on" : "off"), the camera \(s.cameraActive ? "on" : "off")"
                    + " (snapshots: event \(s.eventSnapshots ? "on" : "off"), periodic \(s.periodicSnapshots ? "on" : "off"))"
            }
            state = s
            return (s, said)
        }
        if let said { log(said) }
        if let next {
            saved?(next)
            report { _ in }
        }
    }

    // MARK: - The services

    /// Camera Recording Management, Camera Operating Mode and Data Stream Transport Management, with
    /// `sensors` (the motion sensor, a doorbell) linked to the first.
    func services(sensors: [Service], statusActive: [Characteristic]) -> [Service] {
        let s = current
        let active = Characteristic(type: HAPType.active, format: .uint8, permissions: [.read, .write, .notify],
                                    value: .int(s.active ? 1 : 0))
        active.onWrite = { [weak self] value throws(HAPStatus) in
            guard let on = value.flag else { throw .invalidValue }
            // (Said in the log by `change`, when it changes.)
            self?.change { $0.active = on }
            return nil
        }
        let selected = Characteristic(type: HAPType.selectedCameraRecordingConfiguration, format: .tlv8,
                                      permissions: [.read, .write, .notify], value: .tlv8(s.selected ?? []))
        selected.onWrite = { [weak self] value throws(HAPStatus) in
            guard case let .tlv8(bytes) = value, let choice = SelectedRecording(bytes) else { throw .invalidValue }
            self?.change { $0.selected = bytes }
            self?.log("… HomeKit: the hub chose to record \(choice.width)×\(choice.height) at \(choice.fps) fps, \(choice.bitrate) kbit/s, a keyframe every \(choice.keyframeInterval) ms, \(choice.fragmentLength) ms fragments, profile \(choice.profile) level \(choice.level), sound codec \(choice.audioCodec) rate \(choice.sampleRate)")
            return nil
        }
        let audio = Characteristic(type: HAPType.recordingAudioActive, format: .uint8,
                                   permissions: [.read, .write, .notify, .timedWrite], value: .int(s.audioActive ? 1 : 0))
        audio.onWrite = { [weak self] value throws(HAPStatus) in
            guard let on = value.flag else { throw .invalidValue }
            self?.change { $0.audioActive = on }
            self?.log("HomeKit: recording sound \(on ? "on" : "off")")
            return nil
        }
        let management = Service(type: HAPType.cameraRecordingManagement, [
            active,
            selected,
            Characteristic(type: HAPType.supportedCameraRecordingConfiguration, format: .tlv8, permissions: [.read, .notify],
                           value: .tlv8(options.supportedCameraRecording)),
            Characteristic(type: HAPType.supportedVideoRecordingConfiguration, format: .tlv8, permissions: [.read, .notify],
                           value: .tlv8(options.supportedVideoRecording)),
            Characteristic(type: HAPType.supportedAudioRecordingConfiguration, format: .tlv8, permissions: [.read, .notify],
                           value: .tlv8(options.supportedAudioRecording)),
            audio,
        ])

        let cameraActive = Characteristic(type: HAPType.homeKitCameraActive, format: .uint8, permissions: [.read, .write, .notify],
                                          value: .int(cameraOn ? 1 : 0))
        cameraActive.onWrite = { [weak self] value throws(HAPStatus) in
            guard let self, let on = value.flag else { throw .invalidValue }
            // Kept as the Home app's; the camera off in HomeKit, its sensors say so. Private in Pond, it stays
            // off: said again just after this write is answered.
            change { $0.cameraActive = on }
            for status in statusActive { status.update(.bool(cameraOn)) }
            if on, lock.withLock({ privateInPond }) {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.tellCameraOn() }
            }
            return nil
        }
        lock.withLock {
            cameraActiveCharacteristic = cameraActive
            statusActiveCharacteristics = statusActive
        }
        let eventSnapshots = Characteristic(type: HAPType.eventSnapshotsActive, format: .uint8, permissions: [.read, .write, .notify],
                                            value: .int(s.eventSnapshots ? 1 : 0))
        eventSnapshots.onWrite = { [weak self] value throws(HAPStatus) in
            guard let on = value.flag else { throw .invalidValue }
            self?.change { $0.eventSnapshots = on }
            return nil
        }
        let periodicSnapshots = Characteristic(type: HAPType.periodicSnapshotsActive, format: .uint8,
                                               permissions: [.read, .write, .notify], value: .int(s.periodicSnapshots ? 1 : 0))
        periodicSnapshots.onWrite = { [weak self] value throws(HAPStatus) in
            guard let on = value.flag else { throw .invalidValue }
            self?.change { $0.periodicSnapshots = on }
            return nil
        }
        let operatingMode = Service(type: HAPType.cameraOperatingMode, [eventSnapshots, cameraActive, periodicSnapshots])

        let setup = Characteristic(type: DataStream.setupTransport, format: .tlv8, permissions: [.read, .write, .writeResponse],
                                   value: .tlv8([]))
        setup.onWrite = { [weak self] value throws(HAPStatus) in
            guard let self, case let .tlv8(bytes) = value else { throw .invalidValue }
            let response = dataStream.setup(bytes, sharedSecret: HAPRequest.session?.sharedSecret)
            // Read back later without the accessory's salt, as HAP-NodeJS does.
            lock.withLock { lastSetupResponse = (try? TLV8.decode(response)).map { TLV8.encode($0.filter { $0.type != 0x03 }) } ?? [] }
            return .tlv8(response)
        }
        let dataStreamService = Service(type: HAPType.dataStreamTransportManagement, [
            setup,
            Characteristic(type: DataStream.supportedTransportConfiguration, format: .tlv8, permissions: [.read],
                           value: .tlv8(DataStream.supportedConfiguration)),
            Characteristic(type: HAPType.version, format: .string, permissions: [.read], value: .string(DataStream.version)),
        ])
        management.linked = [dataStreamService] + sensors
        return [management, operatingMode, dataStreamService]
    }

    // MARK: - The data stream

    func received(_ message: DataStream.Message, on connection: DataStreamConnection) {
        guard message.protocol == "dataSend" else {
            if message.kind == .request { connection.send(message.response(status: 5)) }   // a protocol we don't speak
            return
        }
        switch (message.kind, message.topic) {
        case (.request, "open"): open(message, on: connection)
        case (.event, "close"):
            let id = message.body["streamId"]?.int
            let ending = lock.withLock { () -> RecordingSession? in
                guard let s = session, s.streamID == id else { return nil }
                session = nil
                return s
            }
            ending?.close(reason: message.body["reason"]?.int)
        case (.event, "ack"):
            log("… HomeKit: the hub acknowledged recording stream \(message.body["streamId"]?.int.map(String.init) ?? "?")")
        default:
            log("HomeKit: a dataSend \(message.topic) from the hub, not expected")
        }
    }

    /// The hub asks to record: refused unless recording is on, the camera active in HomeKit, a configuration
    /// chosen and no other recording going; else started.
    private func open(_ message: DataStream.Message, on connection: DataStreamConnection) {
        func refuse(_ reason: Int64, _ why: String, _ kind: HomeKitStatus.RecordingProblem.Kind) {
            log("! HomeKit: a recording refused: \(why)")
            report { $0.problem = .init(kind) }
            connection.send(message.response(status: 6, body: .dictionary([("status", .int(reason))])))
        }
        let s = current
        guard message.body["type"]?.string == "ipcamera.recording", message.body["target"]?.string == "controller",
              let streamID = message.body["streamId"]?.int else { return refuse(5, "a request Pond doesn't know", .other) }
        guard s.active, s.cameraActive else { return refuse(1, "recording is off in the Home app", .notAllowed) }
        // Not a problem to show: private by choice.
        if lock.withLock({ privateInPond }) {
            log("HomeKit: a recording asked while the camera is private; refused")
            connection.send(message.response(status: 6, body: .dictionary([("status", .int(1))])))
            return
        }
        guard let bytes = s.selected, let selected = SelectedRecording(bytes) else {
            return refuse(9, "no recording settings chosen", .notChosen)
        }
        guard let prebuffer else { return refuse(5, "no camera stream to record", .noVideo) }
        guard lock.withLock({ session == nil }) else {
            // The hub records one at a time: a second ask while one goes is no fault worth showing.
            log("HomeKit: a second recording asked while one goes; refused (busy)")
            connection.send(message.response(status: 6, body: .dictionary([("status", .int(2))])))
            return
        }
        // Its share of the media engine: the main stream decoded and encoded for the hub; when that doesn't fit (beside
        // other recordings and live re-encoding), the sub-stream instead. Never turned down.
        let encode = MediaBudget.encode(width: selected.width, height: selected.height, fps: Double(selected.fps))
        let cost = MediaBudget.decode(sps: prebuffer.sps, fallback: (3840, 2160)) + encode
        let reduced = subPrebuffer.map { MediaBudget.decode(sps: $0.sps, fallback: (640, 360)) + encode }
        let answer = budget.claim(.homeKitRecording, cost: cost, label: "\(camera ?? "a camera")'s HomeKit recording", reduced: reduced)
        var source = prebuffer
        switch answer {
        case let .granted(g): lock.withLock { grant = g }
        case let .reduced(g):
            lock.withLock { grant = g }
            if let subPrebuffer { source = subPrebuffer }
        case .refused: break
        }
        let session = RecordingSession(camera: camera, streamID: streamID, connection: connection, selected: selected,
                                       audio: s.audioActive ? audioTrack(for: selected, prebuffer: source) : nil,
                                       prebuffer: source, log: log)
        // Done (closed by the hub, or its connection): the clip it made, or the hub's error.
        session.finished = { [weak self] clip, reason in
            // Its share given back.
            self?.lock.withLock { () -> MediaBudget.Grant? in
                defer { self?.grant = nil }
                return self?.grant
            }?.release()
            if let clip { self?.change { $0.lastClip = clip } }
            self?.report { status in
                status.recording = false
                if let clip { status.lastClip = clip }
                status.problem = (reason ?? 0) == 0 ? nil : .init(.cutShort)
            }
        }
        report { $0.recording = true }
        lock.withLock { self.session = session }
        connection.onClose = { [weak self, weak session] in
            guard let self, let session else { return }
            let mine = self.lock.withLock { () -> Bool in
                guard self.session === session else { return false }
                self.session = nil
                return true
            }
            if mine { session.close(reason: nil) }
        }
        connection.send(message.response(status: 0, body: .dictionary([("status", .int(0))])))
        log("… HomeKit: the hub asked to record (\(message.body["reason"]?.string ?? "no reason given"))")
        session.start()
    }

    /// The camera's sound as the hub chose it: AAC-LC at the camera's own sample rate, passed through; else
    /// none (said in the log).
    private func audioTrack(for selected: SelectedRecording, prebuffer: Prebuffer) -> AudioTrack? {
        guard let hex = prebuffer.audioConfig, let config = AACConfig(hex: hex) else { return nil }
        let rates = [1: 16000, 2: 24000, 3: 32000, 4: 44100, 5: 48000]
        guard selected.audioCodec == 0, rates[selected.sampleRate] == config.sampleRate else {
            log("! HomeKit: the hub chose sound the camera doesn't send as is; recording without it")
            return nil
        }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), i < hex.endIndex {
            if let b = UInt8(hex[i ..< j], radix: 16) { bytes.append(b) }
            i = j
        }
        return AudioTrack(config: bytes, sampleRate: config.sampleRate, channels: config.channels)
    }

    func stop() {
        dataStream.stop()
        prebuffer?.stop()
        subPrebuffer?.stop()
        lock.withLock { session }?.close(reason: nil)
        lock.withLock { () -> MediaBudget.Grant? in
            defer { grant = nil }
            return grant
        }?.release()
    }
}

extension HAPValue {
    /// A uint8 or bool written as on or off.
    var flag: Bool? {
        switch self {
        case let .int(i): i != 0
        case let .bool(b): b
        default: nil
        }
    }
}
