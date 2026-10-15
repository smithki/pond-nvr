// macOS asks once whether the app may reach devices on the local network. Until the person answers, a plain
// socket (the RTSP client's) fails at once as if the camera were off. The Network framework instead waits,
// saying why: so a check first connects through it and holds while the answer is pending.
import Foundation
import Network

enum LocalNetworkAccess {
    enum Outcome: Equatable {
        /// Connected, or failed for a reason of its own (which the check itself will report).
        case allowed
        /// Still not allowed after the wait: turned off in System Settings, or the question left unanswered.
        case denied
    }

    /// Connects to `host:port` and waits while macOS withholds local network access, calling `waiting` once
    /// if it does. Returns soon when access is not the problem (connected, refused, unreachable, or nothing
    /// within a few seconds); `.denied` only if access is still withheld after `timeout` seconds.
    static func wait(host: String, port: UInt16, timeout: Double = 120,
                     waiting: @escaping @MainActor @Sendable () -> Void) async -> Outcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .allowed }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "local network access")
        let state = WaitState()
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ outcome: Outcome) {
                guard state.finish() else { return }
                connection.cancel()
                continuation.resume(returning: outcome)
            }
            connection.stateUpdateHandler = { update in
                switch update {
                case .ready, .failed, .cancelled:
                    finish(.allowed)
                case .waiting:
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        if state.markDenied() { Task { @MainActor in waiting() } }
                    } else {
                        finish(.allowed)
                    }
                default:
                    break
                }
            }
            connection.pathUpdateHandler = { path in
                // Allowed while waiting: the connection goes on to .ready (or fails) by itself.
                if path.unsatisfiedReason != .localNetworkDenied { state.clearDenied() }
            }
            // A camera that is simply slow or off is the check's to report, not this.
            queue.asyncAfter(deadline: .now() + 3) { if !state.isDenied { finish(.allowed) } }
            queue.asyncAfter(deadline: .now() + timeout) { finish(state.isDenied ? .denied : .allowed) }
            connection.start(queue: queue)
        }
    }
}

/// Shared between the connection's handlers and the timers, all on one queue; locked anyway.
private final class WaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var denied = false
    private var announced = false

    /// True the first time only.
    func finish() -> Bool { lock.withLock { defer { finished = true }; return !finished } }
    var isDenied: Bool { lock.withLock { denied } }
    /// True the first time access is seen withheld, to announce the wait once.
    func markDenied() -> Bool {
        lock.withLock {
            denied = true
            defer { announced = true }
            return !announced
        }
    }
    func clearDenied() { lock.withLock { denied = false } }
}
