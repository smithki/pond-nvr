// One camera, watched: its sub-stream (through the StreamHub, so the connection is shared with live view and
// HomeKit) decoded picture by picture; a few times a second, whether anything moved; while something did, the
// detection model on the picture; what it finds followed (Tracker) and made into events (EventBuilder), kept in
// the database with a picture of each. Nothing is watched while the camera is private.
import CoreImage
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
    /// Told as events begin and end (for HomeKit's motion sensor, later).
    public var changed: (@Sendable (EventBuilder.Change) -> Void)?

    /// Motion looked for this often.
    static let lookEvery: TimeInterval = 0.2
    /// The model run at most this often, while something moves.
    static let detectEvery: TimeInterval = 0.25
    /// And for this long after it stops (someone standing still at the door is still there).
    static let detectAfterMotion: TimeInterval = 2

    private let lock = NSLock()
    private var stopped = false

    public init(camera: String, url: String, username: String, password: String, detector: SharedDetector, store: EventStore?,
                eventsFolder: String, zones: [Config.Zone] = [], say: @escaping @Sendable (String) -> Void) {
        self.camera = camera
        self.url = url
        self.username = username
        self.password = password
        self.detector = detector
        self.store = store
        self.eventsFolder = eventsFolder
        self.say = say
        rules = ZoneRules(zones)
    }

    var isStopped: Bool { lock.withLock { stopped } }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "watch \(camera)"
        thread.qualityOfService = .utility
        thread.start()
    }

    public func stop() { lock.withLock { stopped = true } }

    // MARK: Watching

    private var gate = MotionGate()
    private var tracker = Tracker()
    private lazy var builder = EventBuilder(camera: camera)

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
        while !isStopped, !PrivacyState.shared.isPrivate(camera) {
            guard let packet = try source.next(timeout: 1) else {
                apply(builder.quiet(at: Date()))
                continue
            }
            guard packet.channel == CameraSession.videoChannel, let rtp = RTPPacket(packet.data) else { continue }
            for unit in depacketizer.push(rtp) {
                // Every picture decoded (each needs the ones before), only some looked at.
                guard let picture = decoder.decode(unit.nalus, keyframe: unit.isKeyframe, damaged: unit.damaged,
                                                   sps: depacketizer.sps, pps: depacketizer.pps) else { continue }
                if !told {
                    say("watching for detection (\(CVPixelBufferGetWidth(picture))×\(CVPixelBufferGetHeight(picture)))")
                    told = true
                }
                let now = Date()
                guard now.timeIntervalSince(lastLook) >= Self.lookEvery else { continue }
                lastLook = now
                let mask = motion(in: picture)
                if mask.isMoving { lastMotion = now }
                guard now.timeIntervalSince(lastMotion) <= Self.detectAfterMotion else {
                    apply(builder.quiet(at: now))
                    continue
                }
                guard now.timeIntervalSince(lastDetect) >= Self.detectEvery else { continue }
                lastDetect = now
                guard let found = detector.detect(picture) else { continue }
                // What counts by the zones, with the zones it's in.
                let counted = found.compactMap { d in rules.zones(for: d).map { (d, $0) } }
                let sightings = tracker.update(counted.map(\.0), mask: mask, at: now) { d in
                    counted.first { $0.0 == d }?.1 ?? []
                }
                apply(builder.update(sightings, at: now), picture: picture)
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
                event.snapshot = snapshots.removeValue(forKey: event.id) ?? event.snapshot
                store?.save(event, ongoing: false)
                let seen = event.labels.sorted { $0.key < $1.key }.map { $0.value > 1 ? "\($0.value) \($0.key)s" : $0.key }
                say("event over after \(Int(event.seconds.rounded())) s: \(seen.joined(separator: ", "))")
            }
            changed?(change)
        }
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
        let relative = snapshots[event.id]
            ?? "events/\(camera)/\(Self.dayFormatter.string(from: event.start))-\(event.id.prefix(8).lowercased()).jpg"
        snapshots[event.id] = relative
        let path = (eventsFolder as NSString).appendingPathComponent(relative)
        let context = Self.context
        nonisolated(unsafe) let picture = picture
        Self.writing.async {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard let image = context.createCGImage(CIImage(cvPixelBuffer: picture), from: CGRect(
                x: 0, y: 0, width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture))),
                let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(out)
        }
        return relative
    }

    static let context = CIContext()
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
