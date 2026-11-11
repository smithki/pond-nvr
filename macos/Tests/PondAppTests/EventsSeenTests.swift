import Foundation
import Testing
@testable import PondApp

@MainActor
struct EventsSeenTests {
    let defaults: UserDefaults
    let suite = "pond.tests.eventsSeen.\(UUID().uuidString)"
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    init() { defaults = UserDefaults(suiteName: suite)! }

    func event(_ id: String, _ minutes: Double) -> TimelineEvent {
        let at = start.addingTimeInterval(minutes * 60)
        return TimelineEvent(id: id, camera: "porch", kind: .person, start: at, end: at.addingTimeInterval(10), summary: "")
    }

    @Test func whatCameBeforePondFirstCountedIsntNew() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let seen = EventsSeen(defaults: defaults, now: start)
        let old = event("old", -5), new = event("new", 5)
        #expect(!seen.isNew(old))
        #expect(seen.isNew(new))
        seen.found([old, new], elsewhere: false)
        #expect(seen.count == 1)
    }

    @Test func seenOnesStaySeenAndMarkAllSeenClearsTheRest() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let seen = EventsSeen(defaults: defaults, now: start)
        let a = event("a", 1), b = event("b", 2), c = event("c", 3)
        seen.found([a, b], elsewhere: false)
        seen.found([c], elsewhere: true)
        #expect(seen.count == 3)
        seen.saw([b])
        #expect(seen.count == 2)
        #expect(!seen.isNew(b))
        // Kept: the same Mac later knows what it's seen.
        let again = EventsSeen(defaults: defaults, now: start.addingTimeInterval(600))
        #expect(!again.isNew(b) && again.isNew(a))
        again.sawAll(at: start.addingTimeInterval(600))
        #expect(!again.isNew(a) && !again.isNew(c))
        #expect(again.isNew(event("d", 11)))
    }
}
