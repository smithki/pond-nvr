import Foundation
import Testing
@testable import Ingest

@Suite struct FrameRetimerTests {
    /// A camera at 20 fps (a frame every 50 ms, 4,500 at 90 kHz) whose stamps are when it sent each frame: after
    /// each keyframe (every 40 frames) the next few wait behind it and go out together, as a Wi-Fi doorbell's do
    /// (measured: keyframe, one frame, a quarter-second gap, then a burst a few ms apart).
    static func bunched(groups: Int) -> [Int64] {
        var stamps: [Int64] = []
        for g in 0 ..< groups {
            for i in 0 ..< 40 {
                let taken = Int64(g * 40 + i) * 4500
                // Frames 2–7 of each group sent late, all at once, just after the 7th is taken.
                let sent = (2 ... 7).contains(i) ? Int64(g * 40 + 7) * 4500 + Int64(i) * 270 : taken
                stamps.append(sent)
            }
        }
        return stamps
    }

    static func gaps(_ times: [Int64]) -> [Double] { zip(times, times.dropFirst()).map { Double($1 - $0) / 90 } }

    @Test func aBunchedCameraComesOutEven() {
        var retimer = FrameRetimer()
        let stamps = Self.bunched(groups: 30)
        let placed = stamps.map { retimer.place($0) }
        // As stamped: a 300 ms gap and 3 ms ones every group.
        #expect(Self.gaps(stamps).max()! >= 300 && Self.gaps(stamps).min()! < 5)
        // While it learns the spacing (its first group), as stamped: never a gap worse than the camera's own.
        #expect(Self.gaps(Array(placed.prefix(41))).max()! <= Self.gaps(stamps).max()!)
        #expect(Self.gaps(placed).allSatisfy { $0 > 0 })
        // Then (from its second group on): every gap within a quarter of 50 ms.
        let settled = Self.gaps(Array(placed.dropFirst(41)))
        #expect(settled.allSatisfy { $0 >= 37 && $0 <= 63 }, "\(settled.min()!)–\(settled.max()!) ms")
        // And still on the camera's clock: never far from its stamps, and as long in all.
        #expect(zip(placed, stamps).allSatisfy { abs($0 - $1) < 45000 })
        #expect(abs((placed.last! - placed.first!) - (stamps.last! - stamps.first!)) < 9000)
    }

    @Test func anEvenCameraIsUnchanged() {
        var retimer = FrameRetimer()
        let stamps = (0 ..< 400).map { Int64($0) * 4500 }
        #expect(stamps.map { retimer.place($0) } == stamps)
    }

    @Test func aJumpStartsAgainFromTheCamerasTime() {
        var retimer = FrameRetimer()
        for i in 0 ..< 100 { _ = retimer.place(Int64(i) * 4500) }
        // Ten seconds on (a reconnect): placed there, not a frame's step after the last.
        #expect(retimer.place(Int64(100) * 4500 + 900_000) == Int64(100) * 4500 + 900_000)
    }

    @Test func framesOutOfOrderAreLeftAsTheyAre() {
        // B-frames: stamped out of order; evened out, they'd be shown in the wrong order.
        var retimer = FrameRetimer()
        let stamps: [Int64] = [0, 13500, 4500, 9000, 27000, 18000, 22500, 40500, 31500, 36000]
        let placed = stamps.map { retimer.place($0) }
        #expect(Array(placed.dropFirst(2)) == Array(stamps.dropFirst(2)))
    }
}
