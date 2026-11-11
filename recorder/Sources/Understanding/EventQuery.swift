// A question about events, read: the kinds of thing asked about and particular ones named, the cameras and zones,
// when, and anything said of how they looked or what they did (for the pictures' embeddings and the sentences). Read
// by the Mac's own language model when Apple Intelligence is on; otherwise by plain rules (words for kinds and
// things, the cameras' and zones' names, time words), which also check what the model read: it's only ever told the
// names there are, and its time words are reckoned here, never by it.
import Foundation
import FoundationModels

public struct EventQuery: Equatable, Sendable, Codable {
    /// Pond's kinds: person, vehicle, bike, animal, package, item, ring.
    public var kinds: Set<String> = []
    /// The detector's words for particular things: cat, dog, car, truck, bus, bicycle…
    public var things: Set<String> = []
    /// Camera and zone names, as the settings have them.
    public var cameras: Set<String> = []
    public var zones: Set<String> = []
    public var time = TimeFilter()
    /// What's asked of how they looked or what they did ("a man in a red jacket"); nil when it's only what kind.
    public var appearance: String?

    public init(kinds: Set<String> = [], things: Set<String> = [], cameras: Set<String> = [], zones: Set<String> = [],
                time: TimeFilter = TimeFilter(), appearance: String? = nil) {
        self.kinds = kinds
        self.things = things
        self.cameras = cameras
        self.zones = zones
        self.time = time
        self.appearance = appearance
    }

    public var isEmpty: Bool { kinds.isEmpty && things.isEmpty && cameras.isEmpty && zones.isEmpty && time.isEmpty && appearance == nil }

    public static let kindNames = ["person", "vehicle", "bike", "animal", "package", "item", "ring"]
}

/// A search answered: the question, how it was read (and whether by the Mac's own model), and the events that answer
/// it. What the service sends the app and `pond search`.
public struct SearchResult: Equatable, Sendable, Codable {
    public var question: String
    public var query: EventQuery
    public var byModel: Bool
    /// The events' ids, best first (newest first, when only filters were asked).
    public var ids: [String]
    /// Whether they're ranked by how they looked (else by time).
    public var ranked: Bool
    /// How they looked was asked, and nothing could be judged by it yet (no picture model, no sentences).
    public var appearanceIgnored: Bool

    public init(question: String, query: EventQuery, byModel: Bool, ids: [String], ranked: Bool, appearanceIgnored: Bool) {
        self.question = question
        self.query = query
        self.byModel = byModel
        self.ids = ids
        self.ranked = ranked
        self.appearanceIgnored = appearanceIgnored
    }
}

/// Words, to the kinds and things they name.
enum Vocabulary {
    /// word → (kind, thing: the detector's word, if it's a particular one).
    static let words: [String: (kind: String, thing: String?)] = {
        var words: [String: (String, String?)] = [:]
        for w in ["person", "people", "persons", "someone", "somebody", "anyone", "man", "men", "woman", "women", "guy", "guys",
                  "kid", "kids", "child", "children", "visitor", "visitors", "stranger", "strangers", "human", "humans"] {
            words[w] = ("person", nil)
        }
        for (w, thing) in [("car", "car"), ("cars", "car"), ("truck", "truck"), ("trucks", "truck"), ("bus", "bus"), ("buses", "bus"),
                           ("vehicle", nil), ("vehicles", nil), ("van", nil), ("vans", nil), ("suv", nil)] as [(String, String?)] {
            words[w] = ("vehicle", thing)
        }
        for (w, thing) in [("bike", nil), ("bikes", nil), ("bicycle", "bicycle"), ("bicycles", "bicycle"), ("cyclist", "bicycle"),
                           ("motorcycle", "motorcycle"), ("motorcycles", "motorcycle"), ("motorbike", "motorcycle"), ("scooter", nil)]
            as [(String, String?)] {
            words[w] = ("bike", thing)
        }
        for (w, thing) in [("animal", nil), ("animals", nil), ("pet", nil), ("pets", nil), ("cat", "cat"), ("cats", "cat"), ("kitten", "cat"),
                           ("dog", "dog"), ("dogs", "dog"), ("puppy", "dog"), ("bird", "bird"), ("birds", "bird"), ("horse", "horse"),
                           ("deer", nil), ("squirrel", nil), ("raccoon", nil), ("fox", nil), ("bear", "bear")] as [(String, String?)] {
            words[w] = ("animal", thing)
        }
        for w in ["package", "packages", "parcel", "parcels", "delivery", "deliveries", "box", "boxes"] { words[w] = ("package", nil) }
        for (w, thing) in [("bag", nil), ("bags", nil), ("backpack", "backpack"), ("suitcase", "suitcase"), ("umbrella", "umbrella"),
                           ("handbag", "handbag")] as [(String, String?)] {
            words[w] = ("item", thing)
        }
        for w in ["doorbell", "ring", "rang", "rings", "ringing"] { words[w] = ("ring", nil) }
        return words
    }()

    /// Words that ask, not describe: left out of what's said of how things looked.
    static let filler: Set<String> = ["show", "me", "find", "any", "all", "the", "a", "an", "were", "was", "there", "is", "are", "did",
                                      "who", "what", "when", "come", "came", "by", "at", "on", "in", "of", "events", "event", "with",
                                      "see", "seen", "saw", "my", "our", "camera", "cameras", "please", "have", "has", "been", "some"]
}

/// The plain rules: no model.
public enum PlainReader {
    public static func read(_ question: String, cameras: [String], zones: [String], now: Date = Date(),
                            calendar: Calendar = .current) -> EventQuery {
        var query = EventQuery()
        let lower = question.lowercased()
        var rest = lower
        // Names first (they may be several words, or words that mean something else: "Front Door", "Bike Shed").
        func names(_ list: [String]) -> Set<String> {
            var found: Set<String> = []
            for name in list.sorted(by: { $0.count > $1.count }) where rest.contains(name.lowercased()) {
                found.insert(name)
                rest = rest.replacingOccurrences(of: name.lowercased(), with: " ")
            }
            return found
        }
        query.cameras = names(cameras)
        query.zones = names(zones)
        if let (time, used) = TimeWords.find(in: rest, now: now, calendar: calendar) {
            query.time = time
            var words = Self.words(rest)
            for word in used { if let i = words.firstIndex(of: word) { words.remove(at: i) } }
            rest = words.joined(separator: " ")
        }
        var described: [String] = []
        for word in Self.words(rest) {
            if let (kind, thing) = Vocabulary.words[word] {
                query.kinds.insert(kind)
                if let thing { query.things.insert(thing) }
            }
            described.append(word)
        }
        // A bag with someone (carrying it) isn't one left behind: an item's a kind of its own only alone.
        if query.kinds.count > 1 { query.kinds.remove("item") }
        // How they looked: the words left, if any say more than what kind.
        let telling = described.filter { !Vocabulary.filler.contains($0) && Vocabulary.words[$0] == nil }
        if !telling.isEmpty {
            var phrase = Array(described.drop { Vocabulary.filler.contains($0) })
            while let last = phrase.last, Vocabulary.filler.contains(last) { phrase.removeLast() }
            query.appearance = phrase.joined(separator: " ")
        }
        return query
    }

    static func words(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}

/// The Mac's own model, reading a question into its parts (guided: it can only answer in this shape).
@Generable(description: "A question about a home security camera's events, read into its parts.")
struct ReadQuestion {
    @Guide(description: "Kinds of thing asked about, from: person, vehicle, bike, animal, package, item, doorbell. Empty if none is.")
    var kinds: [String]
    @Guide(description: "Particular things named, in these words: car, truck, bus, bicycle, motorcycle, cat, dog, bird, horse, backpack, suitcase, umbrella, handbag. Empty if none.")
    var things: [String]
    @Guide(description: "Cameras named in the question, exactly as in the list given. Empty if none.")
    var cameras: [String]
    @Guide(description: "Zones named in the question, exactly as in the list given. Empty if none.")
    var zones: [String]
    @Guide(description: "The question's own words saying when (like \"last night\", \"this week\", \"on Monday\", \"in the morning\"), copied exactly; empty if it doesn't say.")
    var when: String
    @Guide(description: "What the people, animals or things looked like or were doing, as a short phrase for searching pictures (like \"a man in a red jacket\" or \"a dog carrying a ball\"); empty if the question only says what kind of thing.")
    var appearance: String
}

public enum QuestionReader {
    /// The Mac's model made ready ahead of a question (its first answer, cold, takes seconds).
    public static func prewarm() {
        guard Describer.availability == .available else { return }
        LanguageModelSession(model: SystemLanguageModel.default,
                             instructions: "You read questions about a home security camera's events into their parts.").prewarm()
    }

    /// The question read: by the Mac's own model when it can, by the plain rules otherwise (or if it fails).
    public static func read(_ question: String, cameras: [String], zones: [String], now: Date = Date(),
                            calendar: Calendar = .current) async -> (query: EventQuery, byModel: Bool) {
        let plain = PlainReader.read(question, cameras: cameras, zones: zones, now: now, calendar: calendar)
        guard Describer.availability == .available else { return (plain, false) }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: """
        You read questions about a home security camera's events into their parts. \
        The cameras are: \(cameras.joined(separator: ", ")). The zones are: \(zones.isEmpty ? "none" : zones.joined(separator: ", ")).
        """)
        guard let read = try? await session.respond(to: question, generating: ReadQuestion.self).content else { return (plain, false) }
        return (merge(read, plain: plain, question: question, cameras: cameras, zones: zones, now: now, calendar: calendar), true)
    }

    /// What the model read, checked against the question (it fills in what it's offered: every camera, kinds by
    /// association): cameras and zones only if the question names them; kinds only if the question's words are of
    /// them (when the rules found none, the model's, for words they don't know: "a mail carrier"); things only in the
    /// detector's words; its time words reckoned here (or the rules' time). How they looked: only if it says more
    /// than what kind, where and when.
    static func merge(_ read: ReadQuestion, plain: EventQuery, question: String, cameras: [String], zones: [String], now: Date,
                      calendar: Calendar) -> EventQuery {
        var query = EventQuery()
        let words = Set(PlainReader.words(question.lowercased()))
        let modelKinds = Set(read.kinds.map { $0.lowercased() == "doorbell" ? "ring" : $0.lowercased() }.filter(EventQuery.kindNames.contains))
        query.kinds = plain.kinds.isEmpty ? modelKinds : plain.kinds
        let thingWords = Set(Vocabulary.words.values.compactMap(\.thing))
        query.things = Set(read.things.map { $0.lowercased() }.filter { thing in
            thingWords.contains(thing) && words.contains { $0.hasPrefix(thing) }
        }).union(plain.things)
        func named(_ said: [String], _ list: [String]) -> Set<String> {
            Set(said.compactMap { s in list.first { $0.caseInsensitiveCompare(s) == .orderedSame } }
                .filter { question.range(of: $0, options: .caseInsensitive) != nil })
        }
        query.cameras = named(read.cameras, cameras).union(plain.cameras)
        query.zones = named(read.zones, zones).union(plain.zones)
        // (Its time words only if they're the question's: it may fill them in when the question says none.)
        let when = PlainReader.words(read.when.lowercased())
        let said = !when.isEmpty && when.allSatisfy { words.contains($0) }
        query.time = (said ? TimeWords.find(in: read.when, now: now, calendar: calendar)?.filter : nil) ?? plain.time
        let appearance = read.appearance.trimmingCharacters(in: .whitespacesAndNewlines)
        query.appearance = Self.saysMore(appearance, cameras: cameras, zones: zones) ? appearance : plain.appearance
        return query
    }

    /// Whether a phrase says more than what kind of thing, and which camera or zone.
    static func saysMore(_ phrase: String, cameras: [String], zones: [String]) -> Bool {
        let names = Set((cameras + zones).flatMap { PlainReader.words($0.lowercased()) })
        return PlainReader.words(phrase.lowercased()).contains {
            !Vocabulary.filler.contains($0) && Vocabulary.words[$0] == nil && !names.contains($0)
        }
    }
}
