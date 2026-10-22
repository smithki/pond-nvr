import CoreVideo
import Foundation
import Testing
@testable import Watch

@Suite(.serialized) struct VideoMemoryGuardTests {
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var lines: [String] = [], stopped: [String] = []
        var footprint = 0, decoders = 4
    }

    func guarded(_ seen: Seen, memory: Int = 16384) -> VideoMemoryGuard {
        VideoMemoryGuard(memory: memory, log: { line in seen.lock.withLock { seen.lines.append(line) } },
                         stop: { why in seen.lock.withLock { seen.stopped.append(why) } },
                         footprint: { seen.lock.withLock { seen.footprint } }, decoders: { seen.lock.withLock { seen.decoders } })
    }

    @Test func itPausesTheCloserLooksThenStopsPond() {
        let seen = Seen()
        let watching = guarded(seen)
        defer { StreamTap.resume() }
        // In proportion to the Mac's memory: 2 and 4 GB on 16 GB, 8 and 16 on 64.
        #expect(watching.shedAt == 2048 && watching.stopAt == 4096)
        #expect(guarded(Seen(), memory: 65536).stopAt == 16384)
        // Normal (two HomeKit recordings and both closer looks open come to about 150 MB): nothing done.
        seen.footprint = 150
        watching.check()
        #expect(!StreamTap.paused && seen.lines.isEmpty && seen.stopped.isEmpty)
        // Too much: the closer looks paused, said once.
        seen.footprint = watching.shedAt + 100
        watching.check()
        watching.check()
        #expect(StreamTap.paused)
        #expect(seen.lines.count == 1 && seen.lines[0].contains("closer looks paused"))
        #expect(seen.stopped.isEmpty)
        // Far too much: Pond stopped (to be started again), and why.
        seen.footprint = watching.stopAt + 1
        watching.check()
        #expect(seen.stopped.count == 1 && seen.stopped[0].contains("\(watching.stopAt + 1) MB"))
    }

    @Test func growthWithTheSameDecodersIsALeak() {
        let seen = Seen()
        let watching = guarded(seen)
        defer { StreamTap.resume() }
        // A minute of growth, 60 MB a look, the same 5 decoders open: a leak, though far below the limits.
        seen.decoders = 5
        for step in 0 ..< 7 {
            seen.footprint = 150 + step * 60
            watching.check()
        }
        #expect(StreamTap.paused)
        #expect(seen.lines.last?.contains("a leak") == true)
    }

    @Test func growthWithMoreDecodersIsNot() {
        let seen = Seen()
        let watching = guarded(seen)
        // The same growth, a closer look opening along the way: what it costs, not a leak.
        for step in 0 ..< 7 {
            seen.footprint = 150 + step * 60
            seen.decoders = step < 3 ? 4 : 5
            watching.check()
        }
        #expect(!StreamTap.paused && seen.lines.isEmpty)
    }

    @Test func thisMachinesDecoderIsMeasured() {
        // Whatever's decoding now (often nothing): a size, not a failure.
        #expect(VideoMemoryGuard.decoderFootprint() >= 0)
    }

    @Test func aCloseUpIsTheRowsCopiedOut() throws {
        // A 64×48 picture whose every pixel says where it is (blue: x, green: y).
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &made)
        let picture = try #require(made)
        CVPixelBufferLockBaseAddress(picture, [])
        let base = try #require(CVPixelBufferGetBaseAddress(picture)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(picture)
        for y in 0 ..< 48 {
            for x in 0 ..< 64 { base[y * row + x * 4] = UInt8(x); base[y * row + x * 4 + 1] = UInt8(y) }
        }
        CVPixelBufferUnlockBaseAddress(picture, [])

        let part = try #require(CloserLook.picture(picture, cropped: CGRect(x: 10, y: 20, width: 16, height: 8)))
        #expect(CVPixelBufferGetWidth(part) == 16 && CVPixelBufferGetHeight(part) == 8)
        CVPixelBufferLockBaseAddress(part, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(part, .readOnly) }
        let out = try #require(CVPixelBufferGetBaseAddress(part)).assumingMemoryBound(to: UInt8.self)
        let outRow = CVPixelBufferGetBytesPerRow(part)
        #expect(out[0] == 10 && out[1] == 20)                                    // its top left is (10, 20)
        #expect(out[7 * outRow + 15 * 4] == 25 && out[7 * outRow + 15 * 4 + 1] == 27)   // its bottom right (25, 27)
        // Outside the picture: none.
        #expect(CloserLook.picture(picture, cropped: CGRect(x: 60, y: 0, width: 16, height: 8)) == nil)
    }

    @Test func aCloseUpOf420IsItsPlanesCopiedOut() throws {
        // 64×48 in the decoder's 4:2:0: brightness says x, colour says (x/2, y/2) of its 2×2.
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &made)
        let picture = try #require(made)
        CVPixelBufferLockBaseAddress(picture, [])
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(picture, 0)).assumingMemoryBound(to: UInt8.self)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(picture, 1)).assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(picture, 0), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(picture, 1)
        for y in 0 ..< 48 { for x in 0 ..< 64 { luma[y * lumaRow + x] = UInt8(x) } }
        for y in 0 ..< 24 { for x in 0 ..< 32 { chroma[y * chromaRow + 2 * x] = UInt8(x); chroma[y * chromaRow + 2 * x + 1] = UInt8(y) } }
        CVPixelBufferUnlockBaseAddress(picture, [])

        // An odd corner and sides: made even.
        let part = try #require(CloserLook.picture(picture, cropped: CGRect(x: 11, y: 21, width: 17, height: 9)))
        #expect(CVPixelBufferGetPixelFormatType(part) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetWidth(part) == 16 && CVPixelBufferGetHeight(part) == 8)
        CVPixelBufferLockBaseAddress(part, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(part, .readOnly) }
        let outLuma = try #require(CVPixelBufferGetBaseAddressOfPlane(part, 0)).assumingMemoryBound(to: UInt8.self)
        let outChroma = try #require(CVPixelBufferGetBaseAddressOfPlane(part, 1)).assumingMemoryBound(to: UInt8.self)
        #expect(outLuma[0] == 10 && outLuma[15] == 25)          // from (10, 20)
        #expect(outChroma[0] == 5 && outChroma[1] == 10)        // its colour from (5, 10) of the 2×2s
    }
}
