// Records one camera continuously, on its own thread: connect, record segments, and when anything fails,
// close the current segment and connect again after a pause that grows (1 s up to 30 s). Privacy mode is
// recognised and retried every 30 s without filling the log.
import Foundation
import Ingest
import NVRCore

public final class CameraWorker: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case connecting
        case recording(since: Date)
        case privacyMode
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
                segmentSeconds: Double = 60, stallSeconds: Double = 10, hub: StreamHub = .shared) {
        self.hub = hub
        self.camera = camera
        self.password = password
        root = recordingsRoot
        self.log = log
        self.segmentSeconds = segmentSeconds
        self.stallSeconds = stallSeconds
    }

    public func start() {
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
        case privacy
        case noVideo(Double)
    }

    private func run() {
        let recovered = SegmentFiles.recoverPartials(root: root, camera: camera.id)
        if recovered > 0 { log.log(camera.id, "recovered \(recovered) segment\(recovered == 1 ? "" : "s") left by an earlier stop") }
        let files = SegmentFiles(root: root, camera: camera.id, log: log)
        var backoff = 1.0
        var lastProblem: String?
        var problemSince = Date()
        var lastReported = Date()

        while !isStopping {
            setStatus(.connecting)
            var recorder: StreamRecorder?
            do {
                let session = try hub.open(url: camera.main, username: camera.username, password: password)
                defer { session.close() }
                let r = StreamRecorder(video: session.video, audio: session.audio, segmentSeconds: segmentSeconds)
                recorder = r
                var lastVideo = Date()
                var senderPackets: UInt32?
                var announced = false
                while !isStopping {
                    let packet = try session.next(timeout: 1)
                    let now = Date()
                    if let packet {
                        if packet.channel == CameraSession.videoChannel {
                            lastVideo = now
                        } else if packet.channel == CameraSession.videoChannel + 1 {
                            senderPackets = RTCP.senderPacketCount(packet.data) ?? senderPackets
                        }
                        let outputs = r.handle(packet, now: now.timeIntervalSince1970)
                        files.handle(outputs)
                        if !announced, outputs.contains(where: { if case .start = $0 { true } else { false } }) {
                            announced = true
                            backoff = 1
                            lastProblem = nil
                            log.log(camera.id, "recording" + (session.audio == nil ? " (no audio)" : ""))
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
            } catch {
                files.handle(recorder?.finish() ?? [])
                let problem: String
                var wait = backoff
                switch error {
                case Stall.privacy:
                    problem = "privacy mode is on; checking again every 30 s"
                    setStatus(.privacyMode)
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
