// Search, done by the service for whoever asks (the app's Events view, `pond search`), over its control socket: a
// question read (by the Mac's own model, or plain rules), then the events that answer it (EventSearch, over what
// Understander has made of them). The service keeps what it takes ready (the words' model, the Mac's model warmed),
// so a search isn't slowed by readying them, as an app's first one would be each time it opened.
import Foundation
import PondCore
import Understanding

public final class SearchService: @unchecked Sendable {
    let store: EventStore
    /// The cameras now (their names, ids and zones, as the settings have them), and how long events are kept.
    let cameras: @Sendable () -> [Config.Camera]
    let keptDays: @Sendable () -> Int
    private let words = WordsModel()

    public init(store: EventStore, cameras: @escaping @Sendable () -> [Config.Camera], keptDays: @escaping @Sendable () -> Int) {
        self.store = store
        self.cameras = cameras
        self.keptDays = keptDays
    }

    /// What it takes made ready ahead: the Mac's model (its first answer, cold, takes seconds: readied by one asked
    /// now, unseen, as being told to get ready isn't enough) and the words' model.
    public func prepare() {
        QuestionReader.prewarm()
        let names = cameras().map(\.name)
        Task.detached(priority: .utility) { [words] in
            _ = await words.model()
            _ = await QuestionReader.read("people today", cameras: names, zones: [])
        }
    }

    /// A question answered. `reading`: how it was read already (a part taken off it), not read again. `plain`: read
    /// by the plain rules, not the Mac's model.
    public func search(_ question: String, reading: EventQuery? = nil, byModel: Bool = false, plain: Bool = false) async -> SearchResult {
        let cameras = cameras()
        let names = cameras.map(\.name)
        let zones = Array(Set(cameras.flatMap { $0.zones.map(\.name) })).sorted()
        let (query, read) = if let reading { (reading, byModel) } else if plain {
            (PlainReader.read(question, cameras: names, zones: zones), false)
        } else {
            await QuestionReader.read(question, cameras: names, zones: zones)
        }
        let siglip = query.appearance == nil ? nil : await words.model()
        let since = Date().addingTimeInterval(-Double(keptDays()) * 86400)
        let answer = EventSearch.answer(query, events: store.events(since: since).map(\.event), understood: store.understanding(since: since),
                                        cameraIDs: Set(cameras.filter { query.cameras.contains($0.name) }.map(\.id)),
                                        zoneIDs: Set(cameras.flatMap { $0.zones.filter { query.zones.contains($0.name) }.map(\.id) }),
                                        words: query.appearance.flatMap { try? siglip?.embed($0) },
                                        probability: siglip.map { s in { s.probability($0) } })
        return SearchResult(question: question, query: query, byModel: read, ids: answer.hits.map(\.id),
                            ranked: query.appearance != nil && !answer.appearanceIgnored, appearanceIgnored: answer.appearanceIgnored)
    }
}

/// SigLIP's words side, loaded once, on first asking (on the CPU: half a second).
actor WordsModel {
    private var loaded: SigLIP??

    func model() -> SigLIP? {
        if let loaded { return loaded }
        let model = SigLIP.builtIn.flatMap { try? SigLIP(folder: $0, pictures: false) }
        loaded = .some(model)
        return model
    }
}
