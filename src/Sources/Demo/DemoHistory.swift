// A demo's first hours: on a scenario's first start, the last three hours made as if Pond had been recording them,
// so the timeline and events have something to show at once. Each camera's past drawn and encoded faster than real
// time (the sub-stream's size, five pictures a second) and written as the recorder writes, a segment a minute; and
// what its script put in front of it made into events as the watcher makes them (followed, kept, with a picture of
// each). The rest comes as it would for any events: their clips are copied out of the recordings, and their
// sentences written, by the service as usual.
import CoreGraphics
import Detection
import Foundation
import ImageIO
import Ingest
import NVRCore
import Recorder
import UniformTypeIdentifiers
import Watch

public enum DemoHistory {
    /// How far back a demo's history goes.
    public static let hours = 3.0
    /// In the scenario's folder once its history's made (made once, never again).
    static let marker = "history.json"
    /// How much is made at a time.
    static let piece = 15 * 60.0

    /// Made, if this world's history hasn't been (in the background: the service records and watches meanwhile).
    public static func makeIfNew(world: DemoWorld, config: Config, store: EventStore?, log: any EventLog) {
        guard let folder = Demo.folder else { return }
        let marked = (folder as NSString).appendingPathComponent(marker)
        guard !FileManager.default.fileExists(atPath: marked) else { return }
        let to = Date(), from = to.addingTimeInterval(-hours * 3600)
        // (Marked at once: a service stopped partway leaves what it made, and doesn't make it twice.)
        try? JSONEncoder().encode(["from": from, "to": to]).write(to: URL(fileURLWithPath: marked))
        let cameras = config.cameras.filter { !PrivacyState.shared.isPrivate($0.id) }
        guard !cameras.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            log.log("pond", "making the demo's last \(Int(hours)) hours")
            let started = Date()
            // A quarter of an hour at a time, the latest first (so what's just before now is there soonest), each
            // recorded before its events are made (whose clips come from the recording).
            DispatchQueue.concurrentPerform(iterations: cameras.count) { i in
                let camera = cameras[i]
                var end = to
                while end > from {
                    let start = max(from, end.addingTimeInterval(-piece))
                    record(camera, world: world, from: start, to: end, recordings: config.storage.recordingsPath, log: log)
                    events(camera, world: world, from: start, to: end, store: store, eventsFolder: config.storage.eventsPath)
                    end = start
                }
            }
            log.log("pond", String(format: "the demo's last %.0f hours made, in %.0f s", hours, Date().timeIntervalSince(started)))
        }
    }

    /// A camera's past, recorded as the recorder would have.
    static func record(_ camera: Config.Camera, world: DemoWorld, from: Date, to: Date, recordings: String, log: any EventLog) {
        guard let stream = try? DemoStream(url: camera.main, world: world, replaying: from, to: to, fps: 5) else { return }
        defer { stream.close() }
        let files = SegmentFiles(root: recordings, camera: camera.id, log: log)
        let recorder = StreamRecorder(video: stream.video, audio: nil, segmentSeconds: 60)
        var now = from
        while true {
            let packet: InterleavedPacket?
            do { packet = try stream.next(timeout: 1) } catch { break }
            guard let packet else { continue }
            autoreleasepool {
                files.handle(recorder.handle(packet, now: now.timeIntervalSince1970))
                if let placed = recorder.lastPlaced { now = Date(timeIntervalSince1970: placed) }
            }
        }
        files.handle(recorder.finish())
    }

    /// What its script put in front of it, made into events: looked at twice a second, as the watcher looks.
    static func events(_ camera: Config.Camera, world: DemoWorld, from: Date, to: Date, store: EventStore?, eventsFolder: String) {
        guard let store, let demo = world.camera(world.demoID(camera.id)) else { return }
        let painter = DemoPainter(camera: demo, world: world, width: demo.subSize.width, height: demo.subSize.height)
        var tracker = Tracker()
        var builder = EventBuilder(camera: camera.id)
        var pictures: [String: String] = [:]
        func apply(_ changes: [EventBuilder.Change], at t: Date) {
            for change in changes {
                switch change {
                case var .began(event), var .better(event):
                    event.snapshot = picture(painter, at: t, for: event, in: eventsFolder, as: pictures[event.id])
                    pictures[event.id] = event.snapshot
                    store.save(event, ongoing: true)
                case var .ended(event):
                    event.snapshot = pictures[event.id] ?? event.snapshot
                    store.save(event, ongoing: false)
                case var .resumed(event):
                    event.snapshot = pictures[event.id] ?? event.snapshot
                    store.save(event, ongoing: true)
                }
            }
        }
        var t = from
        while t < to {
            let found = world.detections(camera.id, at: t).filter { CameraWatcher.kept.contains($0.category) }
            if found.isEmpty {
                apply(builder.quiet(at: t), at: t)
            } else {
                // (What the script draws is always on the move: the whole picture moving, as far as following goes.)
                let moving = MotionMask(columns: 1, rows: 1, cells: [0])
                let sightings = tracker.update(found, mask: moving, at: t)
                apply(builder.update(sightings, at: t), at: t)
                store.save(found.map { d in
                    Sighting(camera: camera.id, time: t, label: d.label, category: d.category, confidence: d.confidence, box: d.box,
                             track: sightings.first { $0.track.box == d.box }?.track.id, counted: true)
                })
            }
            t = t.addingTimeInterval(CameraWatcher.detectEvery)
        }
        // Whatever's still going at the end, ended there (the live watcher takes up from now).
        apply(builder.quiet(at: to.addingTimeInterval(600)), at: to)
    }

    /// The picture at `t` as the event's JPEG (written over an earlier one of its own); its path in the events folder.
    static func picture(_ painter: DemoPainter, at t: Date, for event: CameraEvent, in folder: String, as kept: String?) -> String? {
        let relative = kept ?? CameraWatcher.eventFile(event, extension: "jpg")
        let path = (folder as NSString).appendingPathComponent(relative)
        guard let context = CGContext(data: nil, width: painter.width, height: painter.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        painter.paint(context, at: t)
        guard let image = context.makeImage() else { return nil }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(out) ? relative : nil
    }
}
