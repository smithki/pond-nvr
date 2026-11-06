// Which events are new: those that came in since one last looked, this Mac's and other Ponds'. An event is seen once
// it's been on screen in the Events grid a moment with the window in front (or opened), or by Mark All Seen; the
// count of the rest is on the Events view and the menu bar item. Kept per Mac, in its preferences: events before a
// time are all seen (where Mark All Seen moves it, and where it starts: nothing from before Pond first counted is new),
// and those after it, one by one.
import Foundation
import Observation

@MainActor
@Observable
final class EventsSeen {
    static let beforeKey = "eventsSeenBefore", seenKey = "eventsSeen"
    /// Its keys: the real Pond's, or a demo scenario's own (a demo shares the app's preferences, not what's seen).
    private let beforeKey: String, seenKey: String
    /// Seen ones are kept this long (events aren't kept longer).
    static let keptFor: TimeInterval = 32 * 86400

    /// Everything before this has been seen.
    private(set) var before: Date
    /// Those after it seen, by id, with when they began (to forget them once they're old).
    private(set) var seen: [String: Date]
    /// Events after `before` as last read: this Mac's (read now and then) and other Ponds' (as Events reads them).
    private var here: [String: Date] = [:]
    private var elsewhere: [String: Date] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, demo: String? = nil, now: Date = Date()) {
        self.defaults = defaults
        let suffix = demo.map { ".demo.\($0)" } ?? ""
        beforeKey = Self.beforeKey + suffix
        seenKey = Self.seenKey + suffix
        if let kept = defaults.object(forKey: beforeKey) as? Date {
            before = kept
        } else {
            before = now
            defaults.set(now, forKey: beforeKey)
        }
        let kept = defaults.dictionary(forKey: seenKey) as? [String: Date] ?? [:]
        seen = kept.filter { now.timeIntervalSince($0.value) < Self.keptFor }
    }

    func isNew(_ event: TimelineEvent) -> Bool { event.start > before && seen[event.id] == nil }

    /// How many came in and haven't been seen (or, for trying the count's look, a made-up number: `--fake-new-events`).
    var count: Int { fake ?? here.merging(elsewhere) { a, _ in a }.keys.count { seen[$0] == nil } }

    /// A made-up count, for development: set at launch, one more every few seconds, gone once Events is shown.
    var fake: Int?

    /// The new ones' ids (those read lately and not seen).
    var newIDs: Set<String> { Set(here.merging(elsewhere) { a, _ in a }.keys.filter { seen[$0] == nil }) }

    /// What's been read lately: this Mac's, or other Ponds'.
    func found(_ events: [TimelineEvent], elsewhere: Bool) {
        let recent = Dictionary(events.filter { $0.start > before && $0.kind != .privacy }.map { ($0.id, $0.start) },
                                uniquingKeysWith: { a, _ in a })
        if elsewhere { if recent != self.elsewhere { self.elsewhere = recent } } else if recent != here { here = recent }
    }

    /// These have been seen.
    func saw(_ events: [TimelineEvent]) {
        let new = events.filter(isNew)
        guard !new.isEmpty else { return }
        for event in new { seen[event.id] = event.start }
        save()
    }

    /// Everything up to now has been seen.
    func sawAll(at now: Date = Date()) {
        before = now
        seen = [:]
        save()
    }

    private func save() {
        defaults.set(before, forKey: beforeKey)
        defaults.set(seen, forKey: seenKey)
    }
}

extension AppModel {
    /// Events, showing only the new ones (from the Events tab's hover card).
    func showNewEvents() {
        eventsState.newOnly = seenEvents.newIDs
        mode = .events
    }

    /// This Mac's events since the last seen, read again (for the count on Events and the menu bar item).
    func refreshNewEvents() async {
        guard let source = EventSource(config: config) else { return }
        let from = seenEvents.before
        let found = await Task.detached { source.events(from: from, to: Date().addingTimeInterval(60)) }.value
        seenEvents.found(found, elsewhere: false)
    }
}
