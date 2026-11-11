// The service's understanding of events, for search: for each ended event with a picture, a sentence (the Mac's own
// language model, when Apple Intelligence is on) and embeddings of the picture and of a close-up of what began it
// (SigLIP 2, when there's a version of it on the Mac). One at a time, in the background, newest first: those that
// come in, and the older ones too, so search reaches back as far as events are kept. What's done is kept
// (EventStore's understanding); what can't be done now (the model busy, rate-limited, not ready) is tried again later.
//
// Pictures are embedded by the newest version there is (SearchModels.available): when a new one is downloaded
// (refresh), every event is embedded again by it, newest first, while search goes on comparing each event by the
// version it was embedded with. Once all are, the feedback's embeddings are brought over to it and the older
// downloaded versions, used by nothing, are deleted.
import CoreGraphics
import Foundation
import ImageIO
import Understanding

public final class Understander: @unchecked Sendable {
    let store: EventStore
    let eventsFolder: String
    let log: @Sendable (String) -> Void
    /// The versions of the picture model there are, the one to embed with first.
    let models: @Sendable () -> [SearchModels.Installed]
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var stale = false

    /// How long it rests when there's nothing to do, or after the model said not now.
    static let idle: Duration = .seconds(30)
    static let backOff: Duration = .seconds(120)

    public init(store: EventStore, eventsFolder: String,
                models: @escaping @Sendable () -> [SearchModels.Installed] = { SearchModels.available(support: SearchModels.support) },
                log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.eventsFolder = eventsFolder
        self.models = models
        self.log = log
    }

    /// A new version of the picture model is there: taken up before the next batch.
    public func refresh() {
        lock.withLock { stale = true }
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [self] in await run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// The newest version that loads, with what it is.
    func load() -> (SigLIP, SearchModels.Installed)? {
        for model in models() {
            do {
                return (try SigLIP(folder: model.folder, words: false), model)
            } catch {
                log("! search's picture model \(model.id) couldn't be loaded: \(error)")
            }
        }
        return nil
    }

    func run() async {
        var loaded = load()
        var siglip = loaded?.0
        log(siglip.map { "understanding events: pictures by \($0.manifest.name)" } ?? "understanding events: no picture model (search goes by what was found and descriptions)")
        var told: Describer.Availability?
        let describer = Describer()
        var retired = false
        while !Task.isCancelled {
            if lock.withLock({ () -> Bool in defer { stale = false }; return stale }) {
                let newer = load()
                if newer?.1.name != loaded?.1.name {
                    loaded = newer
                    siglip = newer?.0
                    retired = false
                    log(siglip.map { "understanding events: pictures by \($0.manifest.name) now, every event embedded again by it" } ?? "understanding events: no picture model")
                }
            }
            let availability = Describer.availability
            if availability != told {
                told = availability
                log(availability == .available ? "understanding events: descriptions by the Mac's own model" : "understanding events: no descriptions (\(availability))")
            }
            let describing = availability == .available
            let batch = store.toUnderstand(describing: describing, embedder: siglip?.manifest.name, limit: 8)
            guard !batch.isEmpty else {
                // All embedded by the newest: what the older versions were for is done.
                if !retired, let loaded {
                    retire(keeping: loaded.1)
                    retired = true
                }
                try? await Task.sleep(for: Self.idle)
                continue
            }
            for event in batch {
                guard !Task.isCancelled else { return }
                if await !understand(event, describer: describing ? describer : nil, siglip: siglip) {
                    try? await Task.sleep(for: Self.backOff)
                    break
                }
            }
        }
    }

    /// Once every event is embedded by `current`: the feedback's embeddings brought over to it (those whose event is
    /// still kept; the others, of a version no longer used, dropped: their rules stay, not their likeness), then the
    /// other downloaded versions deleted, as nothing compares by them any more.
    func retire(keeping current: SearchModels.Installed) {
        let others = models().filter { $0.downloaded && $0.name != current.name }
        let moved = store.feedbackEmbeddings(to: current.name, dropping: Set(others.map(\.name)))
        if moved > 0 { log("understanding events: \(moved) of what you said of events brought over to \(current.name)") }
        for old in others where !store.embeds(by: old.name) {
            do {
                try FileManager.default.removeItem(at: old.folder)
                log("search model: \(old.id) deleted (every event is embedded by \(current.id) now)")
            } catch {
                log("! search model: \(old.id) couldn't be deleted: \(error.localizedDescription)")
            }
        }
    }

    /// One event understood (what's missing of it); false if the model said not now.
    func understand(_ event: CameraEvent, describer: Describer?, siglip: SigLIP?) async -> Bool {
        let had = store.understanding(of: event.id)
        guard let snapshot = event.snapshot,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: (eventsFolder as NSString).appendingPathComponent(snapshot)) as CFURL, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            // Its picture's gone: nothing to understand, and not to be tried again.
            store.understood(event.id, .init(description: "", embedder: siglip?.manifest.name ?? "none"))
            return true
        }
        let closeUp = event.box.flatMap { CloseUp.crop(picture, box: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) }
        var now = EventStore.Understood()
        var ok = true
        if let describer, had?.description == nil {
            do {
                now.description = try await describer.describe(picture: picture, closeUp: closeUp, found: event.labels)
            } catch {
                if Describer.isFinal(error) {
                    now.description = ""
                } else {
                    log("understanding events: the language model said not now (\(error)); later")
                    ok = false
                }
            }
        }
        if let siglip, had?.embedder != siglip.manifest.name {
            do {
                now.scene = try siglip.embed(picture)
                now.subject = try closeUp.map { try siglip.embed($0) }
                now.embedder = siglip.manifest.name
            } catch {
                log("! understanding events: \(event.id)'s picture couldn't be embedded: \(error)")
                now.embedder = siglip.manifest.name
            }
        }
        if now != EventStore.Understood() { store.understood(event.id, now) }
        return ok
    }
}
