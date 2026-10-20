// The Events view's search: a question read (by the Mac's own model, or plain rules), then the events that answer it
// (EventSearch, over what the service has understood of them). Off the main thread; the words' model (SigLIP's text
// side, when the app has it) loaded once, in the background, when the view first opens.
import Foundation
import NVRCore
import Understanding
import Watch

/// A search, done: the question, how it was read, and the events that answer it.
struct EventSearchResult: Equatable {
    var question: String
    var query: EventQuery
    var byModel: Bool
    /// The events' ids, best first (newest first, when only filters were asked).
    var ids: [String]
    /// Whether they're ranked by how they looked (else by time).
    var ranked: Bool
    /// How they looked was asked, and nothing could be judged by it yet.
    var appearanceIgnored: Bool
}

enum EventSearcher {
    /// The words' model, loaded once (nil until then, or if the app hasn't one).
    private static let words = WordsModel()

    /// Made ready ahead (as the app opens), so the first search doesn't wait: the question's reader (the Mac's model,
    /// whose first answer, cold, takes seconds), and the words' model (half a second, on the CPU).
    static func prepare() {
        QuestionReader.prewarm()
        Task.detached(priority: .utility) { _ = await words.model() }
    }

    /// A question read and answered. `reading`: how it was read already (a chip taken off it), not read again.
    static func search(_ question: String, reading: (EventQuery, Bool)? = nil, config: Config) async -> EventSearchResult {
        let cameras = config.cameras.map(\.name)
        let zones = Array(Set(config.cameras.flatMap { $0.zones.map(\.name) })).sorted()
        let (query, byModel) = if let reading { reading } else {
            await QuestionReader.read(question, cameras: cameras, zones: zones)
        }
        let siglip = query.appearance == nil ? nil : await words.model()
        let answer = await Task.detached(priority: .userInitiated) { () -> EventSearch.Answer in
            guard let store = EventStore(path: config.storage.databasePath, readOnly: true) else {
                return EventSearch.Answer(hits: [], appearanceIgnored: false)
            }
            let since = Date().addingTimeInterval(-Double(config.retention.events.days) * 86400)
            let embedded = query.appearance.flatMap { try? siglip?.embed($0) }
            return EventSearch.answer(query, events: store.events(since: since).map(\.event), understood: store.understanding(since: since),
                                      cameraIDs: Set(config.cameras.filter { query.cameras.contains($0.name) }.map(\.id)),
                                      zoneIDs: Set(config.cameras.flatMap { $0.zones.filter { query.zones.contains($0.name) }.map(\.id) }),
                                      words: embedded, probability: siglip.map { s in { s.probability($0) } })
        }.value
        return EventSearchResult(question: question, query: query, byModel: byModel, ids: answer.hits.map { $0.id },
                                 ranked: query.appearance != nil && !answer.appearanceIgnored, appearanceIgnored: answer.appearanceIgnored)
    }
}

/// SigLIP's words side, loaded once, on first asking.
actor WordsModel {
    private var loaded: SigLIP??

    func model() -> SigLIP? {
        if let loaded { return loaded }
        let model = SigLIP.builtIn.flatMap { try? SigLIP(folder: $0, pictures: false) }   // (Words only.)
        loaded = .some(model)
        return model
    }
}
