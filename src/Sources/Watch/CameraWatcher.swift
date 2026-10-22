// One camera, watched: its sub-stream (through the StreamHub, so the connection is shared with live view and
// HomeKit) decoded picture by picture; a few times a second, whether anything moved; while something did, the
// detection model on the picture; what it finds followed (Tracker) and made into events (EventBuilder), kept in
// the database with a picture of each. Nothing is watched while the camera is private.
import CoreVideo
import Detection
import Foundation
import ImageIO
import Ingest
import NVRCore
import UniformTypeIdentifiers

public final class CameraWatcher: @unchecked Sendable {
    public let camera: String
    let url: String
    let username: String
    let password: String
    let detector: SharedDetector
    let store: EventStore?
    /// The events folder: pictures go under its events/<camera>/<day>/.
    let eventsFolder: String
    let say: @Sendable (String) -> Void
    let rules: ZoneRules
    /// The main stream, for a closer look at what moves (nil: closer looks at the sub-stream's own picture).
    let tap: StreamTap?
    /// Told as events begin and end (for HomeKit's motion sensor, later).
    public var changed: (@Sendable (EventBuilder.Change) -> Void)?

    /// The kinds of thing whose sightings are kept.
    static let kept: Set<DetectedCategory> = [.person, .vehicle, .bike, .animal, .package, .item]

    /// Motion looked for this often.
    static let lookEvery: TimeInterval = 0.2
    /// The model run at most this often, while something moves.
    static let detectEvery: TimeInterval = 0.25
    /// And for this long after it stops.
    static let detectAfterMotion: TimeInterval = 2
    /// While something is followed but nothing moves, the model looks this often (to know it's still there).
    static let presenceLookEvery: TimeInterval = 2

    private let lock = NSLock()
    private var stopped = false

    public init(camera: String, url: String, username: String, password: String, detector: SharedDetector, store: EventStore?,
                eventsFolder: String, zones: [Config.Zone] = [], main: String? = nil, say: @escaping @Sendable (String) -> Void) {
        self.camera = camera
        self.url = url
        self.username = username
        self.password = password
        self.detector = detector
        self.store = store
        self.eventsFolder = eventsFolder
        self.say = say
        rules = ZoneRules(zones)
        tap = main.map { StreamTap(url: $0, username: username, password: password) }
    }

    var isStopped: Bool { lock.withLock { stopped } }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "watch \(camera)"
        thread.qualityOfService = .utility
        thread.start()
    }

    public func stop() {
        lock.withLock { stopped = true }
        tap?.stop()
    }

    // MARK: A doorbell's press

    private var ringing: [Date] = []

    /// The doorbell was pressed: an event, with the next picture decoded (the watcher's own, within a frame);
    /// without one if no picture comes in a few seconds (private, or the stream down).
    public func rang(at time: Date = Date()) {
        lock.withLock { ringing.append(time) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let time = lock.withLock({ () -> Date? in
                guard let i = ringing.firstIndex(of: time) else { return nil }
                return ringing.remove(at: i)
            }) else { return }
            Self.ring(camera: camera, at: time, store: store, say: say)
        }
    }

    /// A press kept as an event (its picture, if any, already saved).
    @discardableResult
    public static func ring(camera: String, at time: Date, id: String = UUID().uuidString, snapshot: String? = nil,
                            store: EventStore?, say: @Sendable (String) -> Void) -> CameraEvent {
        let event = CameraEvent(id: id, camera: camera, start: time, end: time, category: .ring, labels: ["doorbell": 1],
                                confidence: 1, snapshot: snapshot)
        store?.save(event, ongoing: false)
        say("doorbell pressed")
        return event
    }

    /// Any press waiting for a picture, with this one.
    private func answerRings(_ picture: CVPixelBuffer) {
        let waiting = lock.withLock { () -> [Date] in
            defer { ringing = [] }
            return ringing
        }
        for time in waiting {
            let event = CameraEvent(camera: camera, start: time, end: time, category: .ring)
            let snapshot = savePicture(picture, for: event)
            snapshots[event.id] = nil
            Self.ring(camera: camera, at: time, id: event.id, snapshot: snapshot, store: store, say: say)
        }
    }

    // MARK: Watching

    private var gate = MotionGate()
    private var tracker = Tracker()
    private lazy var builder = EventBuilder(camera: camera)
    private lazy var leftItems = LeftItems(camera: camera)

    private func run() {
        var pause = 2.0
        while !isStopped {
            if PrivacyState.shared.isPrivate(camera) {
                apply(builder.finish())
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            do {
                try watch()
                pause = 2
            } catch {
                if !isStopped { Thread.sleep(forTimeInterval: pause) }
                pause = min(pause * 2, 30)
            }
            apply(builder.finish())
        }
    }

    struct NotH264: Error {}

    /// Until the stream ends, the camera goes private, or the watcher is stopped.
    private func watch() throws {
        let source = try StreamHub.shared.open(url: url, username: username, password: password)
        defer { source.close() }
        guard source.video.encoding.uppercased() == "H264" else {
            say("not watched for detection: its sub-stream is \(source.video.encoding), not H.264")
            lock.withLock { stopped = true }
            throw NotH264()
        }
        var depacketizer = H264Depacketizer(spropParameterSets: source.video.format["sprop-parameter-sets"])
        let decoder = FrameDecoder()
        defer { decoder.close() }
        gate = MotionGate()
        gate.ignored = rules.ignoredCells(columns: gate.columns, rows: gate.rows)
        var lastLook = Date.distantPast, lastDetect = Date.distantPast, lastMotion = Date.distantPast
        var told = false
        // Each picture's time is when the camera took it (its RTP time, by the camera's sender reports), as the
        // recorder places the recording: so a box drawn over the recording is on the picture it was found in, not
        // the network's and the decoder's second or so later. (The Mac's clock until the first report.)
        var clock = RTPClock(rate: source.video.clockRate > 0 ? source.video.clockRate : 90000)
        var toldDelay = false
        var arrivalLag: Double?
        while !isStopped, !PrivacyState.shared.isPrivate(camera) {
            guard let packet = try source.next(timeout: 1) else {
                apply(builder.quiet(at: Date()))
                continue
            }
            if packet.channel == CameraSession.videoChannel + 1 {
                clock.noteRTCP(packet.data)
                continue
            }
            guard packet.channel == CameraSession.videoChannel, let rtp = RTPPacket(packet.data) else { continue }
            for unit in depacketizer.push(rtp) {
                // Each picture's leftovers let go with it (this thread runs for as long as the camera's watched: its
                // own pool would keep them all, and with them the decoder's pictures).
                autoreleasepool {
                    // Every picture decoded (each needs the ones before), only some looked at.
                    guard let picture = decoder.decode(unit.nalus, keyframe: unit.isKeyframe, damaged: unit.damaged,
                                                       sps: depacketizer.sps, pps: depacketizer.pps) else { return }
                    answerRings(picture)
                    if !told {
                        say("watching for detection (\(CVPixelBufferGetWidth(picture))×\(CVPixelBufferGetHeight(picture)))")
                        told = true
                    }
                    // On the recording's clock: when the picture arrived (smoothed, by the sub-stream's own times, so the
                    // watcher's own pauses don't show), less how long after their place in the recording the recorder's
                    // pictures arrive. Before the recorder has said: the sub-stream's own reports; before those, now.
                    let arrived = Date()
                    let taken = clock.wallTime(unit.timestamp).map { Date(timeIntervalSince1970: $0) }
                    if let taken { arrivalLag = arrivalLag.map { $0 * 0.95 + arrived.timeIntervalSince(taken) * 0.05 } ?? arrived.timeIntervalSince(taken) }
                    let now: Date
                    if let taken, let lag = arrivalLag, let recorded = StreamLatency.shared.recordedLag(camera) {
                        now = taken.addingTimeInterval(lag - recorded)
                    } else {
                        now = taken ?? arrived
                    }
                    if !toldDelay, let lag = arrivalLag, let recorded = StreamLatency.shared.recordedLag(camera) {
                        say(String(format: "on the recording's clock: its pictures arrive %.2f s after their place there, detection's %.2f s after theirs; moved %+.2f s", recorded, lag, lag - recorded))
                        toldDelay = true
                    }
                    guard now.timeIntervalSince(lastLook) >= Self.lookEvery else { return }
                    lastLook = now
                    let mask = motion(in: picture)
                    if mask.isMoving { lastMotion = now }
                    let moving = now.timeIntervalSince(lastMotion) <= Self.detectAfterMotion
                    // While something is followed (a dog lying down), or put down and waiting to be seen again, the model
                    // looks now and then though nothing moves: so it's known to be still there.
                    let present = tracker.following(EventBuilder.important) || builder.current != nil
                    let checking = (present && now.timeIntervalSince(lastDetect) >= Self.presenceLookEvery)
                        || (leftItems.isWaiting && now.timeIntervalSince(lastDetect) >= leftItems.lookEvery)
                    guard moving || checking else {
                        apply(builder.quiet(at: now))
                        return
                    }
                    guard checking || now.timeIntervalSince(lastDetect) >= Self.detectEvery else { return }
                    lastDetect = now
                    // The whole picture, and a closer look at what moves (at the main stream's resolution, once it's
                    // decoding: it starts with the motion).
                    let closer = mask.isMoving
                        ? tap?.picture(priority: tracker.following(EventBuilder.important) ? .following : .motion) : nil
                    guard let found = CloserLook.look(detector.detect, whole: picture, closer: closer, mask: mask)
                    else { return }
                    // What counts by the zones, with the zones it's in.
                    let counted = found.compactMap { d in rules.zones(for: d).map { (d, $0) } }
                    let sightings = tracker.update(counted.map(\.0), mask: mask, at: now) { d in
                        counted.first { $0.0 == d }?.1 ?? []
                    }
                    apply(builder.update(sightings, at: now), picture: picture)
                    // Kept, for drawing over the recording when it's played back: what matters, counted or not (an
                    // ignored one shows the zones at work), each with the track it was followed as.
                    store?.save(found.filter { Self.kept.contains($0.category) }.map { d in
                        Sighting(camera: camera, time: now, label: d.label, category: d.category, confidence: d.confidence, box: d.box,
                                 track: sightings.first { $0.track.box == d.box }?.track.id,
                                 counted: counted.contains { $0.0 == d })
                    })
                    let items = counted.filter { $0.0.category == .item }
                        .map { (detection: $0.0, zones: $0.1, moved: mask.overlaps(($0.0.box.x, $0.0.box.y, $0.0.box.width, $0.0.box.height))) }
                    for event in leftItems.update(items, people: found.filter { $0.category == .person }, at: now) {
                        left(event, picture: picture)
                    }
                }
            }
        }
    }

    private func motion(in picture: CVPixelBuffer) -> MotionMask {
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(picture) else { return MotionMask(columns: gate.columns, rows: gate.rows, cells: []) }
        let cells = MotionGate.cells(bgra: base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(picture),
                                     height: CVPixelBufferGetHeight(picture), stride: CVPixelBufferGetBytesPerRow(picture),
                                     columns: gate.columns, rows: gate.rows)
        return gate.moving(cells)
    }

    // MARK: Events

    /// Each change kept (and its picture, for a better one), told and logged.
    private func apply(_ changes: [EventBuilder.Change], picture: CVPixelBuffer? = nil) {
        for change in changes {
            switch change {
            case var .began(event):
                if let picture { event.snapshot = savePicture(picture, for: event) }
                snapshots[event.id] = event.snapshot
                store?.save(event, ongoing: true)
                say("\(event.category.rawValue) seen (\(Self.percent(event.confidence)))")
            case var .better(event):
                if let picture { event.snapshot = savePicture(picture, for: event) } else { event.snapshot = snapshots[event.id] }
                store?.save(event, ongoing: true)
            case var .ended(event):
                // (Its picture's path kept a while: the event may be taken up again.)
                event.snapshot = snapshots[event.id] ?? event.snapshot
                if snapshots.count > 20 { snapshots = snapshots.filter { $0.key == event.id } }
                store?.save(event, ongoing: false)
                say("event over after \(Int(event.seconds.rounded())) s: \(CameraEvent.words(event.labels))")
            case var .resumed(event):
                event.snapshot = snapshots[event.id] ?? event.snapshot
                store?.save(event, ongoing: true)
                say("\(event.category.rawValue) moving again: the event goes on")
            }
            changed?(change)
        }
    }

    /// Something left behind: an event of its own, begun and ended at once.
    private func left(_ event: CameraEvent, picture: CVPixelBuffer) {
        var event = event
        event.snapshot = savePicture(picture, for: event)
        snapshots[event.id] = nil
        store?.save(event, ongoing: false)
        say("\(event.labels.keys.sorted().joined(separator: ", ")) left (\(Self.percent(event.confidence)))")
        changed?(.began(event))
        changed?(.ended(event))
    }

    /// Each ongoing event's picture (relative path), as it was saved.
    private var snapshots: [String: String] = [:]

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd/HH-mm-ss"
        return f
    }()

    /// The picture as a JPEG in the events folder (the same file for an event, written again as it gets better);
    /// its path relative to the folder, or nil.
    private func savePicture(_ picture: CVPixelBuffer, for event: CameraEvent) -> String? {
        let relative = snapshots[event.id] ?? Self.eventFile(event, extension: "jpg")
        snapshots[event.id] = relative
        let path = (eventsFolder as NSString).appendingPathComponent(relative)
        // Copied out now: the decoder's picture isn't kept while the file waits to be written (see CloserLook).
        guard let image = Self.image(picture) else { return nil }
        Self.writing.async {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(out)
        }
        return relative
    }

    /// Where an event's files go, in the events folder: "events/<camera>/<day>/<time>-<id>.<extension>" (its
    /// picture, its clip), dated by its start (retention's sweep reads it from the name).
    public static func eventFile(_ event: CameraEvent, extension: String) -> String {
        "events/\(event.camera)/\(dayFormatter.string(from: event.start))-\(event.id.prefix(8).lowercased()).\(`extension`)"
    }

    /// A 32BGRA picture as an image of its own (its pixels copied).
    static func image(_ picture: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(picture) else { return nil }
        let width = CVPixelBufferGetWidth(picture), height = CVPixelBufferGetHeight(picture)
        let row = CVPixelBufferGetBytesPerRow(picture)
        guard let provider = CGDataProvider(data: Data(bytes: base, count: row * height) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static let writing = DispatchQueue(label: "pond.watch.pictures", qos: .utility)

    static func percent(_ confidence: Double) -> String { "\(Int((confidence * 100).rounded()))%" }
}

/// The one detection model, shared by every camera's watcher, one picture at a time.
public final class SharedDetector: @unchecked Sendable {
    public let detector: Detector
    private let lock = NSLock()
    private var failed = false
    let say: @Sendable (String) -> Void

    public init(detector: Detector = Detector(), say: @escaping @Sendable (String) -> Void) {
        self.detector = detector
        self.say = say
    }

    /// What's in the picture; nil if no model is loaded or it failed (said once).
    func detect(_ picture: CVPixelBuffer) -> [Detection]? {
        lock.withLock {
            do {
                let found = try detector.detect(picture)
                failed = false
                return found
            } catch {
                if !failed { say("! detection: \(error)") }
                failed = true
                return nil
            }
        }
    }
}
