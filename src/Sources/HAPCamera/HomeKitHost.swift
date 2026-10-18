// Runs each configured camera as its own HomeKit accessory. A camera's HomeKit identity (device ID, signing
// key), setup code and pairings are kept in the login Keychain under "pond-homekit", so they survive restarts
// and the camera stays paired.
import CryptoKit
import Foundation
import Synchronization
import Devices
import HAP
import NVRCore

/// What a camera keeps in the Keychain for HomeKit.
public struct HomeKitRecord: Codable, Sendable {
    public var deviceID: String
    var signingKey: Data
    public var setupCode: String
    public var setupID: String
    public var pairings: [PairedController]
    /// The port it last listened on, reused so controllers find it where they left it.
    public var port: UInt16?
    /// The accessory database's shape when last served, and its configuration number: the number goes up
    /// when the shape changes (a service added), so controllers fetch the database again.
    public var layout: String?
    public var configNumber: Int?
    /// HomeKit Secure Video's settings, as the hub left them.
    public var recording: RecordingState?

    public static func new() -> HomeKitRecord {
        let identity = AccessoryIdentity.generate()
        let setup = SetupInfo.generate()
        return HomeKitRecord(deviceID: identity.deviceID, signingKey: identity.signingKey.rawRepresentation,
                             setupCode: setup.code, setupID: setup.setupID, pairings: [])
    }

    var identity: AccessoryIdentity {
        AccessoryIdentity(deviceID: deviceID, signingKey: (try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKey))
            ?? Curve25519.Signing.PrivateKey())
    }

    public var setup: SetupInfo { SetupInfo(code: setupCode, setupID: setupID) }
    public var isPaired: Bool { !pairings.isEmpty }
}

/// Where records are kept, by camera id: the Keychain, or memory in tests.
public protocol HomeKitRecords: Sendable {
    func record(for camera: String) -> HomeKitRecord?
    func save(_ record: HomeKitRecord, for camera: String)
    func remove(for camera: String)
}

/// Records as JSON in a CredentialStore (the Keychain, service "pond-homekit").
public struct CredentialHomeKitRecords: HomeKitRecords {
    let store: CredentialStore

    public init(store: CredentialStore) { self.store = store }

    public func record(for camera: String) -> HomeKitRecord? {
        guard let text = try? store.password(for: camera) else { return nil }
        return try? JSONDecoder().decode(HomeKitRecord.self, from: Data(text.utf8))
    }

    public func save(_ record: HomeKitRecord, for camera: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? store.setPassword(String(decoding: data, as: UTF8.self), for: camera)
    }

    public func remove(for camera: String) { try? store.removePassword(for: camera) }
}

/// A camera's pairings, read from and written to its record.
final class RecordPairingStore: PairingStore, @unchecked Sendable {
    let records: HomeKitRecords
    let camera: String
    private let lock = NSLock()

    init(records: HomeKitRecords, camera: String) {
        self.records = records
        self.camera = camera
    }

    func pairings() -> [PairedController] { lock.withLock { records.record(for: camera)?.pairings ?? [] } }

    func save(_ pairings: [PairedController]) {
        lock.withLock {
            guard var r = records.record(for: camera) else { return }
            r.pairings = pairings
            records.save(r, for: camera)
        }
    }
}

/// The cameras on HomeKit.
public final class HomeKitHost: @unchecked Sendable {
    public struct Running: Sendable {
        public let camera: Config.Camera
        public let record: HomeKitRecord
        public let listener: HAPListener
        public let accessory: CameraAccessory
    }

    let records: HomeKitRecords
    public private(set) var running: [Running] = []
    public var log: @Sendable (String) -> Void
    /// Called with the whole status whenever any of it changes (the service writes it to a file).
    public var statusChanged: (@Sendable (HomeKitStatus) -> Void)?
    private var status = HomeKitStatus()
    private var watchers: [CameraEvents] = []
    private let lock = NSLock()
    /// Pond's privacy: a private camera has no live view, snapshots or motion in HomeKit, and shows as off in
    /// the Home app; turning it off or on there makes it private or not.
    let privacy: PrivacyState
    private var privacyObservers: [UUID] = []

    public init(records: HomeKitRecords, privacy: PrivacyState = .shared, log: @escaping @Sendable (String) -> Void) {
        self.records = records
        self.privacy = privacy
        self.log = log
    }

    /// The camera's record, made (with a new setup code) if it has none.
    public func record(for camera: String) -> HomeKitRecord {
        if let r = records.record(for: camera) { return r }
        let r = HomeKitRecord.new()
        records.save(r, for: camera)
        return r
    }

    /// Changes one camera's status and passes the whole on.
    func update(_ id: String, _ change: (inout HomeKitStatus.Camera) -> Void) {
        let snapshot = lock.withLock { () -> HomeKitStatus? in
            let before = status.cameras[id]
            var c = before ?? HomeKitStatus.Camera()
            change(&c)
            guard c != before else { return nil }
            status.cameras[id] = c
            status.updated = Date()
            return status
        }
        if let snapshot { statusChanged?(snapshot) }
    }

    /// Starts an accessory for each camera that is to be in HomeKit. A camera that cannot start is left out
    /// (and its status says why); the others carry on.
    public func start(cameras: [Config.Camera], password: (String) -> String?) {
        lock.withLock { status = HomeKitStatus() }
        statusChanged?(lock.withLock { status })
        for camera in cameras where camera.homekit {
            guard let password = password(camera.id) else {
                log("! HomeKit: \(camera.name) has no password in the Keychain; left out.")
                update(camera.id) { $0.problem = .init(.noPassword, during: .starting) }
                continue
            }
            do {
                try start(camera, password: password)
            } catch {
                log("! HomeKit: \(camera.name) could not start: \(error)")
                update(camera.id) { $0.running = false; $0.problem = .init(.couldNotStart, during: .starting) }
            }
        }
    }

    /// The configuration number for a database of this shape: as before if the shape is the same, else one
    /// more (kept with the camera's record, from 1 to 65535).
    static func configNumber(for layout: String, camera id: String, records: HomeKitRecords) -> Int {
        guard var record = records.record(for: id) else { return 1 }
        let current = record.configNumber ?? 1
        if record.layout == layout { return current }
        // A record from before layouts were kept was served as 1, with this shape or the one before.
        let next = record.layout == nil && record.configNumber == nil ? 2 : current % 65535 + 1
        record.layout = layout
        record.configNumber = next
        records.save(record, for: id)
        return next
    }

    /// A camera's own log lines, named: "HomeKit: …" becomes "HomeKit (Doorbell): …", so two cameras
    /// recording at once can be told apart.
    static func labelled(_ name: String, _ log: @escaping @Sendable (String) -> Void) -> @Sendable (String) -> Void {
        { line in
            guard let range = line.range(of: "HomeKit:") else { return log(line) }
            log(line.replacingCharacters(in: range, with: "HomeKit (\(name)):"))
        }
    }

    private func start(_ camera: Config.Camera, password: String) throws {
        let id = camera.id
        let record = record(for: id)
        // A slot per viewer at once (iPhone and Mac, say), all reading the one camera connection.
        let streams = (0 ..< camera.homeKitViewerSlots).map { _ in
            StreamManagement(main: (camera.main, camera.username, password), sub: (camera.sub, camera.username, password),
                             reencode: camera.reencodesForHomeKit, log: log)
        }
        let doorbell = camera.kind == .doorbell
        // HomeKit Secure Video, for a camera set to record in HomeKit: its state kept with the record.
        // Not while it is video only: nothing would start a recording (its choice stays, and comes back).
        // Revisit with Pond's own detection, which could start recordings for a video-only camera too.
        let recording = camera.homekitRecording == true && !camera.isVideoOnly
            ? RecordingController(options: RecordingOptions(doorbell: doorbell), state: record.recording,
                                  source: (camera.main, camera.username, password),
                                  log: Self.labelled(camera.name, log)) : nil
        recording?.camera = id
        recording?.statusChanged = { [weak self] status in self?.update(id) { $0.recording = status } }
        // Told once now, so the app shows the camera waiting for the hub before the hub writes anything.
        recording?.report { _ in }
        let store = self.records
        recording?.saved = { state in
            if var latest = store.record(for: id) {
                latest.recording = state
                store.save(latest, for: id)
            }
        }
        // Talking back from the Home app, for a camera that can be talked through (as the app's talk button): its
        // speaker through the same controls, and connections, the service keeps for it.
        let talks = camera.device?.controls?.talk != nil && !camera.isVideoOnly
        let controls = talks ? CameraControls(access: CameraAccess(host: camera.host, username: camera.username, password: password,
                                                                   mainStream: camera.main), device: camera.device) : nil
        let privacy = self.privacy
        var speaker: (@Sendable () async -> (any TalkSession)?)?
        if let controls {
            speaker = { @Sendable () async -> (any TalkSession)? in
                // Not while private: nothing of it is shown, and nothing is said through it.
                guard !privacy.isPrivate(id) else { return nil }
                do throws(ControlFailure) {
                    let session: any TalkSession = try await controls.withTalk { c throws(ControlFailure) in try await c.open() }
                    return session
                } catch {
                    return nil
                }
            }
        }
        let accessory = CameraAccessory(name: camera.name, details: AccessoryDetails(device: camera.device, cameraID: id),
                                        doorbell: doorbell, streams: streams, recording: recording, speaker: speaker)
        // The recording offers count as the shape too: changed, controllers look again.
        let configNumber = Self.configNumber(for: accessory.accessory.layoutDigest + (recording?.options.digest ?? ""),
                                             camera: id, records: records)
        let server = AccessoryServer(identity: record.identity, store: RecordPairingStore(records: records, camera: id),
                                     accessory: accessory.accessory, setupCode: record.setupCode)
        let snapshots = Snapshotter(url: camera.sub, username: camera.username, password: password)
        snapshots.keyframe = { streams.lazy.compactMap(\.latestKeyframe).first }
        let name = camera.name
        let log = self.log
        for stream in streams { stream.allowed = { !privacy.isPrivate(id) } }
        // Nor its main stream held for HomeKit Secure Video's prebuffer.
        recording?.prebuffer?.paused = { privacy.isPrivate(id) }
        // Private: off in the Home app and its live views ended (the Home app's own on and off is HomeKit's,
        // and never changes Pond's privacy).
        recording?.setPrivate(privacy.isPrivate(id) || privacy.isPrivateOnCamera(id))
        let observer = privacy.observe { [weak recording] camera, isPrivate in
            guard camera == id else { return }
            recording?.setPrivate(isPrivate)
            if isPrivate { for stream in streams { stream.stop() } }
        }
        lock.withLock { privacyObservers.append(observer) }
        server.snapshot = { [weak self] width, height in
            // None while private (the Home app shows the camera as off).
            if privacy.isPrivate(id) { return nil }
            let jpeg = await snapshots.jpeg(width: width, height: height)
            if jpeg == nil {
                log("! HomeKit: no snapshot from \(name)")
                let kind = snapshots.lastProblem ?? .other
                self?.update(id) { $0.problem = .init(kind, during: .snapshot) }
            } else {
                log("✓ HomeKit: snapshot of \(name), \(width)×\(height)")
                self?.update(id) { if $0.problem?.during == .snapshot { $0.problem = nil } }
            }
            return jpeg
        }
        let watching = Mutex(Set<Int>())
        for (slot, stream) in streams.enumerated() {
            stream.statusChanged = { [weak self, weak accessory] inUse in
                accessory?.setStreaming(inUse, slot: slot)
                let viewers = watching.withLock { set in
                    if inUse { set.insert(slot) } else { set.remove(slot) }
                    return set.count
                }
                self?.update(id) { $0.viewers = viewers }
            }
            stream.problem = { [weak self] kind in self?.update(id) { $0.problem = .init(kind, during: .liveView) } }
            stream.playing = { [weak self] in self?.update(id) { if $0.problem?.during != .starting { $0.problem = nil } } }
        }
        server.log = log
        server.sessionVerified = { [weak self] keys in
            log("✓ HomeKit: \(name) opened by controller \(keys.controller.identifier.prefix(8))…")
            // Only a paired controller gets this far.
            self?.update(id) { $0.paired = true; $0.setup = nil }
        }
        let listener = HAPListener(server: server, name: camera.name, model: accessory.model,
                                   category: doorbell ? .videoDoorbell : .ipCamera, setup: record.setup)
        listener.log = log
        listener.configNumber = configNumber
        // The listener refreshes its advertisement on pairing changes; the status follows them too.
        // (The listener adds its own handler to this when it starts, to refresh its advertisement.)
        let records = self.records
        let setup = HomeKitStatus.Camera.Setup(code: record.setupCode,
                                               uri: record.setup.uri(category: (doorbell ? AccessoryCategory.videoDoorbell : .ipCamera).rawValue))
        server.pairingsChanged = { [weak self] in
            let paired = records.record(for: id)?.isPaired ?? false
            self?.update(id) { $0.paired = paired; $0.setup = paired ? nil : setup }
        }
        try listener.start(port: record.port)
        // Started afresh, keeping the recording status already told.
        update(id) {
            let recording = $0.recording
            $0 = HomeKitStatus.Camera(running: true, paired: record.isPaired, setup: record.isPaired ? nil : setup)
            $0.recording = recording
        }
        log("HomeKit: \(camera.name) is \(record.isPaired ? "in the Home app" : "waiting to be added to the Home app")")

        let seesMotion = watchEvents(camera, password: password, accessory: accessory)
        recording?.report { $0.motion = seesMotion }

        // Remember the port once known, so the camera comes back where controllers expect it.
        Task {
            for _ in 0 ..< 50 {
                if let port = listener.port {
                    if var latest = records.record(for: id), latest.port != port {
                        latest.port = port
                        records.save(latest, for: id)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        lock.withLock { running.append(Running(camera: camera, record: record, listener: listener, accessory: accessory)) }
    }

    /// A doorbell's button, through the provider that recognised the camera.
    /// Watches what the camera notices: motion sets its motion sensor (which the home hub records on, with
    /// HomeKit Secure Video, and notifies about); a doorbell's press rings in the Home app.
    /// Whether the camera's provider can tell motion at all.
    @discardableResult
    private func watchEvents(_ camera: Config.Camera, password: String, accessory: CameraAccessory) -> Bool {
        let id = camera.id, name = camera.name, log = self.log, doorbell = camera.kind == .doorbell
        if camera.isVideoOnly {
            log("HomeKit: \(name) is set to video only: its motion\(doorbell ? " and button" : "") aren't watched")
            if doorbell { update(id) { $0.doorbell = .videoOnly } }
            return false
        }
        guard let events = CameraProviders.provider(camera.device?.provider)?
            .events(host: camera.host, username: camera.username, password: password) else {
            if doorbell {
                log("! HomeKit: \(name) is a doorbell, but pond knows no way to see its button presses")
                update(id) { $0.doorbell = camera.device == nil ? .unknownModel : .notSupported }
            }
            return false
        }
        let motion = MotionHold(accessory: accessory, name: name, log: log)
        // Private: no motion (nothing watches the camera). A doorbell still rings: someone is at the door.
        let privacy = self.privacy
        events.start(motion: { moving in motion.set(moving && !privacy.isPrivate(id)) }, pressed: { [weak accessory] in
            guard doorbell else { return }
            log("HomeKit: \(name) rang")
            accessory?.ring()
        }, state: { [weak self] state in
            guard doorbell else { return }
            self?.update(id) { $0.doorbell = HomeKitStatus.DoorbellState(state) }
        })
        lock.withLock { watchers.append(events) }
        return true
    }

    public func stop() {
        let (all, events) = lock.withLock { () -> ([Running], [CameraEvents]) in
            defer { running = []; watchers = [] }
            return (running, watchers)
        }
        for e in events { e.stop() }
        for r in all { r.listener.stop() }
        for observer in lock.withLock({ privacyObservers }) { privacy.forget(observer) }
        lock.withLock { privacyObservers = [] }
        lock.withLock {
            for id in status.cameras.keys { status.cameras[id]?.running = false; status.cameras[id]?.viewers = 0 }
        }
        statusChanged?(lock.withLock { status })
    }
}

extension HomeKitStatus.DoorbellState {
    init(_ state: DoorbellButtonState) {
        switch state {
        case .watching: self = .watching
        case .notSupported: self = .notSupported
        case .unreachable: self = .cameraUnreachable
        case .loginRefused: self = .loginRefused
        }
    }
}

/// A camera's motion sensor, from its own detection: on at once, and off no sooner than `hold` seconds later
/// (a brief movement still registers with the home hub).
final class MotionHold: @unchecked Sendable {
    static let hold = 5.0
    weak var accessory: CameraAccessory?
    let name: String
    let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var since: Date?
    private var off: Task<Void, Never>?

    init(accessory: CameraAccessory, name: String, log: @escaping @Sendable (String) -> Void) {
        self.accessory = accessory
        self.name = name
        self.log = log
    }

    func set(_ moving: Bool) {
        if moving {
            let first = lock.withLock { () -> Bool in
                off?.cancel()
                off = nil
                defer { since = since ?? Date() }
                return since == nil
            }
            if first {
                log("HomeKit: motion at \(name)")
                accessory?.motion.update(.bool(true))
            }
            return
        }
        lock.withLock {
            guard let since else { return }
            let wait = max(0, Self.hold - Date().timeIntervalSince(since))
            off = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                lock.withLock { self.since = nil }
                log("HomeKit: motion over at \(name)")
                accessory?.motion.update(.bool(false))
            }
        }
    }
}
