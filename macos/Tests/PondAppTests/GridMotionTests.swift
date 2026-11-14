// The Events grid's motion: how one move, jump or swap gives way to another, and what's held meanwhile.
import CoreGraphics
import Foundation
import Testing
@testable import PondApp

@MainActor
@Suite struct GridMotionTests {
    let sectionsA = [EventGridLayout.Section(day: Date(timeIntervalSince1970: 0), ids: ["a"])]
    let sectionsB = [EventGridLayout.Section(day: Date(timeIntervalSince1970: 0), ids: ["a", "b"])]

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
