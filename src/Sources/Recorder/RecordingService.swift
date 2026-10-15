// Everything `pond run` runs: a worker per camera and the retention sweep every few minutes, until a
// signal (Ctrl-C, or launchd stopping the service) or an optional time limit.
import Foundation
import NVRCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(IOKit)
import IOKit.pwr_mgt
#endif

public final class RecordingService: @unchecked Sendable {
    let config: Config
    let passwords: [String: String]
    let log: EventLog
    let segmentSeconds: Double
    let sweepInterval: Double
    public private(set) var workers: [CameraWorker] = []

    public init(config: Config, passwords: [String: String], log: EventLog, segmentSeconds: Double = 60,
                sweepInterval: Double = 300) {
        self.config = config
        self.passwords = passwords
        self.log = log
        self.segmentSeconds = segmentSeconds
        self.sweepInterval = sweepInterval
    }

    /// Runs until SIGINT or SIGTERM, or for `seconds` if given.
    public func run(for seconds: Double? = nil) {
        let done = DispatchSemaphore(value: 0)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let queue = DispatchQueue(label: "pond.signals")
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { done.signal() }
            source.resume()
            sources.append(source)
        }

        let awake = preventIdleSleep()
        defer { allowIdleSleep(awake) }
        log.log("pond", "starting: \(config.cameras.count) camera\(config.cameras.count == 1 ? "" : "s"), recording to \(config.storage.recordingsPath)")
        for camera in config.cameras {
            guard let password = passwords[camera.id] else {
                log.log(camera.id, "not started: no password in the Keychain")
                continue
            }
            let worker = CameraWorker(camera: camera, password: password, recordingsRoot: config.storage.recordingsPath,
                                      log: log, segmentSeconds: segmentSeconds)
            workers.append(worker)
            worker.start()
        }

        let sweeper = RetentionSweeper(config: config, log: log)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pond.retention"))
        timer.schedule(deadline: .now(), repeating: sweepInterval)
        timer.setEventHandler { _ = sweeper.sweep() }
        timer.resume()

        if let seconds {
            _ = done.wait(timeout: .now() + seconds)
        } else {
            done.wait()
        }
        log.log("pond", "stopping")
        timer.cancel()
        for worker in workers { worker.stop() }
        sources.forEach { $0.cancel() }
        log.log("pond", "stopped")
    }

    /// A sleeping Mac records nothing, so idle sleep is held off while recording (the display may still
    /// sleep). Returns the assertion to release, or 0.
    private func preventIdleSleep() -> UInt32 {
        #if canImport(IOKit)
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "pond is recording cameras" as CFString, &id)
        if result != kIOReturnSuccess { log.log("pond", "could not keep the Mac awake; it may sleep and stop recording") }
        return id
        #else
        return 0
        #endif
    }

    private func allowIdleSleep(_ id: UInt32) {
        #if canImport(IOKit)
        if id != 0 { IOPMAssertionRelease(id) }
        #endif
    }
}
