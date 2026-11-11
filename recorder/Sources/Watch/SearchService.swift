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
    private let words: WordsModels

    public init(store: EventStore, cameras: @escaping @Sendable () -> [Config.Camera], keptDays: @escaping @Sendable () -> Int,
                models: @escaping @Sendable () -> [SearchModels.Installed] = { SearchModels.available(support: SearchModels.support) }) {
        self.store = store
        self.cameras = cameras
        self.keptDays = keptDays
        words = WordsModels(models: models)
    }

    /// A new version of the picture model is there (or one's gone): the versions looked at again on the next search.
    public func refresh() {
        Task { await words.refresh() }
    }

    /// What it takes made ready ahead: the Mac's model (its first answer, cold, takes seconds: readied by one asked
    /// now, unseen, as being told to get ready isn't enough) and the words' model.
    public func prepare() {
        QuestionReader.prewarm()
        let names = cameras().map(\.name)
        Task.detached(priority: .utility) { [words] in
            _ = await words.newest()
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
        let since = Date().addingTimeInterval(-Double(keptDays()) * 86400)
        let understood = store.understanding(since: since)
        // The phrase embedded by each version events are embedded by (one, but for while a new version embeds them
        // all again): each event compared by its own.
        var byModel: [String: EventSearch.Words] = [:]
        if let appearance = query.appearance {
            let used = Set(understood.values.compactMap { $0.scene == nil ? nil : $0.embedder })
            for (name, siglip) in await words.models(named: used.isEmpty ? nil : used) {
                if let embedding = try? siglip.embed(appearance) {
                    byModel[name] = EventSearch.Words(embedding: embedding, probability: { siglip.probability($0) })
                }
            }
        }
        let answer = EventSearch.answer(query, events: store.events(since: since).map(\.event), understood: understood,
                                        cameraIDs: Set(cameras.filter { query.cameras.contains($0.name) }.map(\.id)),
                                        zoneIDs: Set(cameras.flatMap { $0.zones.filter { query.zones.contains($0.name) }.map(\.id) }),
                                        words: nil, probability: nil, byModel: byModel)
        return SearchResult(question: question, query: query, byModel: read, ids: answer.hits.map(\.id),
                            ranked: query.appearance != nil && !answer.appearanceIgnored, appearanceIgnored: answer.appearanceIgnored)
    }
}

/// SigLIP's words side of each version of the picture model, loaded on first asking (on the CPU: half a second each),
/// and kept while it's there.
actor WordsModels {
    let models: @Sendable () -> [SearchModels.Installed]
    private var available: [SearchModels.Installed]?
    private var loaded: [String: SigLIP?] = [:]

    init(models: @escaping @Sendable () -> [SearchModels.Installed]) {
        self.models = models
    }

    func refresh() {
        available = nil
    }

    private func list() -> [SearchModels.Installed] {
        if let available { return available }
        let now = models()
        available = now
        // Versions gone (deleted once nothing used them): let go of.
        let names = Set(now.map(\.name))
        loaded = loaded.filter { names.contains($0.key) }
        return now
    }

    private func load(_ model: SearchModels.Installed) -> SigLIP? {
        if let had = loaded[model.name] { return had }
        let siglip = try? SigLIP(folder: model.folder, pictures: false)
        loaded[model.name] = siglip
        return siglip
    }

    /// The newest version's.
    func newest() -> SigLIP? {
        list().first.flatMap { load($0) }
    }

    /// Those of the versions named (nil: the newest only), by name.
    func models(named names: Set<String>?) -> [String: SigLIP] {
        let all = list()
        let wanted = names.map { n in all.filter { n.contains($0.name) } } ?? Array(all.prefix(1))
        var out: [String: SigLIP] = [:]
        for model in wanted { if let siglip = load(model) { out[model.name] = siglip } }
        return out
    }
}
