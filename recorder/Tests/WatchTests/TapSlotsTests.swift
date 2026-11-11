import Foundation
import Testing
@testable import Watch

@Suite struct TapSlotsTests {
    final class Tap: @unchecked Sendable {
        let lock = NSLock()
        var yielded = false
    }

    @Test func onlySoManyAtOnceAndFollowingSomeoneComesFirst() {
        let slots = TapSlots(limit: 2)
        let a = Tap(), b = Tap(), c = Tap(), d = Tap()
        func claim(_ t: Tap, _ p: TapSlots.Priority) -> Bool { slots.claim(t, priority: p) { t.lock.withLock { t.yielded = true } } }
        #expect(claim(a, .motion) && claim(b, .following))
        // Full: another where something only moves waits.
        #expect(!claim(c, .motion))
        // One following someone takes the slot of one where something only moves, which is told to close.
        #expect(claim(d, .following))
        #expect(a.yielded && !b.yielded)
        #expect(slots.held == 2)
        // Asking again keeps a slot already held; a closed tap's slot is free again.
        #expect(claim(b, .following))
        slots.release(b)
        #expect(claim(c, .motion))
    }

    @Test func moreForBiggerChips() {
        #expect(TapSlots.limit(for: "Apple M6") == 4)
        #expect(TapSlots.limit(for: "Apple M6 Pro") == 6)
        #expect(TapSlots.limit(for: "Apple M6 Max") == 8)
        #expect(TapSlots.limit(for: "Apple M6 Ultra") == 12)
    }

    @Test func aCloseUpIsDecodedNoBiggerThan2560() {
        #expect(FrameDecoder.fitting(width: 3840, height: 2160, within: (2560, 1920)) == (2560, 1440))
        #expect(FrameDecoder.fitting(width: 2560, height: 1920, within: (2560, 1920)) == (2560, 1920))
        #expect(FrameDecoder.fitting(width: 1920, height: 1080, within: (2560, 1920)) == (1920, 1080))
        #expect(FrameDecoder.fitting(width: 4000, height: 3000, within: (2560, 1920)) == (2560, 1920))
    }
}
