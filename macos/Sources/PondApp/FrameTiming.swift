// How promptly the main thread answers, for measuring the app's animations: a thread of its own asks it to answer
// every 4 ms and notes how late each answer is (more than a frame, 16 ms at 60 Hz, is a frame missed). Measured
// around a stretch (`begin` and `end`: the snapshot mode's transition check, docs/development.md); and, with
// POND_STALLS set, each answer over 40 ms logged with what the Events grid was doing then. Neither costs anything
// unless asked for: the thread only starts when one is.
import Foundation
import os
import QuartzCore

let frameLog = Logger(subsystem: "camera.pond", category: "frames")

final class FrameTiming: @unchecked Sendable {
    static let shared = FrameTiming()
    /// Stalls logged as they happen (POND_STALLS).
    static let logsStalls = ProcessInfo.processInfo.environment["POND_STALLS"] != nil

    private let lock = NSLock()
    private var started = false
    private var recording: [Double]?
    private var stage = "idle"

    /// How late each answer was, seconds, from now until `end`.
    func begin() {
        start()
        lock.withLock { recording = [] }
    }

    func end() -> [Double] {
        lock.withLock {
            defer { recording = nil }
            return recording ?? []
        }
    }

    /// What's under way, for a while (for the logged stalls).
    func during(_ what: String, for seconds: Double) {
        guard Self.logsStalls else { return }
        start()
        lock.withLock { stage = what }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            lock.withLock { if stage == what { stage = "idle" } }
        }
    }

    private func start() {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        let thread = Thread { [self] in
            while true {
                let asked = CACurrentMediaTime()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let late = CACurrentMediaTime() - asked
                let what = lock.withLock { () -> String in
                    recording?.append(late)
                    return stage
                }
                if Self.logsStalls, late > 0.04 { frameLog.notice("stall \(Int(late * 1000)) ms during \(what, privacy: .public)") }
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
        thread.name = "pond frame timing"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
