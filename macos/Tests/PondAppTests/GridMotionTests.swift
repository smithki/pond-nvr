// The Events grid's motion: how one move, jump or swap gives way to another, and what's held meanwhile.
import CoreGraphics
import Foundation
import Testing
@testable import PondApp

@MainActor
@Suite struct GridMotionTests {
    let layout = EventGridLayout(sections: [EventGridLayout.Section(day: Date(timeIntervalSince1970: 0), ids: ["a", "b", "c"])],
                                 width: 900, columns: 3)
    let sectionsA = [EventGridLayout.Section(day: Date(timeIntervalSince1970: 0), ids: ["a"])]
    let sectionsB = [EventGridLayout.Section(day: Date(timeIntervalSince1970: 0), ids: ["a", "b"])]

    func reshape(_ began: Date, start: Double = 0) -> GridMotion.Move {
        .reshape(GridReshape(before: layout, anchor: nil, beforeOffset: 0, dx: 0, start: start, began: began))
    }

    func flip(_ began: Date, start: Double = 0) -> GridMotion.Move {
        .flip(GridFlip(before: layout, beforeOffset: 0, dx: 0, cards: [:], headers: [:], offset: 0, start: start, began: began))
    }

    // MARK: Moves

    @Test func aNewerMoveReplacesTheOneUnderWayWhoseEndIsThenIgnored() {
        var m = GridMotion()
        let first = Date(timeIntervalSince1970: 1), second = Date(timeIntervalSince1970: 2)
        m.begin(reshape(first))
        m.begin(flip(second, start: 3))
        #expect(m.flip != nil && m.reshaping == nil)
        let r1 = m.ended(began: first)
        #expect(r1 == false)
        #expect(m.flip != nil)
        #expect(m.start(else: 9) == 3)
        let r2 = m.ended(began: second)
        #expect(r2)
        #expect(m.move == nil)
        #expect(m.start(else: 9) == 9)
    }

    @Test func landingMidReshapeEndsItAndItsLateCompletionChangesNothing() {
        // The panel's zoom under way when a far jump lands (the panel closed far from its card).
        var m = GridMotion()
        let began = Date(timeIntervalSince1970: 1)
        m.begin(reshape(began))
        #expect(m.scrollerHidden)
        m.land()
        #expect(!m.scrollerHidden)
        let r3 = m.ended(began: began)
        #expect(r3 == false)
        // A move begun after the landing isn't ended by the old one's completion.
        let next = Date(timeIntervalSince1970: 2)
        m.begin(flip(next))
        let r4 = m.ended(began: began)
        #expect(r4 == false)
        #expect(m.flip != nil)
    }

    @Test func onlyAReshapeHidesTheScroller() {
        var m = GridMotion()
        m.begin(flip(Date()))
        #expect(!m.scrollerHidden)
        m.begin(reshape(Date()))
        #expect(m.scrollerHidden)
    }

    // MARK: Clicks

    @Test func clicksWaitTillAMoveIsNearlyStillAndForAFarJumpToSettle() {
        var m = GridMotion()
        #expect(m.clickable(scrubbing: false, progress: 1))
        #expect(!m.clickable(scrubbing: true, progress: 1))
        m.begin(reshape(Date()))
        #expect(!m.clickable(scrubbing: false, progress: 0.3))
        #expect(m.clickable(scrubbing: false, progress: GridMotion.clickableAfter))
        m.land()
        m.holdClicks(now: 100, showing: sectionsA)
        #expect(!m.clickable(scrubbing: false, progress: 1))
        m.settled()
        #expect(m.clickable(scrubbing: false, progress: 1))
    }

    @Test func heldClicksAreLetGoOnlyOnceTheirTimeIsUp() {
        var m = GridMotion()
        m.holdClicks(now: 100, showing: sectionsA)
        m.timedOut(now: 101)
        #expect(m.settling)
        // Held again meanwhile: from then.
        m.holdClicks(now: 102, showing: sectionsA)
        m.timedOut(now: 100 + GridMotion.settleFor)
        #expect(m.settling)
        m.timedOut(now: 102 + GridMotion.settleFor)
        #expect(!m.settling)
    }

    // MARK: The panel

    @Test func theMomentBetweenThePanelChangingAndItsMove() {
        var m = GridMotion()
        m.measured(panelOpen: false, leading: 200)
        #expect(!m.between(panelOpen: false))
        // Opened, the rail going (the grid now begins at 0): drawn where it was, 200 over, till its move begins.
        #expect(m.between(panelOpen: true))
        #expect(m.shift(panelOpen: true, leading: 0) == 200)
        // The window resized meanwhile: not taken as where it was laid out.
        m.moved(to: 50, panelOpen: true)
        #expect(m.shift(panelOpen: true, leading: 0) == 200)
        let r5 = m.panelChanged(open: true, leading: 0)
        #expect(r5 == 200)
        #expect(!m.between(panelOpen: true))
        #expect(m.shift(panelOpen: true, leading: 0) == 0)
        // Resized with nothing to come: taken at once.
        m.moved(to: 30, panelOpen: true)
        let r6 = m.panelChanged(open: false, leading: 230)
        #expect(r6 == -200)
    }

    @Test func measuredOnlyOnce() {
        var m = GridMotion()
        m.measured(panelOpen: true, leading: 10)
        m.measured(panelOpen: false, leading: 99)
        #expect(m.laidOutOpen == true && m.laidOutLeading == 10)
    }

    @Test func thePanelsMovePlanned() {
        #expect(GridMotion.panelPlan(centred: nil, here: 500, view: 800) == .reshape(to: 500))
        #expect(GridMotion.panelPlan(centred: 900, here: 500, view: 800) == .reshape(to: 900))
        #expect(GridMotion.panelPlan(centred: 5000, here: 500, view: 800) == .reshapeThenJump(here: 500, to: 5000))
        #expect(GridMotion.isFar(from: 0, to: 1700, view: 800))
        #expect(!GridMotion.isFar(from: 0, to: 1500, view: 800))
    }

    // MARK: Veils, and events come meanwhile

    @Test func aNewerVeilTakesOverAndTheOlderCantEndIt() {
        var m = GridMotion()
        let first = m.beginVeil()
        let second = m.beginVeil()
        #expect(!m.isCurrent(first) && m.isCurrent(second))
        let r7 = m.endVeil(first)
        #expect(r7 == false)
        #expect(m.veil == second)
        let r8 = m.endVeil(second)
        #expect(r8)
        #expect(m.veil == nil)
    }

    @Test func aRequestGivesUpAVeilAndWhatItHeld() {
        var m = GridMotion()
        let r9 = m.interrupt()
        #expect(r9 == false)
        m.holdClicks(now: 0, showing: sectionsA)
        _ = m.beginVeil()
        m.swapping = Swapping(top: true) { _ in }
        let r10 = m.interrupt()
        #expect(r10)
        #expect(m.veil == nil && m.swapping == nil && !m.settling)
        // What came meanwhile is let in now.
        let r11 = m.letIn(now: sectionsB)
        #expect(r11 == sectionsA)
    }

    @Test func eventsComingDuringAFarJumpWaitTillItsSettled() {
        var m = GridMotion()
        m.holdClicks(now: 0, showing: sectionsA)
        let id = m.beginVeil()
        #expect(m.holdsEvents)
        // Held as first drawn, not as they came later.
        m.hold(sectionsB)
        #expect(m.waiting == sectionsA)
        let r12 = m.letIn(now: sectionsB)
        #expect(r12 == nil)
        m.endVeil(id)
        let r13 = m.letIn(now: sectionsB)
        #expect(r13 == nil)
        m.settled()
        let r14 = m.letIn(now: sectionsB)
        #expect(r14 == sectionsA)
        #expect(m.waiting == nil)
    }

    @Test func nothingCameMeanwhileNothingToMove() {
        var m = GridMotion()
        m.holdClicks(now: 0, showing: sectionsA)
        m.settled()
        let r15 = m.letIn(now: sectionsA)
        #expect(r15 == nil)
        #expect(m.waiting == nil)
    }

    @Test func aSwapsOwnEventsArentHeld() {
        // A search's answer comes under its own veil: it's the swap's to land, not held for after.
        var m = GridMotion()
        _ = m.beginVeil()
        m.swapping = Swapping(top: true) { _ in }
        #expect(!m.holdsEvents)
        let r16 = m.takeSwap()
        #expect(r16 != nil)
        let r17 = m.takeSwap()
        #expect(r17 == nil)
        #expect(m.holdsEvents)
    }

    // MARK: Resizing

    @Test func aResizeKeepsTheCardItBeganWithTillItsDone() {
        var m = GridMotion()
        var asked = 0
        func here(_ id: String) -> (id: String, y: Double)? { asked += 1; return (id, 40) }
        #expect(m.resizing(from: here("a"))?.id == "a")
        // Later steps: the same card, where it was (not where the scroll has since left one).
        #expect(m.resizing(from: here("b"))?.id == "a")
        #expect(asked == 1)
        m.resized()
        #expect(m.resizing(from: here("c"))?.id == "c")
    }
}
