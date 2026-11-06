// What's said of events ("this wasn't anything", "it was something"), from the app: kept in Pond's database, and
// the events read again so what's like them is quieted (EventJudge, in Watch). How a quieted one says why.
import Detection
import Foundation
import Watch

extension AppModel {
    /// Said of one of this Mac's events: kept, and the events read again.
    func say(_ verdict: EventFeedback.Verdict, of event: TimelineEvent) {
        guard event.pond == nil, let source = EventSource(config: config) else { return }
        let keepScene = config?.testFeatures == true
        Task {
            await Task.detached { source.say(verdict, of: event, keepScene: keepScene) }.value
            feedbackChanged += 1
        }
    }

    /// Some of the events seen and kept, as real test scenes (once a day: SceneLibrary).
    func keepSeenEvents() async {
        guard config?.testFeatures == true, let source = EventSource(config: config) else { return }
        // (Seen: not new any more, in Events.)
        let unseen = seenEvents.newIDs
        await Task.detached { source.keepSeen(seen: { !unseen.contains($0.id) }) }.value
    }

    /// Everything said of a camera's events forgotten (and with it what was learnt).
    func forgetFeedback(camera: String) {
        guard let source = EventSource(config: config) else { return }
        Task {
            await Task.detached { source.forgetFeedback(camera: camera) }.value
            feedbackChanged += 1
        }
    }
}

extension Quieted {
    /// Why, in a few words.
    var words: String {
        switch self {
        case .dismissed: "You said this wasn\u{2019}t anything"
        case let .rule(rule):
            "\(Self.kinds(rule.category)) here \(rule.night ? "at night" : "by day"): learnt from \(rule.from.count) you dismissed"
        case let .likeness(n): n == 1 ? "Like one you dismissed" : "Like \(n) you dismissed"
        }
    }

    static func kinds(_ category: DetectedCategory) -> String {
        switch category {
        case .person: "People"
        case .vehicle: "Vehicles"
        case .bike: "Bikes"
        case .animal: "Animals"
        case .package: "Packages"
        case .item: "Things left"
        case .ring, .other: "Events"
        }
    }
}

extension LearntRule {
    /// The rule, in words, for the camera's settings.
    var words: String { "\(Quieted.kinds(category)) in one spot \(night ? "at night" : "by day"), from \(from.count) dismissed" }
}
