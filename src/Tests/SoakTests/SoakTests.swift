// The soak: Pond's video decoding with many cameras for minutes at a time, for memory. Off unless POND_SOAK=1:
// scripts/soak.sh runs it (with a watchdog of its own, outside the test), so it isn't part of the usual tests.
//
// Each made-up camera runs on a thread of its own, as the service's watchers do: its sub-stream decoded all the
// while (32BGRA, for the motion gate); while "something moves" (8 s of every 12, the cameras out of step), its
// main stream decoded for a closer look (the decoder's 4:2:0, no bigger than 2560 wide) under the shared budget
// of taps (TapSlots), a crop taken 4 times a second; and the first few cameras recording to HomeKit Secure Video
// all the while (the main stream re-encoded to 1920×1080, a keyframe every 4 s). Every 2 s: the Mac's wired memory,
// what macOS's decoder service holds, and Pond's decoders open. It passes if, after the first half minute, the
// decoder service stays flat, it never comes near VideoMemoryGuard's limits, and every camera's pictures were
// decoded; and (unless POND_SOAK_WIRED=0, as when Pond's own service runs alongside and its language model comes
// and goes) if wired memory stays flat too, by its typical reading.
//
//   POND_SOAK=1 [POND_SOAK_CAMERAS=8] [POND_SOAK_SIZE=3840x2160] [POND_SOAK_FPS=15] [POND_SOAK_SECONDS=180]
//   [POND_SOAK_RECORDING=2] [POND_SOAK_TAPS=4] swift test --filter SoakTests
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import HAPCamera
import NVRCore
@testable import Watch

@Suite(.serialized) struct SoakTests {
    static let environment = ProcessInfo.processInfo.environment

    struct Settings: Sendable {
        var cameras = 8, width = 3840, height = 2160, fps = 15, seconds = 180.0, recording = 2, taps = 4

        init(_ e: [String: String]) {
            cameras = e["POND_SOAK_CAMERAS"].flatMap(Int.init) ?? cameras
            if let size = e["POND_SOAK_SIZE"]?.split(separator: "x").compactMap({ Int($0) }), size.count == 2 {
                (width, height) = (size[0], size[1])
            }
            fps = e["POND_SOAK_FPS"].flatMap(Int.init) ?? fps
            seconds = e["POND_SOAK_SECONDS"].flatMap(Double.init) ?? seconds
            recording = min(cameras, e["POND_SOAK_RECORDING"].flatMap(Int.init) ?? recording)
            taps = e["POND_SOAK_TAPS"].flatMap(Int.init) ?? TapSlots.forThisMac()
        }
    }

    /// What every camera thread adds up as it goes.
    final class Tally: @unchecked Sendable {
        let lock = NSLock()
        var main = 0, sub = 0, crops = 0, encoded = 0, refused = 0
        var stop = false
        func add(_ change: (Tally) -> Void) { lock.withLock { change(self) } }
        var stopping: Bool { lock.withLock { stop } }
    }

    @Test(.enabled(if: environment["POND_SOAK"] == "1"), .timeLimit(.minutes(60)))
    func decodingStaysFlatWithManyCameras() async throws {
        let settings = Settings(Self.environment)
        print("soak: \(settings.cameras) cameras at \(settings.width)×\(settings.height), \(settings.fps) fps, "
            + "\(settings.recording) recording to HomeKit, \(settings.taps) closer looks at once, \(Int(settings.seconds)) s")
        let main = try MadeUpCamera.make(width: settings.width, height: settings.height, fps: settings.fps)
        let sub = try MadeUpCamera.make(width: 640, height: 360, fps: settings.fps)
        let baseline = Memory.now()
        print("soak: before \(baseline)")

        let tally = Tally()
        let slots = TapSlots(limit: settings.taps)
        let done = DispatchGroup()
        let start = Date()
        for camera in 0 ..< settings.cameras {
            done.enter()
            let thread = Thread {
                Self.camera(camera, settings: settings, main: main, sub: sub, slots: slots, tally: tally, start: start)
                done.leave()
            }
            thread.name = "soak camera \(camera)"
            thread.start()
        }

        // Looks every 2 s, until the time is up or something's wrong.
        var looks: [(at: Double, memory: Memory)] = []
        var failure: String?
        let memory = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        while Date().timeIntervalSince(start) < settings.seconds {
            try await Task.sleep(for: .seconds(2))
            let now = Memory.now(), at = Date().timeIntervalSince(start)
            looks.append((at, now))
            let t = tally.lock.withLock { (tally.main, tally.sub, tally.crops, tally.encoded, tally.refused) }
            print(String(format: "soak: %4.0f s  %@  decoded %d main, %d sub, crops %d, HomeKit %d, refused %d",
                         at, now.description, t.0, t.1, t.2, t.3, t.4))
            if now.decoders >= memory / 8 { failure = "the decoder service reached \(now.decoders) MB: VideoMemoryGuard would pause"; break }
        }
        tally.add { $0.stop = true }
        await withCheckedContinuation { c in done.notify(queue: .global()) { c.resume() } }
        let end = Memory.now()
        print("soak: after \(end)")

        #expect(failure == nil, "\(failure ?? "")")
        // Flat after the first half minute (decoders opened, pools filled): the last third no higher than the
        // middle by more than a little.
        let settled = looks.filter { $0.at >= 30 }
        if settled.count >= 6 {
            let third = settled.count / 3
            let middle = settled[third ..< 2 * third].map(\.memory.decoders).max() ?? 0
            let last = settled.suffix(third).map(\.memory.decoders).max() ?? 0
            print("soak: the decoder service at most \(middle) MB in the middle third, \(last) MB in the last")
            #expect(last <= middle + 150, "the decoder service kept growing: \(middle) MB, then \(last) MB")
            // Wired memory by its typical reading (a model loaded for a moment elsewhere isn't the soak's).
            func median(_ looks: ArraySlice<(at: Double, memory: Memory)>) -> Double {
                let sorted = looks.map(\.memory.wired).sorted()
                return sorted[sorted.count / 2]
            }
            let wired = (median(settled[third ..< 2 * third]), median(settled.suffix(third)))
            print(String(format: "soak: wired memory typically %.2f GB in the middle third, %.2f GB in the last", wired.0, wired.1))
            if Self.environment["POND_SOAK_WIRED"] != "0" {
                #expect(wired.1 - wired.0 < 1, "wired memory kept growing")
            }
        }
        // Every camera decoded (at least half its pictures, the sub-streams; the main streams while they moved).
        let t = tally.lock.withLock { (tally.main, tally.sub, tally.encoded) }
        let expected = Int(settings.seconds) * settings.fps * settings.cameras
        #expect(t.1 >= expected / 2, "sub-streams decoded \(t.1) of \(expected)")
        #expect(t.0 > 0 && (settings.recording == 0 || t.2 > 0), "main \(t.0), HomeKit \(t.2)")
    }

    /// One camera, until the soak stops: its sub-stream, its closer looks while something moves, its HomeKit
    /// recording; at its own pace.
    static func camera(_ index: Int, settings: Settings, main: MadeUpCamera, sub: MadeUpCamera, slots: TapSlots,
                       tally: Tally, start: Date) {
        /// Holds the slot; told when it's taken by a camera following someone (its tap then closes, as a StreamTap's).
        final class Holder: @unchecked Sendable {
            let lock = NSLock()
            var yielded = false
        }
        let holder = Holder()
        let subDecoder = FrameDecoder()
        var tap: FrameDecoder?
        let transcoder = index < settings.recording
            ? VideoTranscoder(target: .init(width: 1920, height: 1080, bitrate: 2000, fps: 30, profile: 0),
                              realTime: false, keyframeInterval: 4 * 90000) { _ in tally.add { $0.encoded += 1 } }
            : nil
        defer {
            subDecoder.close()
            tap?.close()
            slots.release(holder)
            transcoder?.finish()
        }
        var clock: Int64 = 0, lastCrop = 0.0
        var picture = 0
        while !tally.stopping {
            let i = picture % main.units.count
            picture += 1
            let due = start.addingTimeInterval(Double(clock) / 90000)
            if due > Date() { Thread.sleep(until: due) }
            let elapsed = Date().timeIntervalSince(start)
            // Something moves 8 s of every 12, each camera a second later than the one before.
            let moving = (elapsed + Double(index)).truncatingRemainder(dividingBy: 12) < 8
            autoreleasepool {
                let keyframe = { (u: [[UInt8]]) in u.contains { ($0.first ?? 0) & 0x1F == 5 } }
                if subDecoder.decode(sub.units[i].nalus, keyframe: keyframe(sub.units[i].nalus), damaged: false,
                                     sps: sub.sps, pps: sub.pps) != nil {
                    tally.add { $0.sub += 1 }
                }
                if let transcoder {
                    transcoder.push(main.units[i].nalus, sps: main.sps, pps: main.pps, time: clock, encode: true)
                }
                // A closer look: a slot claimed (every quarter second, as the watcher asks), the main stream decoded
                // from its next keyframe while it's held, let go when the motion stops.
                if moving, elapsed - lastCrop >= 0.25 {
                    if slots.claim(holder, priority: index % 3 == 0 ? .following : .motion,
                                   yield: { holder.lock.withLock { holder.yielded = true } }) {
                        holder.lock.withLock { holder.yielded = false }
                        if tap == nil { tap = FrameDecoder.closeUp() }
                    } else {
                        tally.add { $0.refused += 1 }
                    }
                }
                let yielded = holder.lock.withLock { holder.yielded }
                if tap != nil, !moving || yielded {
                    tap?.close()
                    tap = nil
                    if !yielded { slots.release(holder) }
                }
                if let decoder = tap, let decoded = decoder.decode(main.units[i].nalus, keyframe: keyframe(main.units[i].nalus),
                                                                   damaged: false, sps: main.sps, pps: main.pps) {
                    tally.add { $0.main += 1 }
                    if elapsed - lastCrop >= 0.25 {
                        lastCrop = elapsed
                        let side = Double(min(640, CVPixelBufferGetHeight(decoded) / 2))
                        if CloserLook.picture(decoded, cropped: CGRect(x: 100, y: 100, width: side, height: side)) != nil {
                            tally.add { $0.crops += 1 }
                        }
                    }
                }
            }
            clock += main.units[i].duration
        }
    }
}

/// What the soak watches: the Mac's wired memory (GB), what macOS's decoder services hold (MB), and Pond's
/// decoders open.
struct Memory: CustomStringConvertible {
    var wired: Double
    var decoders: Int
    var open: Int

    var description: String { String(format: "wired %.2f GB, decoder service %d MB, %d decoders open", wired, decoders, open) }

    static func now() -> Memory {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let read = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let wired = read == KERN_SUCCESS ? Double(stats.wire_count) * Double(getpagesize()) / 1_073_741_824 : 0
        return Memory(wired: wired, decoders: VideoMemoryGuard.decoderFootprint(), open: DecoderCount.open)
    }
}
