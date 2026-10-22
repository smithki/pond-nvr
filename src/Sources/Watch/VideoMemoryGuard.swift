// A guard on the memory the Mac's video decoding holds for Pond. Decoded pictures live in macOS's decoder service
// (VTDecoderXPCService) and the kernel, not in Pond's own memory: kept by mistake, they grow unseen until the Mac
// runs out and freezes (as it did when the closer look's crops kept the main stream's pictures). So the service
// looks every 10 s, two ways:
//
// - A leak: the decoder service growing all through a minute while Pond's decoders stay as they are (more cameras
//   decoding, or a closer look opening, is growth with a reason; growth without one isn't). The closer looks pause.
// - Too much, whatever the reason, in proportion to the Mac's memory: past an eighth, the closer looks pause for a
//   few minutes; past a quarter, or when macOS says memory is critical, Pond logs why and exits, and launchd starts
//   it again (the decoder service, with no one left to decode for, lets everything go). A restart costs a few
//   seconds of recording; a frozen Mac costs everything until someone notices.
//
// (What's measured is every decoder service of this user's: the app's live views' too, which only makes it
// warier. Pond's own memory isn't where the pictures are.) Hourly, the size and the decoders open are logged, with
// how hard the closer looks were worked that hour (they're what leaked before: a flat size after many is the proof).
import Darwin
import Foundation
import NVRCore

public final class VideoMemoryGuard: @unchecked Sendable {
    /// The decoder services' footprint (MB) at which the closer looks pause, and at which Pond stops: an eighth and a
    /// quarter of the Mac's memory (2 and 4 GB on 16 GB).
    public let shedAt: Int, stopAt: Int
    /// How long the closer looks pause.
    public static let shedFor: TimeInterval = 300
    /// Growth counted as a leak: all through this many looks (a minute), by this much (MB), Pond's decoders the same.
    static let leakLooks = 7, leakGrowth = 300
    static let every: TimeInterval = 10, reportEvery: TimeInterval = 3600

    let log: @Sendable (String) -> Void
    let stop: @Sendable (String) -> Void
    let footprint: @Sendable () -> Int
    let decoders: @Sendable () -> Int
    private let queue = DispatchQueue(label: "pond.video-memory", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pressure: DispatchSourceMemoryPressure?
    private var shedding = false
    /// The latest looks: the footprint (MB) and Pond's decoders open.
    private var looks: [(held: Int, decoders: Int)] = []
    private var reported = Date()

    /// `memory`: the Mac's (MB). `footprint` and `decoders`: what the decoder services hold (MB) and how many decoders
    /// Pond has open (a test's own).
    public init(memory: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                log: @escaping @Sendable (String) -> Void,
                stop: @escaping @Sendable (String) -> Void = { _ in exit(75) },
                footprint: @escaping @Sendable () -> Int = VideoMemoryGuard.decoderFootprint,
                decoders: @escaping @Sendable () -> Int = { DecoderCount.open }) {
        shedAt = memory / 8
        stopAt = memory / 4
        self.log = log
        self.stop = stop
        self.footprint = footprint
        self.decoders = decoders
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.every, repeating: Self.every)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self, weak pressure] in
            guard let self, let event = pressure?.data else { return }
            if event.contains(.critical) {
                self.halt("macOS says memory is critically low (the video decoder holds \(self.footprint()) MB)")
            } else if event.contains(.warning) {
                self.shed("macOS says memory is low")
            }
        }
        pressure.resume()
        self.pressure = pressure
    }

    public func stopWatching() {
        timer?.cancel()
        pressure?.cancel()
    }

    func check(now: Date = Date()) {
        let held = footprint(), open = decoders()
        looks.append((held, open))
        if looks.count > Self.leakLooks { looks.removeFirst() }
        if now.timeIntervalSince(reported) >= Self.reportEvery {
            reported = now
            let (looks, taps) = CloserLook.Count.take()
            log("video decoding: \(held) MB held, \(open) decoder\(open == 1 ? "" : "s") open; this hour, \(looks) closer look"
                + "\(looks == 1 ? "" : "s") from \(taps) main stream\(taps == 1 ? "" : "s") opened")
        }
        if held >= stopAt {
            halt("the video decoder holds \(held) MB (more than a quarter of this Mac's memory)")
        } else if held >= shedAt {
            shed("the video decoder holds \(held) MB (more than an eighth of this Mac's memory)")
        } else if let growth = leaking() {
            shed("the video decoder grew \(growth) MB in a minute with the same \(open) decoder\(open == 1 ? "" : "s") open: a leak")
            looks = []
        }
    }

    /// How much it grew, if it grew all through the latest looks while Pond's decoders stayed the same.
    func leaking() -> Int? {
        guard looks.count == Self.leakLooks, let first = looks.first, let last = looks.last,
              looks.allSatisfy({ $0.decoders == first.decoders }),
              zip(looks, looks.dropFirst()).allSatisfy({ $1.held > $0.held }),
              last.held - first.held >= Self.leakGrowth else { return nil }
        return last.held - first.held
    }

    private func shed(_ why: String) {
        StreamTap.pause(for: Self.shedFor)
        guard !shedding else { return }
        shedding = true
        log("! \(why): closer looks paused for \(Int(Self.shedFor / 60)) minutes")
        queue.asyncAfter(deadline: .now() + Self.shedFor) { [weak self] in self?.shedding = false }
    }

    private func halt(_ why: String) {
        log("! \(why): stopping, to be started again with the memory let go")
        stop(why)
    }

    /// What macOS's video decoder services hold (MB, their footprint): Pond's, and the app's live views'.
    public static func decoderFootprint() -> Int {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var total: UInt64 = 0
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var name = [CChar](repeating: 0, count: 64)
            guard proc_name(pid, &name, UInt32(name.count)) > 0,
                  String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "VTDecoderXPCService"
            else { continue }
            var usage = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if read == 0 { total += usage.ri_phys_footprint }
        }
        return Int(total / 1_048_576)
    }
}
