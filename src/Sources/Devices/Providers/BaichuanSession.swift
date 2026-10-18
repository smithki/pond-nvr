// One lasting Baichuan connection to a Reolink camera, as its apps keep: logged in, subscribed to its events, kept
// alive, and connected again when it drops. What the camera pushes is handed to whoever observes it: its privacy
// mode (574, 623) and what it notices (33: motion, a person, vehicle or animal, a doorbell's visitor). Requests
// (setting privacy) go over the same connection, their replies picked out by the reader. One per camera, shared
// (CameraSessions), so it takes one of the camera's few logins.
import Foundation

public final class BaichuanSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case connecting
        case connected
        /// It turned the login down (the password, or the account's rights).
        case refused
        case unreachable(String)
    }

    /// Told what the camera pushes (each optional).
    public struct Observer: Sendable {
        public var privacy: (@Sendable (Bool) -> Void)?
        public var motion: (@Sendable (Bool) -> Void)?
        public var pressed: (@Sendable () -> Void)?
        public var state: (@Sendable (State) -> Void)?

        public init(privacy: (@Sendable (Bool) -> Void)? = nil, motion: (@Sendable (Bool) -> Void)? = nil,
                    pressed: (@Sendable () -> Void)? = nil, state: (@Sendable (State) -> Void)? = nil) {
            self.privacy = privacy
            self.motion = motion
            self.pressed = pressed
            self.state = state
        }
    }

    /// Commands, and the channel byte events are subscribed on.
    enum Command {
        static let subscribe: UInt32 = 31
        static let event: UInt32 = 33
        static let keepalive: UInt32 = 93
        static let getPrivacy: UInt32 = 574
        static let setPrivacy: UInt32 = 575
        static let privacyPushed: UInt32 = 623
        static let eventsChannel: UInt8 = 251
    }

    static let keepaliveInterval: TimeInterval = 30

    let host: String
    let username: String
    let password: String
    private let lock = NSLock()
    private var client: BaichuanClient?
    private var started = false
    private var stopped = false
    private var waiters: [UInt32: @Sendable (BaichuanClient.Reply) -> Void] = [:]
    private var observers: [UUID: Observer] = [:]
    private var _state = State.connecting
    private var _privacy: Bool?
    private var moving = false
    private var visiting = false

    public init(host: String, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }

    public var state: State { lock.withLock { _state } }
    /// Its privacy mode as last told (at login, pushed, or set); nil until connected.
    public var privacyMode: Bool? { lock.withLock { _privacy } }

    /// Told from now on (and of the privacy mode and state at once, if known).
    @discardableResult
    public func observe(_ observer: Observer) -> UUID {
        let id = UUID()
        let (privacy, state) = lock.withLock { () -> (Bool?, State) in
            observers[id] = observer
            return (_privacy, _state)
        }
        observer.state?(state)
        if let privacy { observer.privacy?(privacy) }
        return id
    }

    public func forget(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }

    /// Connects (once; later calls do nothing), on a thread of its own, until stopped.
    public func start() {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        let thread = Thread { [self] in run() }
        thread.name = "baichuan \(host)"
        thread.qualityOfService = .utility
        thread.start()
    }

    public func stop() {
        let client = lock.withLock { () -> BaichuanClient? in
            stopped = true
            return self.client
        }
        client?.close()
    }

    var isStopped: Bool { lock.withLock { stopped } }

    // MARK: Requests

    /// Its privacy mode set, as it then says it is.
    public func setPrivacyMode(_ on: Bool) throws(BaichuanClient.Failure) -> Bool {
        let body = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <sleepState version="1.1">
        <operate>2</operate>
        <sleep>\(on ? 1 : 0)</sleep>
        </sleepState>
        </body>
        """
        _ = try request(Command.setPrivacy, body: body)
        let now = try readPrivacyMode()
        return now
    }

    public func readPrivacyMode() throws(BaichuanClient.Failure) -> Bool {
        let reply = try request(Command.getPrivacy, body: nil)
        guard let sleep = BaichuanClient.value("sleep", in: reply) else { throw .unexpected("no sleep state") }
        notePrivacy(sleep == "1")
        return sleep == "1"
    }

    /// A command to the camera (channel 0) over the session, its reply's XML.
    func request(_ command: UInt32, body: String?, timeout: Double = 8) throws(BaichuanClient.Failure) -> String {
        guard let client = lock.withLock({ client }) else { throw .unreachable("not connected") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply: BaichuanClient.Reply?
        lock.withLock {
            waiters[command] = { answer in
                reply = answer
                done.signal()
            }
        }
        try client.send(command: command, channel: 1, legacy: false, body: body, extension: BaichuanClient.channelExtension(0), aes: true)
        guard done.wait(timeout: .now() + timeout) == .success, let reply else {
            lock.withLock { waiters[command] = nil }
            throw .unreachable("no reply to \(command)")
        }
        guard reply.status == 200 else { throw .status(reply.status) }
        return reply.xml
    }

    // MARK: The connection

    private func run() {
        var pause = 2.0
        while !isStopped {
            let client = BaichuanClient(host: host, username: username, password: password)
            do throws(BaichuanClient.Failure) {
                try client.login()
                lock.withLock { self.client = client }
                pause = 2
                setState(.connected)
                // Asleep or not, as it said on logging in.
                if let sleep = BaichuanClient.value("sleep", in: client.loginReply ?? "") { notePrivacy(sleep == "1") }
                try client.send(command: Command.subscribe, channel: Command.eventsChannel, legacy: false, body: nil)
                var kept = Date()
                while !isStopped {
                    for reply in try client.pump(timeout: 1) { handle(reply) }
                    if Date().timeIntervalSince(kept) > Self.keepaliveInterval {
                        try client.send(command: Command.keepalive, channel: BaichuanClient.host, legacy: false, body: nil)
                        kept = Date()
                    }
                }
            } catch .loginRefused {
                setState(.refused)
                pause = 60
            } catch {
                setState(.unreachable(error.description))
            }
            let waiting = lock.withLock { () -> [@Sendable (BaichuanClient.Reply) -> Void] in
                self.client = nil
                defer { waiters = [:] }
                return Array(waiters.values)
            }
            client.close()
            // Requests waiting are let go (they time out).
            _ = waiting
            let until = Date().addingTimeInterval(pause)
            while !isStopped, Date() < until { Thread.sleep(forTimeInterval: 0.25) }
            pause = min(pause * 2, 60)
        }
    }

    private func handle(_ reply: BaichuanClient.Reply) {
        if let waiter = lock.withLock({ waiters.removeValue(forKey: reply.command) }) {
            waiter(reply)
            return
        }
        switch reply.command {
        case Command.getPrivacy, Command.privacyPushed:
            if let sleep = BaichuanClient.value("sleep", in: reply.xml) { notePrivacy(sleep == "1") }
        case Command.event:
            noteEvent(reply.xml)
        default:
            break
        }
    }

    private func setState(_ state: State) {
        let observers = lock.withLock { () -> [Observer]? in
            guard _state != state else { return nil }
            _state = state
            return Array(self.observers.values)
        }
        for observer in observers ?? [] { observer.state?(state) }
    }

    private func notePrivacy(_ on: Bool) {
        let observers = lock.withLock { () -> [Observer]? in
            guard _privacy != on else { return nil }
            _privacy = on
            return Array(self.observers.values)
        }
        for observer in observers ?? [] { observer.privacy?(on) }
    }

    /// An event (33): motion (its own detection, or a person, vehicle or animal) and a visitor (a doorbell's
    /// button), each told when it changes.
    private func noteEvent(_ xml: String) {
        guard let event = Self.alarm(in: xml) else { return }
        let (observers, motionChanged, pressedNow) = lock.withLock { () -> ([Observer], Bool, Bool) in
            let motionChanged = event.motion != moving
            let pressedNow = event.visitor && !visiting
            moving = event.motion
            visiting = event.visitor
            return (Array(self.observers.values), motionChanged, pressedNow)
        }
        for observer in observers {
            if motionChanged { observer.motion?(event.motion) }
            if pressedNow { observer.pressed?() }
        }
    }

    /// The camera's own channel's alarm event in a pushed 33: motion, and a visitor.
    static func alarm(in xml: String) -> (motion: Bool, visitor: Bool)? {
        var rest = xml[...]
        while let start = rest.range(of: "<AlarmEvent"), let end = rest.range(of: "</AlarmEvent>", range: start.upperBound ..< rest.endIndex) {
            let event = String(rest[start.lowerBound ..< end.upperBound])
            rest = rest[end.upperBound...]
            let channel = BaichuanClient.value("channelId", in: event) ?? "0"
            guard channel == "0" else { continue }
            let status = BaichuanClient.value("status", in: event) ?? ""
            let detected = (BaichuanClient.value("AItype", in: event) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let motion = status.contains("MD") || detected.contains { ["people", "vehicle", "dog_cat", "other"].contains($0) }
            return (motion, status.contains("visitor"))
        }
        return nil
    }
}
