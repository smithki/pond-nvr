// The connection to the signaling service: one WebSocket, its mailbox claimed (with the secret only this identity
// can derive), envelopes sent to others' mailboxes and received in its own. Kept up: dropped, it connects again
// (waiting longer each time, up to a minute).
import Foundation
import Signal

public final class SignalClient: @unchecked Sendable {
    let url: URL
    let identity: RemoteIdentity
    let received: @Sendable (Envelope) -> Void
    let log: @Sendable (String) -> Void
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var running = false
    /// Sends waiting for the service's word (sent, or undelivered), in order.
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private var ready: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()

    public init(url: URL, identity: RemoteIdentity, received: @escaping @Sendable (Envelope) -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.url = url
        self.identity = identity
        self.received = received
        self.log = log
    }

    /// Connected, and kept connected, until stopped.
    public func start() {
        lock.withLock { running = true }
        Task.detached { [self] in
            var wait = 1.0
            while lock.withLock({ running }) {
                if await connect() {
                    wait = 1
                    await receive()
                }
                guard lock.withLock({ running }) else { return }
                try? await Task.sleep(for: .seconds(wait))
                wait = min(60, wait * 2)
            }
        }
    }

    public func stop() {
        let (task, waiting) = lock.withLock { () -> (URLSessionWebSocketTask?, [CheckedContinuation<Bool, Never>]) in
            running = false
            defer { self.waiting = [] }
            return (self.task, self.waiting)
        }
        task?.cancel(with: .goingAway, reason: nil)
        for w in waiting { w.resume(returning: false) }
    }

    /// Whether it's connected, its mailbox claimed.
    public private(set) var isConnected = false

    /// An envelope sent: true if it was passed on (its recipient connected), false if not (or not connected).
    public func send(_ envelope: Envelope) async -> Bool {
        guard let task = lock.withLock({ isConnected ? self.task : nil }) else { return false }
        let message = SignalServer.Message(op: "send", to: envelope.to, sealed: envelope.sealed)
        return await withCheckedContinuation { continuation in
            lock.withLock { waiting.append(continuation) }
            task.send(.string(Self.encode(message))) { [self] error in
                guard error != nil else { return }
                let w = lock.withLock { waiting.isEmpty ? nil : waiting.removeLast() }
                w?.resume(returning: false)
            }
        }
    }

    /// Connected and its mailbox claimed (the service said ready).
    func connect() async -> Bool {
        let task = session.webSocketTask(with: url)
        lock.withLock { self.task = task }
        task.resume()
        let hello = SignalServer.Message(op: "hello", mailbox: identity.peer.mailbox, secret: identity.mailboxSecret)
        guard (try? await task.send(.string(Self.encode(hello)))) != nil,
              case let .string(text)? = try? await task.receive(),
              let answer = Self.decode(text), answer.op == "ready" else {
            log("! signaling: couldn't connect to \(url.host() ?? url.absoluteString)")
            task.cancel()
            return false
        }
        lock.withLock { isConnected = true }
        log("signaling: connected to \(url.host() ?? url.absoluteString)")
        return true
    }

    /// Messages until the connection drops.
    func receive() async {
        guard let task = lock.withLock({ self.task }) else { return }
        while case let .string(text)? = try? await task.receive() {
            guard let message = Self.decode(text) else { continue }
            switch message.op {
            case "envelope":
                if let to = message.to, let sealed = message.sealed { received(Envelope(to: to, sealed: sealed)) }
            case "sent", "undelivered":
                let w = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
                w?.resume(returning: message.op == "sent")
            default:
                if let why = message.why { log("! signaling: \(why)") }
            }
        }
        let waiting = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            isConnected = false
            defer { self.waiting = [] }
            return self.waiting
        }
        for w in waiting { w.resume(returning: false) }
    }

    static func decode(_ text: String) -> SignalServer.Message? { try? JSONDecoder().decode(SignalServer.Message.self, from: Data(text.utf8)) }
    static func encode(_ m: SignalServer.Message) -> String { String(decoding: (try? JSONEncoder().encode(m)) ?? Data(), as: UTF8.self) }
}
