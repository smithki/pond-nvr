// Events that answer a question (read into an EventQuery): those of the kinds, things, cameras, zones and time asked
// about; and, when it says how they looked or what they did, those that look it most, first. How much an event looks
// it: its picture's (or the close-up's, of what began it) SigLIP match to the words, as a probability, and how many of
// the words its sentence has. Either is enough to keep it; with neither to go by (no picture model, no sentences yet),
// the words of how they looked aren't used, and the answer says so.
import Detection
import Foundation
import Understanding

public enum EventSearch {
    public struct Hit: Equatable, Sendable {
        public var id: String
        /// How well it answers how they looked (0…1); 1 when that wasn't asked.
        public var score: Double

        public init(id: String, score: Double) {
            self.id = id
            self.score = score
        }
    }

    public struct Answer: Equatable, Sendable {
        /// Best first (newest first when only filters were asked).
        public var hits: [Hit]
        /// The question said how they looked, and nothing could be judged by it (no picture model, no sentences).
        public var appearanceIgnored: Bool

        public init(hits: [Hit], appearanceIgnored: Bool) {
            self.hits = hits
            self.appearanceIgnored = appearanceIgnored
        }
    }

    /// A picture this likely to show what's asked is kept (SigLIP's probabilities are low for any one phrase; a good
    /// match is a few percent, a poor one far under one).
    public static let pictureFloor = 0.01
    /// A sentence with this share of the telling words is kept.
    public static let wordsFloor = 0.6

    /// The question's appearance, embedded by one version of the picture model, and that version's calibration.
    public struct Words: @unchecked Sendable {
        public var embedding: [Float]
        public var probability: (Double) -> Double
        public init(embedding: [Float], probability: @escaping (Double) -> Double) {
            self.embedding = embedding
            self.probability = probability
        }
    }

    /// `cameraIDs`, `zoneIDs`: the query's cameras and zones, as the settings' ids. `byModel`: the phrase (the
    /// question's appearance) embedded by each version of the picture model events are embedded by, by its name:
    /// each event's picture is compared with the phrase by its own version (two versions' embeddings aren't
    /// comparable), as while a new one embeds every event again. `words` and `probability`: one embedding for any
    /// event whose version isn't among them.
    public static func answer(_ query: EventQuery, events: [CameraEvent], understood: [String: EventStore.Understood],
                              cameraIDs: Set<String>, zoneIDs: Set<String>, words: [Float]?,
                              probability: ((Double) -> Double)?, byModel: [String: Words] = [:],
                              calendar: Calendar = .current) -> Answer {
        let candidates = events.filter { matches($0, query, cameraIDs: cameraIDs, zoneIDs: zoneIDs, calendar: calendar) }
        guard let appearance = query.appearance else {
            return Answer(hits: candidates.sorted { $0.start > $1.start }.map { Hit(id: $0.id, score: 1) }, appearanceIgnored: false)
        }
        let telling = Self.telling(appearance)
        var judged = false
        var hits: [(Hit, Date)] = []
        for event in candidates {
            let u = understood[event.id]
            var picture: Double?
            let model = u?.embedder.flatMap { byModel[$0] }
                ?? words.flatMap { w in probability.map { Words(embedding: w, probability: $0) } }
            if let model, let scene = u?.scene {
                judged = true
                let best = max(SigLIP.similarity(model.embedding, scene),
                               u?.subject.map { SigLIP.similarity(model.embedding, $0) } ?? -1)
                picture = model.probability(best)
            }
            var sentence: Double?
            if let description = u?.description, !description.isEmpty, !telling.isEmpty {
                judged = true
                sentence = Self.sentenceMatch(telling, description)
            }
            guard (picture ?? 0) >= pictureFloor || (sentence ?? 0) >= wordsFloor else { continue }
            // Both count, alike: the picture's match (a good one, ten percent or more, counts in full), and the
            // sentence's words (all of them, in full).
            hits.append((Hit(id: event.id, score: min(1, (picture ?? 0) * 10) * 0.5 + (sentence ?? 0) * 0.5), event.start))
        }
        // (Nothing judged with something to judge: nothing to go by. Nothing to judge: nothing's ignored.)
        guard judged || candidates.isEmpty else {
            return Answer(hits: candidates.sorted { $0.start > $1.start }.map { Hit(id: $0.id, score: 1) }, appearanceIgnored: true)
        }
        return Answer(hits: hits.sorted { $0.0.score != $1.0.score ? $0.0.score > $1.0.score : $0.1 > $1.1 }.map(\.0),
                      appearanceIgnored: false)
    }

    /// Whether an event is of the kinds, things, cameras, zones and time asked (what isn't asked, anything).
    static func matches(_ e: CameraEvent, _ q: EventQuery, cameraIDs: Set<String>, zoneIDs: Set<String>, calendar: Calendar) -> Bool {
        if !q.kinds.isEmpty {
            let kinds = Set([e.category.rawValue] + e.labels.keys.map { DetectedCategory.forLabel($0).rawValue })
            if kinds.isDisjoint(with: q.kinds) { return false }
        }
        if !q.things.isEmpty, Set(e.labels.keys.map { $0.lowercased() }).isDisjoint(with: q.things) { return false }
        if !cameraIDs.isEmpty, !cameraIDs.contains(e.camera) { return false }
        if !zoneIDs.isEmpty, Set(e.zones).isDisjoint(with: zoneIDs) { return false }
        return q.time.contains(e.start, calendar: calendar)
    }

    /// How much of a phrase's telling words a sentence has (0…1): mostly the words themselves (a plural for a
    /// singular, either way), and the rest, how many of the phrase's neighbouring pairs are neighbours there too
    /// ("a white bag" is in "carrying a white bag", not in "white trousers, carrying a bag").
    static func sentenceMatch(_ telling: [String], _ sentence: String) -> Double {
        let said = Self.telling(sentence)
        func same(_ a: String, _ b: String) -> Bool { a == b || a + "s" == b || a == b + "s" }
        let words = Double(telling.filter { w in said.contains { same(w, $0) } }.count) / Double(telling.count)
        guard telling.count > 1 else { return words }
        let pairs = zip(telling, telling.dropFirst())
        let together = pairs.filter { a, b in zip(said, said.dropFirst()).contains { same(a, $0.0) && same(b, $0.1) } }.count
        return 0.7 * words + 0.3 * Double(together) / Double(telling.count - 1)
    }

    /// The words of a phrase that say something (not "a", "the", "in"…).
    static func telling(_ phrase: String) -> [String] {
        words(phrase).filter { !stop.contains($0) }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static let stop: Set<String> = ["a", "an", "the", "in", "on", "at", "of", "with", "and", "or", "to", "is", "are", "was", "were",
                                    "by", "near", "some", "someone", "something", "wearing", "who", "that", "their", "his", "her"]
}
