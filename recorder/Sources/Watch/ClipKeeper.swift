// Each event's own clip: its stretch of the recording (and a few seconds either side), copied out of the continuous
// recording into a file of its own beside its picture, so it's kept as long as events are (event retention), not
// only as long as the minutes around it. Copied as recorded (no re-encoding), once the minute an event ended in is
// complete; older events too, as long as their recordings are there. One at a time, in the service's background.
import AVFoundation
import Foundation
import Recorder

public final class ClipKeeper: @unchecked Sendable {
    let store: EventStore
    let recordings: String
    let eventsFolder: String
    let log: @Sendable (String) -> Void
    private var task: Task<Void, Never>?

    /// Seconds kept either side of an event (as its details show it).
    public static let around: TimeInterval = 3
    /// How long after an event's end its clip waits (the minute being written then, complete and named).
    static let settle: TimeInterval = 75
    static let idle: Duration = .seconds(30)

    public init(store: EventStore, recordings: String, eventsFolder: String, log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.recordings = recordings
        self.eventsFolder = eventsFolder
        self.log = log
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [self] in await run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    func run() async {
        while !Task.isCancelled {
            // (The drive away: nothing to copy from, and nothing to be said of events until it's back.)
            guard FileManager.default.fileExists(atPath: recordings) else {
                try? await Task.sleep(for: Self.idle)
                continue
            }
            let batch = store.toClip(endedBefore: Date().addingTimeInterval(-(Self.around + Self.settle)), limit: 8)
            guard !batch.isEmpty else {
                try? await Task.sleep(for: Self.idle)
                continue
            }
            for event in batch {
                guard !Task.isCancelled else { return }
                await clip(event)
            }
        }
    }

    /// One event's clip made, and kept in the store; or noted as none (no recording of it).
    func clip(_ event: CameraEvent) async {
        let from = event.start.addingTimeInterval(-Self.around), to = event.end.addingTimeInterval(Self.around)
        let spans = RecordingIndex.spans(base: recordings, camera: event.camera, from: from, to: to, writing: false)
        // From the event's time, or from where the recording of it begins (a stretch before it, not black).
        guard let first = spans.first else { return store.clipped(event.id, clip: "", start: nil) }
        let origin = max(from, first.start)
        guard let (composition, _) = await RecordingComposition.make(spans, from: origin, to: to),
              let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return store.clipped(event.id, clip: "", start: nil)
        }
        let relative = event.snapshot.map { ($0 as NSString).deletingPathExtension + ".mp4" } ?? CameraWatcher.eventFile(event, extension: "mp4")
        let url = URL(fileURLWithPath: (eventsFolder as NSString).appendingPathComponent(relative))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        do {
            try await export.export(to: url, as: .mp4)
            store.clipped(event.id, clip: relative, start: origin)
        } catch {
            log("! clips: \(event.camera)'s event at \(event.start) couldn't be copied: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            store.clipped(event.id, clip: "", start: nil)
        }
    }
}
