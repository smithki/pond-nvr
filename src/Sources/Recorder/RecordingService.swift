// Everything `pond run` runs: a worker per camera and the retention sweep every few minutes, until a
// signal (Ctrl-C, or launchd stopping the service) or an optional time limit. Cameras can be added, taken
// away or changed while it runs (`add`, `remove`), and retention changed (`setConfig`), the others going on.
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
    private var config: Config
    let passwords: [String: String]
    let log: EventLog
    let segmentSeconds: Double
    let sweepInterval: Double
    private let lock = NSLock()
    private var running: [String: CameraWorker] = [:]
    public var workers: [CameraWorker] { lock.withLock { Array(running.values) } }

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
        for camera in config.cameras { add(camera, password: passwords[camera.id]) }

        // With the settings as they are at each sweep (they can change while it runs).
        let log = self.log
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pond.retention"))
        timer.schedule(deadline: .now(), repeating: sweepInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            _ = RetentionSweeper(config: lock.withLock { config }, log: log).sweep()
        }
        timer.resume()

        if let seconds {
            _ = done.wait(timeout: .now() + seconds)
        } else {
            done.wait()
        }
        log.log("pond", "stopping")
        timer.cancel()
        for worker in workers { worker.stop() }
        lock.withLock { running = [:] }
        sources.forEach { $0.cancel() }
        log.log("pond", "stopped")
    }

    /// Restarting a camera through its controls (set by the service, before cameras are added): how, or nil.
    /// Asked by a camera's worker when its video server keeps refusing connections though the camera's there.
    nonisolated(unsafe) public var restart: (@Sendable (String) async -> String?)?

    /// A camera recorded from now, alongside the others (changed: `remove` it first).
    public func add(_ camera: Config.Camera, password: String?) {
        guard let password else {
            log.log(camera.id, "not started: no password in the Keychain")
            return
        }
        let worker = CameraWorker(camera: camera, password: password, recordingsRoot: lock.withLock { config.storage.recordingsPath },
                                  log: log, segmentSeconds: segmentSeconds, restart: restart)
        let previous = lock.withLock { () -> CameraWorker? in
            defer { running[camera.id] = worker }
            return running[camera.id]
        }
        previous?.stop()
        worker.start()
    }

    /// A camera no longer recorded: its segment finished and its connection let go.
    public func remove(_ id: String) {
        let worker = lock.withLock { running.removeValue(forKey: id) }
        worker?.stop()
    }

    /// The settings as they are now (for retention: its days, size and free space; the cameras' own changes
    /// are `add` and `remove`).
    public func setConfig(_ next: Config) { lock.withLock { config = next } }

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
