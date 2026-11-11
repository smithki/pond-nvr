import Testing
@testable import Ingest

@Suite struct PlayoutClockTests {
    /// 20 pictures a second for `seconds`; every `every` s a keyframe holds the stream up for `stall` s, and the
    /// pictures behind it come all at once (as the doorbell's over Wi-Fi). Arrival and timestamp of each.
    static func stream(seconds: Double, stall: Double, every: Double = 2, start: Double = 0) -> [(Double, UInt32)] {
        var out: [(Double, UInt32)] = []
        var heldUntil = -1.0
        for i in 0 ..< Int(seconds * 20) {
            let t = start + Double(i) / 20
            if stall > 0, (t - start).truncatingRemainder(dividingBy: every) < 0.001 { heldUntil = t + stall }
            out.append((max(t, heldUntil) + 0.002, UInt32(truncatingIfNeeded: Int64(t * 90000))))
        }
        return out
    }

    @Test func aStallingCameraIsShownEvenly() {
        var clock = PlayoutClock()
        let shown = Self.stream(seconds: 20, stall: 0.5).map { clock.time(arrival: $0.0, timestamp: $0.1) }
        // Once it's learnt (after the first stall), each picture 50 ms after the one before.
        let gaps = zip(shown.dropFirst(60), shown.dropFirst(61)).map { $1 - $0 }
        #expect(gaps.allSatisfy { abs($0 - 0.05) < 0.005 })
        #expect(clock.delay > 0.45 && clock.delay < 0.6)
    }

    @Test func anEvenCameraIsHardlyHeldBack() {
        var clock = PlayoutClock()
        for (arrival, timestamp) in Self.stream(seconds: 10, stall: 0) { _ = clock.time(arrival: arrival, timestamp: timestamp) }
        #expect(clock.delay < 0.05)
    }

    @Test func theDelayComesDownWhenStallsStop() {
        var clock = PlayoutClock()
        for (a, t) in Self.stream(seconds: 10, stall: 0.5) { _ = clock.time(arrival: a, timestamp: t) }
        let learnt = clock.delay
        for (a, t) in Self.stream(seconds: 20, stall: 0, start: 10) { _ = clock.time(arrival: a, timestamp: t) }
        #expect(learnt > 0.45 && clock.delay < 0.05)
    }

    @Test func neverMoreThanTheCap() {
        var clock = PlayoutClock()
        for (a, t) in Self.stream(seconds: 10, stall: 3, every: 4) { _ = clock.time(arrival: a, timestamp: t) }
        #expect(clock.delay <= PlayoutClock.cap)
    }

    @Test func neverBeforeItArrivedNorOutOfOrder() {
        var clock = PlayoutClock(delay: 0)
        var last = -1.0
        for (a, t) in Self.stream(seconds: 6, stall: 0.5) {
            let shown = clock.time(arrival: a, timestamp: t)
            #expect(shown >= a && shown > last)
            last = shown
        }
    }

    @Test func aLearntDelayIsAStart() {
        var clock = PlayoutClock(delay: 0.5)
        // The first stall is covered at once: no freeze while it learns.
        let shown = Self.stream(seconds: 3, stall: 0.5).map { clock.time(arrival: $0.0, timestamp: $0.1) }
        let gaps = zip(shown.dropFirst(), shown.dropFirst(2)).map { $1 - $0 }
        #expect(gaps.max()! < 0.06)
    }
}
