// The service's understanding of events, for search: for each ended event with a picture, a sentence (the Mac's own
// language model, when Apple Intelligence is on) and embeddings of the picture and of a close-up of what began it
// (SigLIP 2, when the app has it). One at a time, in the background, newest first: those that come in, and the older
// ones too, so search reaches back as far as events are kept. What's done is kept (EventStore's understanding);
// what can't be done now (the model busy, rate-limited, not ready) is tried again later.
import CoreGraphics
import Foundation
import ImageIO
import Understanding

public final class Understander: @unchecked Sendable {
    let store: EventStore
    let eventsFolder: String
    let log: @Sendable (String) -> Void
    private var task: Task<Void, Never>?

    /// How long it rests when there's nothing to do, or after the model said not now.
    static let idle: Duration = .seconds(30)
    static let backOff: Duration = .seconds(120)

    public init(store: EventStore, eventsFolder: String, log: @escaping @Sendable (String) -> Void) {
        self.store = store
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
        let siglip: SigLIP?
        do {
            siglip = try SigLIP.builtIn.map { try SigLIP(folder: $0, words: false) }
        } catch {
            log("! search's picture model couldn't be loaded: \(error)")
            siglip = nil
        }
        log(siglip.map { "understanding events: pictures by \($0.manifest.name)" } ?? "understanding events: no picture model (search goes by what was found and descriptions)")
        var told: Describer.Availability?
        let describer = Describer()
        while !Task.isCancelled {
            let availability = Describer.availability
            if availability != told {
                told = availability
                log(availability == .available ? "understanding events: descriptions by the Mac's own model" : "understanding events: no descriptions (\(availability))")
            }
            let describing = availability == .available
            let batch = store.toUnderstand(describing: describing, embedder: siglip?.manifest.name, limit: 8)
            guard !batch.isEmpty else {
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
