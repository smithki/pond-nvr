// What the user said of events: "this wasn't anything", or (of one that was quieted) "it was something", kept in
// Pond's database with what's needed to learn from it after the event itself is gone (its kind, where in the picture,
// when, and its picture's embedding). The app writes it; the app reads it, to quiet events like the ones dismissed:
// marked "probably nothing" with why, left out of Events by default, never lost (the service still records and
// makes them, and HomeKit hears of them as ever).
//
// Two ways an event is judged like the dismissed ones (EventJudge):
// - a learnt rule: three or more dismissed of one kind, in one spot, in one part of the day ("vehicles here at
//   night"): another of that kind there then;
// - a likeness: one of the kind near a dismissed one's spot, its picture very like that one's (the embeddings
//   search uses): a shadow, a flag, a reflection, called a person again.
// Saying "it was something" of one outweighs either, near it.
import Detection
import Foundation

public struct EventFeedback: Sendable, Equatable, Identifiable {
    public enum Verdict: String, Sendable { case nothing, something }

    /// The event's id.
    public var id: String
    public var camera: String
    public var category: DetectedCategory
    public var start: Date
    public var box: Detection.Box?
    public var verdict: Verdict
    /// Its picture's embedding (its subject's, else the whole view's), by `embedder`.
    public var embedding: [Float]?
    public var embedder: String?
    /// When it was said.
    public var time: Date

    public init(id: String, camera: String, category: DetectedCategory, start: Date, box: Detection.Box?, verdict: Verdict,
                embedding: [Float]? = nil, embedder: String? = nil, time: Date = Date()) {
        self.id = id
        self.camera = camera
        self.category = category
        self.start = start
        self.box = box
        self.verdict = verdict
        self.embedding = embedding
        self.embedder = embedder
        self.time = time
    }
}

extension EventStore {
    /// Kept (or, said again, replaced): with the event's embedding, if it has one by now.
    public func record(_ feedback: EventFeedback) {
        var feedback = feedback
        if feedback.embedding == nil, let u = understanding(of: feedback.id) {
            feedback.embedding = u.subject ?? u.scene
            feedback.embedder = u.embedder
        }
        let f = feedback
        queue.sync {
            _ = run("""
            INSERT OR REPLACE INTO feedback (id, camera, category, start, x, y, w, h, verdict, embedding, embedder, time)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [f.id, f.camera, f.category.rawValue, f.start.timeIntervalSince1970, f.box?.x, f.box?.y, f.box?.width,
                  f.box?.height, f.verdict.rawValue, f.embedding.map(Self.data), f.embedder, f.time.timeIntervalSince1970])
        }
    }

    /// Forgotten: these (by event id), or every one of a camera's.
    public func forgetFeedback(_ ids: [String]) {
        queue.sync { for id in ids { _ = run("DELETE FROM feedback WHERE id = ?", [id]) } }
    }

    public func forgetFeedback(camera: String) {
        queue.sync { _ = run("DELETE FROM feedback WHERE camera = ?", [camera]) }
    }

    /// What's said of events, brought over to a new version of the picture model once every event is embedded by
    /// it: each one's embedding replaced by its event's (if the event's still kept), and those by `old` versions
    /// still left (their events gone) dropped, as nothing compares by them any more (a learnt rule doesn't need
    /// one). How many were brought over.
    @discardableResult
    public func feedbackEmbeddings(to embedder: String, dropping old: Set<String>) -> Int {
        queue.sync {
            let moved = rows("""
            SELECT COUNT(*) FROM feedback f JOIN understanding u ON u.id = f.id
            WHERE u.embedder = ? AND f.embedder IS NOT ? AND COALESCE(u.subject, u.scene) IS NOT NULL
            """, [embedder, embedder]) { $0.int(0) }.first ?? 0
            _ = run("""
            UPDATE feedback SET embedding = (SELECT COALESCE(u.subject, u.scene) FROM understanding u WHERE u.id = feedback.id),
                embedder = ?
            WHERE embedder IS NOT ? AND id IN (SELECT id FROM understanding WHERE embedder = ? AND COALESCE(subject, scene) IS NOT NULL)
            """, [embedder, embedder, embedder])
            for name in old { _ = run("UPDATE feedback SET embedding = NULL, embedder = NULL WHERE embedder = ?", [name]) }
            return moved
        }
    }

    /// Whether anything's still embedded by this version of the picture model: an event's picture, or what's said of one.
    public func embeds(by embedder: String) -> Bool {
        queue.sync {
            (rows("""
            SELECT EXISTS(SELECT 1 FROM understanding WHERE embedder = ? AND scene IS NOT NULL)
                OR EXISTS(SELECT 1 FROM feedback WHERE embedder = ? AND embedding IS NOT NULL)
            """, [embedder, embedder]) { $0.int(0) }.first ?? 0) != 0
        }
    }

    /// Everything said (a camera's, or every camera's), oldest first.
    public func feedback(camera: String? = nil) -> [EventFeedback] {
        queue.sync {
            rows("""
            SELECT id, camera, category, start, x, y, w, h, verdict, embedding, embedder, time FROM feedback
            WHERE ? IS NULL OR camera = ? ORDER BY time
            """, [camera, camera]) { row in
                guard let id = row.text(0), let camera = row.text(1),
                      let category = row.text(2).flatMap(DetectedCategory.init(rawValue:)),
                      let verdict = row.text(8).flatMap(EventFeedback.Verdict.init(rawValue:)) else { return nil }
                let box = row.isNull(4) ? nil : Detection.Box(x: row.double(4), y: row.double(5), width: row.double(6), height: row.double(7))
                return EventFeedback(id: id, camera: camera, category: category, start: Date(timeIntervalSince1970: row.double(3)),
                                     box: box, verdict: verdict, embedding: row.floats(9), embedder: row.text(10),
                                     time: Date(timeIntervalSince1970: row.double(11)))
            }
        }
    }
}

/// A rule learnt from dismissals: events of a kind, in a spot, in a part of the day, are probably nothing.
public struct LearntRule: Sendable, Equatable, Identifiable {
    public var camera: String
    public var category: DetectedCategory
    /// The spot: the dismissed ones' boxes, averaged.
    public var box: Detection.Box
    public var night: Bool
    /// The dismissals it's learnt from (their event ids).
    public var from: [String]

    public var id: String { "\(camera)|\(category.rawValue)|\(night)|\(from.first ?? "")" }
}

/// Whether an event is probably nothing, and why.
public enum Quieted: Sendable, Equatable {
    /// The user said so of this one.
    case dismissed
    /// A rule learnt from several dismissed.
    case rule(LearntRule)
    /// Its picture very like these many dismissed (near the same spot).
    case likeness(Int)
}

public struct EventJudge: Sendable {
    /// Of a kind as many as this, dismissed in one spot in one part of the day, make a rule.
    public static let ruleFrom = 3
    /// Two boxes in one spot: their middles this close (a share of the picture), their sizes within this ratio.
    public static let near = 0.12
    public static let sizeRatio = 2.0
    /// A picture this like a dismissed one's (cosine of their embeddings) is "like it".
    public static let alike: Float = 0.9

    public let feedback: [EventFeedback]
    public let rules: [LearntRule]
    private let verdicts: [String: EventFeedback.Verdict]

    public init(feedback: [EventFeedback], calendar: Calendar = .current) {
        self.feedback = feedback
        verdicts = Dictionary(feedback.map { ($0.id, $0.verdict) }, uniquingKeysWith: { _, b in b })
        rules = Self.learn(feedback, calendar: calendar)
    }

    /// Night: from 7 in the evening to 7 in the morning (a parked car's hours, headlights and infrared).
    public static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 19 || hour < 7
    }

    public static func near(_ a: Detection.Box, _ b: Detection.Box) -> Bool {
        let dx = (a.x + a.width / 2) - (b.x + b.width / 2), dy = (a.y + a.height / 2) - (b.y + b.height / 2)
        let areaA = a.width * a.height, areaB = b.width * b.height
        guard areaA > 0, areaB > 0 else { return false }
        let ratio = max(areaA, areaB) / min(areaA, areaB)
        return (dx * dx + dy * dy).squareRoot() <= near && ratio <= sizeRatio
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// Rules from the dismissed: those of a camera, kind and part of the day, gathered by spot; a spot with enough is a
    /// rule, unless something was said to be something there (of that kind, then).
    static func learn(_ feedback: [EventFeedback], calendar: Calendar) -> [LearntRule] {
        var rules: [LearntRule] = []
        let kept = feedback.filter { $0.box != nil }
        let groups = Dictionary(grouping: kept) { "\($0.camera)|\($0.category.rawValue)|\(isNight($0.start, calendar: calendar))" }
        for (_, group) in groups {
            let dismissed = group.filter { $0.verdict == .nothing }
            let confirmed = group.filter { $0.verdict == .something }
            // Gathered by spot, each to the first spot it's near (by that spot's first box).
            var spots: [[EventFeedback]] = []
            for f in dismissed {
                if let i = spots.firstIndex(where: { near($0[0].box!, f.box!) }) { spots[i].append(f) } else { spots.append([f]) }
            }
            for spot in spots where spot.count >= ruleFrom {
                let n = Double(spot.count)
                let mean = Detection.Box(x: spot.map { $0.box!.x }.reduce(0, +) / n, y: spot.map { $0.box!.y }.reduce(0, +) / n,
                                         width: spot.map { $0.box!.width }.reduce(0, +) / n,
                                         height: spot.map { $0.box!.height }.reduce(0, +) / n)
                guard !confirmed.contains(where: { near($0.box!, mean) }) else { continue }
                rules.append(LearntRule(camera: spot[0].camera, category: spot[0].category, box: mean,
                                        night: isNight(spot[0].start, calendar: calendar), from: spot.map(\.id)))
            }
        }
        return rules.sorted { $0.from.count > $1.from.count }
    }

    /// Whether an event's probably nothing, and why; nil, it's to be shown.
    /// `embedder`: the version of the picture model `embedding` is by; it's compared only with what's said of events
    /// embedded by the same one (another version's embeddings aren't comparable).
    public func judge(id: String, camera: String, category: DetectedCategory, start: Date, box: Detection.Box?,
                      embedding: [Float]?, embedder: String? = nil, calendar: Calendar = .current) -> Quieted? {
        switch verdicts[id] {
        case .nothing?: return .dismissed
        case .something?: return nil
        case nil: break
        }
        guard let box else { return nil }
        let night = Self.isNight(start, calendar: calendar)
        if let rule = rules.first(where: { $0.camera == camera && $0.category == category && $0.night == night && Self.near($0.box, box) }) {
            return .rule(rule)
        }
        // Like the dismissed ones near here (of the kind), more than like any said to be something.
        guard let embedding else { return nil }
        let here = feedback.filter { $0.camera == camera && $0.category == category && $0.box.map { Self.near($0, box) } == true
            && (embedder == nil || $0.embedder == nil || $0.embedder == embedder) }
        func likeness(_ f: EventFeedback) -> Float { f.embedding.map { Self.cosine($0, embedding) } ?? 0 }
        let like = here.filter { $0.verdict == .nothing && likeness($0) >= Self.alike }
        guard !like.isEmpty else { return nil }
        let best = like.map(likeness).max() ?? 0
        if here.contains(where: { $0.verdict == .something && likeness($0) >= best }) { return nil }
        return .likeness(like.count)
    }
}
