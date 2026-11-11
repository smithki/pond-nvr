// Records one camera continuously, on its own thread: connect, record segments, and when anything fails,
// close the current segment and connect again after a pause that grows (1 s up to 30 s). Privacy mode is
// recognised and retried every 30 s without filling the log. A camera made private in Pond (PrivacyState) isn't
// recorded: its segment is closed and its connection let go until it's made public again. Made public while its
// own privacy mode was on, it's waking (PrivacyState): tried again every 2 s, quietly, until its video flows.
import Foundation
import Ingest
import PondCore

public final class CameraWorker: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case connecting
        case recording(since: Date)
        case privacyMode
        /// Made private in Pond: not recorded, by choice.
        case keptPrivate
        case offline(String)
        case storageUnavailable(String)
        case stopped
    }

    public let camera: Config.Camera
    let password: String
    let root: String
    let log: EventLog
    let segmentSeconds: Double
    let stallSeconds: Double
    /// Where the camera's stream comes from, shared with HomeKit.
    let hub: StreamHub
    let privacy: PrivacyState
    private var privacyObserver: UUID?
    /// Restarting the camera (through its controls, set by the service): how it was done, or nil if it couldn't
    /// be. Asked when its video server has refused every connection for `restartAfter` while the camera's there
    /// (not private, not waking); not again within `restartEvery`.
    let restart: (@Sendable (String) async -> String?)?
    let restartAfter: TimeInterval
    let restartEvery: TimeInterval

    private let lock = NSCondition()
    private var stopping = false
    private var thread: Thread?
    private var _status: Status = .connecting
    private var finished = false

    public var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    public init(camera: Config.Camera, password: String, recordingsRoot: String, log: EventLog,
                segmentSeconds: Double = 60, stallSeconds: Double = 10, hub: StreamHub = .shared,
                privacy: PrivacyState = .shared, restart: (@Sendable (String) async -> String?)? = nil,
                restartAfter: TimeInterval = 180, restartEvery: TimeInterval = 1800) {
        self.hub = hub
        self.privacy = privacy
        self.restart = restart
        self.restartAfter = restartAfter
        self.restartEvery = restartEvery
        self.camera = camera
        self.password = password
        root = recordingsRoot
        self.log = log
        self.segmentSeconds = segmentSeconds
        self.stallSeconds = stallSeconds
    }

    public func start() {
        // Made private or public: woken at once.
        let id = camera.id
        privacyObserver = privacy.observe { [weak self] camera, _ in
            guard camera == id, let self else { return }
            self.lock.lock()
            self.lock.broadcast()
            self.lock.unlock()
        }
        let t = Thread { [self] in run() }
        t.name = "pond camera \(camera.id)"
        thread = t
        t.start()
    }

    /// Asks the worker to finish its segment and stop, and waits up to `timeout` seconds for it.
    public func stop(timeout: Double = 10) {
        lock.lock()
        stopping = true
        lock.broadcast()
        let deadline = Date().addingTimeInterval(timeout)
        while !finished, lock.wait(until: deadline) {}
        lock.unlock()
        if let privacyObserver { privacy.forget(privacyObserver) }
    }

    /// Waits while the camera is private (woken when that changes, or when stopped).
    private func waitWhilePrivate() {
        lock.lock()
        while !stopping, privacy.isPrivate(camera.id) {
            _ = lock.wait(until: Date().addingTimeInterval(5))
        }
        lock.unlock()
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func setStatus(_ s: Status) {
        lock.lock()
        _status = s
        lock.unlock()
    }

    /// Sleeps, but wakes at once when stopped.
    private func pause(_ seconds: Double) {
        lock.lock()
        let deadline = Date().addingTimeInterval(seconds)
        while !stopping, lock.wait(until: deadline) {}
        lock.unlock()
    }

    private enum Stall: Error {
        /// Made private in Pond while recording.
        case keptPrivate
        case privacy
        case noVideo(Double)
    }

    /// The camera restarted through its controls (waited for: a few seconds), said in the log and to the doctor.
    private func restartCamera(minutes: Int) {
        let health = HealthLog.shared
        let why = "its video server has refused every connection for \(minutes) min, though the camera answers"
        guard let restart else {
            log.log(camera.id, "\(why); it can\u{2019}t be restarted from here (restart it, or unplug it for a few seconds)")
            return
        }
        log.log(camera.id, "\(why): restarting it")
        let done = DispatchSemaphore(value: 0)
        let outcome = RestartOutcome()
        let id = camera.id
        Task.detached {
            outcome.how = await restart(id)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 30)
        if let how = outcome.how {
            log.log(camera.id, "restarted (\(how)): back in a minute or so")
            health.record(camera.id, .restarted, how)
        } else {
            log.log(camera.id, "couldn\u{2019}t be restarted: restart it, or unplug it for a few seconds")
            health.record(camera.id, .restarted, "couldn\u{2019}t be restarted")
        }
    }

    /// How a restart went (nil: it couldn't, or not in time), set by the task that asks and read by the worker after.
    private final class RestartOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var _how: String?
        var how: String? {
            get { lock.withLock { _how } }
            set { lock.withLock { _how = newValue } }
        }
    }

    /// What kind of incident an error is, for the doctor.
    private static func healthKind(_ error: Error) -> HealthIncident.Kind {
        switch error {
        case Stall.privacy: return .privacyMode
        case Stall.noVideo: return .stalled
        case RTSPError.unauthorized: return .loginRefused
        case RTSPError.timeout, RTSPError.transport: return .unreachable
        default: return .failed
        }
    }

    private func run() {
        let recovered = SegmentFiles.recoverPartials(root: root, camera: camera.id)
        if recovered > 0 { log.log(camera.id, "recovered \(recovered) segment\(recovered == 1 ? "" : "s") left by an earlier stop") }
        let files = SegmentFiles(root: root, camera: camera.id, log: log)
        var backoff = 1.0
        var lastProblem: String?
        // Its video server refusing every connection though the camera's there: since when, and when it was last
        // restarted for it.
        var refusedSince: Date?
        var lastRestart: Date?
        var problemSince = Date()
        var lastReported = Date()
        var saidWaking = false
        // Its health, for the doctor: how the video flows, and what happens to it.
        var meter = VideoMeter(camera: camera.id, videoChannel: CameraSession.videoChannel)
        let health = HealthLog.shared

        while !isStopping {
            if privacy.isPrivate(camera.id) {
                log.log(camera.id, "private: not recording")
                setStatus(.keptPrivate)
                waitWhilePrivate()
                if isStopping { break }
                log.log(camera.id, "no longer private")
                backoff = 1
                lastProblem = nil
                continue
            }
            setStatus(.connecting)
            var recorder: StreamRecorder?
            do {
                let session = try hub.open(url: camera.recordedStream, username: camera.username, password: password)
                defer { session.close() }
                let r = StreamRecorder(video: session.video, audio: session.audio, segmentSeconds: segmentSeconds)
                recorder = r
                var lastVideo = Date()
                var senderPackets: UInt32?
                var announced = false
                while !isStopping {
                    if privacy.isPrivate(camera.id) { throw Stall.keptPrivate }
                    let packet = try session.next(timeout: 1)
                    let now = Date()
                    if let packet, let sample = meter.add(channel: packet.channel, data: packet.data, at: now) { health.add(sample) }
                    if let packet {
                        if packet.channel == CameraSession.videoChannel {
                            lastVideo = now
                        } else if packet.channel == CameraSession.videoChannel + 1 {
                            senderPackets = RTCP.senderPacketCount(packet.data) ?? senderPackets
                        }
                        let outputs = r.handle(packet, now: now.timeIntervalSince1970)
                        if packet.channel == CameraSession.videoChannel, let placed = r.lastPlaced {
                            StreamLatency.shared.noteRecorded(camera.id, placed: placed, arrived: now.timeIntervalSince1970)
                        }
                        files.handle(outputs)
                        if !announced, outputs.contains(where: { if case .start = $0 { true } else { false } }) {
                            announced = true
                            backoff = 1
                            lastProblem = nil
                            log.log(camera.id, "recording" + (session.audio == nil ? " (no audio)" : ""))
                            refusedSince = nil
                            health.record(camera.id, .connected)
                            saidWaking = false
                            // Awake, if it was waking: what waited to be set on it is.
                            privacy.awake(camera.id)
                            // Sending video: its own privacy mode (if it was on) is off.
                            privacy.cameraReports(camera.id, privacyMode: false)
                        }
                    }
                    let silent = now.timeIntervalSince(lastVideo)
                    if silent > stallSeconds {
                        throw senderPackets == 0 ? Stall.privacy : Stall.noVideo(silent)
                    }
                    if announced {
                        if case let .unavailable(reason) = files.state {
                            setStatus(.storageUnavailable(reason))
                        } else if case .recording = status {} else {
                            setStatus(.recording(since: now))
                        }
                    }
                }
                files.handle(r.finish())
                if let sample = meter.finish() { health.add(sample) }
            } catch {
                files.handle(recorder?.finish() ?? [])
                if let sample = meter.finish() { health.add(sample) }
                // Private: the segment is closed and the connection let go; not a problem.
                if case Stall.keptPrivate = error { continue }
                // Starting its video again after its own privacy mode: not a problem (nor its privacy mode on).
                if privacy.isWaking(camera.id) {
                    if !saidWaking { log.log(camera.id, "waking from privacy mode: waiting for its video") }
                    saidWaking = true
                    setStatus(.connecting)
                    pause(2)
                    continue
                }
                // Waking, and its time is up with no video: its video server is stuck. Said once; it's retried
                // as any other problem from now on.
                if saidWaking {
                    saidWaking = false
                    let why = (error as? RTSPError)?.description ?? "\(error)"
                    log.log(camera.id, "didn\u{2019}t start its video again after privacy mode (\(why)); it may need restarting")
                    health.record(camera.id, .wakeFailed, why)
                }
                // Refused, not private or waking (so its video server should be up): after a few minutes of it, the
                // camera restarted (its controls often still answer when its video server doesn't).
                if case RTSPError.transport(.refused) = error {
                    let since = refusedSince ?? Date()
                    refusedSince = since
                    if Date().timeIntervalSince(since) >= restartAfter, lastRestart.map({ Date().timeIntervalSince($0) >= restartEvery }) ?? true {
                        lastRestart = Date()
                        restartCamera(minutes: Int((Date().timeIntervalSince(since) / 60).rounded()))
                    }
                } else {
                    refusedSince = nil
                }
                let problem: String
                var wait = backoff
                switch error {
                case Stall.privacy:
                    problem = "privacy mode is on; checking again every 30 s"
                    setStatus(.privacyMode)
                    // Shown as private everywhere (the app, HomeKit) while it lasts.
                    privacy.cameraReports(camera.id, privacyMode: true)
                    wait = 30
                case let Stall.noVideo(s):
                    problem = String(format: "no video for %.0f s", s)
                    setStatus(.offline(problem))
                case let e as RTSPError:
                    problem = e.description
                    setStatus(.offline(problem))
                default:
                    problem = "\(error)"
                    setStatus(.offline(problem))
                }
                // A new problem is logged at once; the same one again every 5 minutes, with when it began, so a
                // long outage shows in the log instead of going quiet.
                if problem != lastProblem {
                    log.log(camera.id, "\(problem); reconnecting")
                    // For the doctor: each new problem once (as logged), not every retry.
                    health.record(camera.id, Self.healthKind(error), problem)
                    problemSince = Date()
                    lastReported = Date()
                } else if Date().timeIntervalSince(lastReported) >= 300 {
                    let since = problemSince.formatted(date: .omitted, time: .shortened)
                    log.log(camera.id, "still \(problem), since \(since); reconnecting")
                    lastReported = Date()
                }
                lastProblem = problem
                pause(wait)
                backoff = min(backoff * 2, 30)
            }
        }
        setStatus(.stopped)
        lock.lock()
        finished = true
        lock.broadcast()
        lock.unlock()
    }
}
