import Testing
@testable import Ingest

@Suite struct MediaBudgetTests {
    final class Told: @unchecked Sendable {
        var shed: [String: Bool] = [:]
        var lines: [String] = []
    }

    static let fourK = MediaBudget.decode(width: 3840, height: 2160, fps: 15)
    static let sub = MediaBudget.decode(width: 640, height: 360, fps: 15)

    func budget(_ told: Told, capacity: Double = 4 * fourK) -> MediaBudget {
        MediaBudget(capacity: capacity) { told.lines.append($0) }
    }

    func grant(_ answer: MediaBudget.Answer) -> MediaBudget.Grant? {
        switch answer {
        case let .granted(g), let .reduced(g): g
        case .refused: nil
        }
    }

    @Test func whatFitsIsGranted() {
        let told = Told()
        let b = budget(told)
        guard case .granted = b.claim(.homeKitRecording, cost: Self.fourK, label: "a") else { Issue.record("refused"); return }
        #expect(b.report.used == Self.fourK)
        #expect(told.lines.isEmpty)
    }

    @Test func closerLooksCloseFirstThenDetectionGoesToKeyframes() {
        let told = Told()
        let b = budget(told)
        let look = grant(b.claim(.closerLook, cost: Self.fourK, label: "look") { told.shed["look"] = $0 })
        let watch = grant(b.claim(.detection, cost: Self.fourK, label: "garage", reduced: Self.fourK / 20) { told.shed["garage"] = $0 })
        #expect(look != nil && watch != nil)
        // Two HomeKit recordings fit beside them; the third needs the closer look's room, the fourth detection's.
        _ = b.claim(.homeKitRecording, cost: Self.fourK, label: "r1")
        _ = b.claim(.homeKitRecording, cost: Self.fourK, label: "r2")
        #expect(told.shed.isEmpty)
        _ = b.claim(.homeKitRecording, cost: Self.fourK, label: "r3")
        #expect(told.shed == ["look": true])
        guard case .granted = b.claim(.homeKitRecording, cost: Self.fourK * 0.9, label: "r4") else { Issue.record("not granted"); return }
        #expect(told.shed == ["look": true, "garage": true])
        #expect(watch?.isShed == true)
        #expect(told.lines.contains { $0.contains("detection on keyframes only for garage") })
    }

    @Test func whatWasShedComesBackWhenThereIsRoom() {
        let told = Told()
        let b = budget(told, capacity: 2 * Self.fourK)
        let watch = grant(b.claim(.detection, cost: Self.fourK, label: "garage", reduced: Self.fourK / 20) { told.shed["garage"] = $0 })
        let recording = grant(b.claim(.homeKitRecording, cost: Self.fourK * 1.5, label: "r"))
        #expect(watch?.isShed == true)
        recording?.release()
        #expect(told.shed["garage"] == false)
        #expect(watch?.isShed == false)
        #expect(b.report.used == Self.fourK)
    }

    @Test func aRecordingThatDoesntFitIsMadeFromTheSubStream() {
        let told = Told()
        let b = budget(told, capacity: Self.fourK * 1.2)
        _ = b.claim(.homeKitRecording, cost: Self.fourK, label: "front")
        guard case let .reduced(g) = b.claim(.homeKitRecording, cost: Self.fourK, label: "side", reduced: Self.sub) else {
            Issue.record("not from the sub-stream"); return
        }
        #expect(g.cost == Self.sub)
        #expect(told.lines.contains { $0.contains("side: from the sub-stream") })
    }

    @Test func aRecordingIsNeverTurnedDown() {
        let b = budget(Told(), capacity: Self.fourK)
        _ = b.claim(.homeKitRecording, cost: Self.fourK, label: "a")
        guard case .granted = b.claim(.homeKitRecording, cost: Self.fourK, label: "b") else { Issue.record("turned down"); return }
        #expect(b.report.percent == 200)
    }

    @Test func aLiveReencodeThatDoesntFitIsTurnedDown() {
        let told = Told()
        let b = budget(told, capacity: Self.fourK)
        _ = b.claim(.homeKitRecording, cost: Self.fourK, label: "a")
        guard case .refused = b.claim(.liveReencode, cost: Self.fourK, label: "Front Door, HomeKit live") else { Issue.record("granted"); return }
        #expect(told.lines.contains { $0.contains("its own stream sent as it is") })
    }

    @Test func aGrantsRealCostMakesRoomOrGivesItBack() {
        let told = Told()
        let b = budget(told, capacity: 2 * Self.fourK)
        let watch = grant(b.claim(.detection, cost: Self.fourK, label: "garage", reduced: Self.fourK / 20) { told.shed["garage"] = $0 })
        let live = grant(b.claim(.appLive, cost: Self.sub, label: "app"))
        // Its tiles grow: detection gives way; they shrink again: it's back.
        live?.update(cost: Self.fourK * 1.5)
        #expect(watch?.isShed == true)
        live?.update(cost: Self.sub)
        #expect(watch?.isShed == false)
    }

    @Test func capacityGoesByTheChip() {
        #expect(MediaBudget.capacity(for: "Apple M6") == MediaBudget.baseCapacity)
        #expect(MediaBudget.capacity(for: "Apple M6 Pro") == 2 * MediaBudget.baseCapacity)
        #expect(MediaBudget.capacity(for: "Apple M6 Max") == 4 * MediaBudget.baseCapacity)
        #expect(MediaBudget.capacity(for: "Apple M6 Ultra") == 8 * MediaBudget.baseCapacity)
    }
}
