// Reolink's HTTP API (api.cgi): log in for a token, send JSON commands, log out. Cameras answer on HTTPS
// with a certificate of their own making, so that is trusted for the camera's address only; older firmware
// answers on plain HTTP, tried second. Used for what the camera is (GetDevInfo) and, on doorbells, for
// presses of the button (GetEvents).
import Foundation
import NVRCore

public final class ReolinkAPI: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// Nothing answered on HTTPS or HTTP.
        case unreachable
        /// It answered, but turned the login down.
        case loginRefused
        /// The camera does not know the command (its firmware is too old, or the model lacks it).
        case notSupported
        /// The token ran out; log in again.
        case loggedOut
        /// It allows only a few logins at once, and has them all ("max session"); they lapse after a while.
        case tooManyLogins
        /// It answered with something else; kept for the log, not for people.
        case unexpected(String)
    }

    let host: String
    let username: String
    let password: String
    let timeout: Double
    /// Where it answered and the login's token, while logged in; one login at a time, shared by whoever
    /// asks during it (a camera allows only a few).
    private let lock = NSLock()
    private var login: (base: String, token: String)?
    private var loggingIn: Task<Result<(base: String, token: String), Failure>, Never>?
    /// Its connections to the camera: made anew when one fails to connect (a session made while macOS was
    /// still deciding whether the process may use the local network kept failing, "local network
    /// prohibited", long after it had been allowed).
    private var connections: URLSession

    public init(host: String, username: String, password: String, timeout: Double = 4) {
        self.host = host
        self.username = username
        self.password = password
        self.timeout = timeout
        connections = Self.makeSession(host: host, timeout: timeout)
    }

    deinit { connections.invalidateAndCancel() }

    private static func makeSession(host: String, timeout: Double) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration, delegate: CameraCertificate(host: host), delegateQueue: nil)
    }

    private var session: URLSession { lock.withLock { connections } }

    /// Starts over with new connections, if `failed` is still the current ones.
    private func reconnect(after failed: URLSession) {
        let old: URLSession? = lock.withLock {
            guard connections === failed else { return nil }
            defer { connections = Self.makeSession(host: host, timeout: timeout) }
            return connections
        }
        old?.finishTasksAndInvalidate()
    }

    /// Logs in (once, however many ask at the same time).
    public func login() async throws(Failure) {
        let task = lock.withLock {
            if let pending = loggingIn { return pending }
            let task = Task { await self.loginNow() }
            loggingIn = task
            return task
        }
        let result = await task.value
        lock.withLock {
            if loggingIn == task { loggingIn = nil }
            if case let .success(login) = result { self.login = login }
        }
        if case let .failure(error) = result { throw error }
    }

    var isLoggedIn: Bool { lock.withLock { login != nil } }

    /// Logs in over HTTPS, else HTTP.
    private func loginNow() async -> Result<(base: String, token: String), Failure> {
        var lastFailure = Failure.unreachable
        for scheme in ["https", "http"] {
            let base = "\(scheme)://\(host)/api.cgi"
            let body: [[String: Any]] = [["cmd": "Login", "param": ["User": ["Version": "0", "userName": username, "password": password]]]]
            do throws(Failure) {
                let value = try await send(base: base, cmd: "Login", token: nil, body: body)
                guard let token = (value["Token"] as? [String: Any])?["name"] as? String else {
                    throw .unexpected("no token in the login reply")
                }
                return .success((base, token))
            } catch .unreachable {
                continue
            } catch {
                lastFailure = error
                if error == .loginRefused || error == .tooManyLogins { break }
            }
        }
        return .failure(lastFailure)
    }

    /// One command's `value`, after logging in.
    public func command(_ cmd: String, param: [String: Any] = [:]) async throws(Failure) -> [String: Any] {
        if !isLoggedIn { try await login() }
        guard let (base, token) = lock.withLock({ login }) else { throw .unreachable }
        do throws(Failure) {
            return try await send(base: base, cmd: cmd, token: token, body: [["cmd": cmd, "action": 0, "param": param]])
        } catch .loggedOut {
            // That login is over; the next command logs in again.
            lock.withLock { if self.login?.token == token { self.login = nil } }
            throw .loggedOut
        }
    }

    /// One command's whole reply as the camera wrote it, for investigating (`pond camera reolink`).
    public func raw(_ cmd: String, param: [String: Any]) async -> String {
        for attempt in 0 ..< 3 where !isLoggedIn {
            // A process's first connections fail while macOS decides whether it may use the local network.
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            do throws(Failure) { try await login() } catch {
                if error == .loginRefused { return "login refused: " + (await rawLogin() ?? "no answer") }
            }
        }
        guard let (base, token) = lock.withLock({ login }), let url = URL(string: "\(base)?cmd=\(cmd)&token=\(token)"),
              let body = try? JSONSerialization.data(withJSONObject: [["cmd": cmd, "action": 0, "param": param]]) else {
            return "not logged in: " + (await rawLogin() ?? "no answer")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, _) = try? await session.data(for: request) else { return "no answer" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The login's reply as written, to see why it was refused.
    private func rawLogin() async -> String? {
        for scheme in ["https", "http"] {
            guard let url = URL(string: "\(scheme)://\(host)/api.cgi?cmd=Login"),
                  let body = try? JSONSerialization.data(withJSONObject: [["cmd": "Login", "param": ["User": ["Version": "0", "userName": username, "password": password]]]])
            else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            if let (data, _) = try? await session.data(for: request) { return String(decoding: data, as: UTF8.self) }
        }
        return nil
    }

    public func logout() async {
        guard let (base, token) = lock.withLock({ () -> (String, String)? in
            defer { login = nil }
            return login
        }) else { return }
        _ = try? await send(base: base, cmd: "Logout", token: token, body: [["cmd": "Logout", "param": [:]]])
    }

    private func send(base: String, cmd: String, token: String?, body: [[String: Any]]) async throws(Failure) -> [String: Any] {
        var url = "\(base)?cmd=\(cmd)"
        if let token { url += "&token=\(token)" }
        guard let u = URL(string: url), let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw .unexpected("bad request")
        }
        var request = URLRequest(url: u)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let reply: Data
        let session = session
        do {
            (reply, _) = try await session.data(for: request)
        } catch {
            reconnect(after: session)
            throw .unreachable
        }
        guard let list = try? JSONSerialization.jsonObject(with: reply) as? [[String: Any]], let first = list.first else {
            throw .unexpected("not a Reolink reply")
        }
        if (first["code"] as? Int) == 0, let value = first["value"] as? [String: Any] { return value }
        let code = (first["error"] as? [String: Any])?["rspCode"] as? Int
        // -9 "not support", -4 "param error" (an unknown command, on some firmware).
        if code == -9 || code == -4 { throw .notSupported }
        // -5 "max session": every login it allows is in use.
        if code == -5 { throw .tooManyLogins }
        if cmd == "Login", code != nil { throw .loginRefused }
        // -6: the token ran out ("please login first").
        if code == -6 { throw .loggedOut }
        throw .unexpected("rspCode \(code.map(String.init) ?? "none")")
    }
}

/// Trusts the certificate the camera made for itself, and only for the camera's own address.
final class CameraCertificate: NSObject, URLSessionDelegate {
    let host: String
    init(host: String) { self.host = host }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Reolink cameras and doorbells: identified by GetDevInfo; motion and a doorbell's button by polling
/// GetEvents.
public struct ReolinkProvider: CameraProvider {
    public let id = "reolink"
    public let name = "Reolink"
    public let maker: String? = "Reolink"
    public let appName: String? = "the Reolink app"
    /// The Reolink app's name for the sub-stream ("Clear" is the main stream's).
    public let subStreamName: String? = "Fluent"
    public init() {}

    public func identify(host: String, username: String, password: String) async -> Config.Device? {
        let api = ReolinkAPI(host: host, username: username, password: password)
        let value = try? await api.command("GetDevInfo")
        await api.logout()
        guard let info = value?["DevInfo"] as? [String: Any] else { return nil }
        return Self.device(fromDevInfo: info)
    }

    /// From GetDevInfo's `DevInfo`.
    static func device(fromDevInfo info: [String: Any]) -> Config.Device? {
        func text(_ key: String) -> String? {
            (info[key] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let model = text("model") else { return nil }
        let kind = [text("exactType"), text("type"), model].compactMap { $0 }
        return Config.Device(manufacturer: "Reolink", model: model, serial: text("serial"), firmware: text("firmVer"),
                             isDoorbell: kind.contains { $0.localizedCaseInsensitiveContains("doorbell") },
                             provider: "reolink")
    }

    public func events(host: String, username: String, password: String) -> CameraEvents? {
        ReolinkPushedEvents(access: CameraAccess(host: host, username: username, password: password))
    }

    public func streams(host: String) -> (main: String, sub: String)? {
        ("rtsp://\(host):554/h264Preview_01_main", "rtsp://\(host):554/h264Preview_01_sub")
    }
}

/// Polls GetEvents once a second: motion while its motion alarm (or an AI detection: a person, vehicle or
/// animal) is on; a visitor alarm going from off to on is a doorbell press.
/// What the camera notices, pushed over its Baichuan connection as it happens (nothing asked each second); if
/// it doesn't answer there, asked of its HTTP API instead (ReolinkEvents).
final class ReolinkPushedEvents: CameraEvents, @unchecked Sendable {
    let access: CameraAccess
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var observer: (session: BaichuanSession, id: UUID)?
    private var polled: ReolinkEvents?

    init(access: CameraAccess) { self.access = access }

    func start(motion: @escaping @Sendable (Bool) -> Void, pressed: @escaping @Sendable () -> Void,
               state: @escaping @Sendable (DoorbellButtonState) -> Void) {
        let access = self.access
        let t = Task { [weak self] in
            let session = await CameraSessions.shared.baichuan(access)
            guard !Task.isCancelled else { return }
            if await session.settled(within: 15) == .connected {
                let id = session.observe(BaichuanSession.Observer(motion: motion, pressed: pressed, state: { now in
                    switch now {
                    case .connected: state(.watching)
                    case .refused: state(.loginRefused)
                    case .unreachable, .connecting: state(.unreachable)
                    }
                }))
                self?.lock.withLock { self?.observer = (session, id) }
            } else {
                // No Baichuan: asked of the HTTP API, each second.
                let events = ReolinkEvents(access: access)
                self?.lock.withLock { self?.polled = events }
                events.start(motion: motion, pressed: pressed, state: state)
            }
        }
        lock.withLock { task = t }
    }

    func stop() {
        let (task, observer, polled) = lock.withLock { () -> (Task<Void, Never>?, (session: BaichuanSession, id: UUID)?, ReolinkEvents?) in
            defer { self.task = nil; self.observer = nil; self.polled = nil }
            return (self.task, self.observer, self.polled)
        }
        task?.cancel()
        if let observer { observer.session.forget(observer.id) }
        polled?.stop()
    }
}

final class ReolinkEvents: CameraEvents, @unchecked Sendable {
    /// The camera's login is the one its controls use too (CameraSessions): it allows only a few.
    let access: CameraAccess
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(access: CameraAccess) { self.access = access }

    /// Motion in a GetEvents answer: its motion alarm, or any AI detection on.
    static func motion(in value: [String: Any]) -> Bool {
        if ((value["md"] as? [String: Any])?["alarm_state"] as? Int) == 1 { return true }
        guard let ai = value["ai"] as? [String: Any] else { return false }
        return ai.values.contains { (($0 as? [String: Any])?["alarm_state"] as? Int) == 1 }
    }

    func start(motion: @escaping @Sendable (Bool) -> Void, pressed: @escaping @Sendable () -> Void,
               state: @escaping @Sendable (DoorbellButtonState) -> Void) {
        let access = self.access
        let t = Task.detached {
            let api = await CameraSessions.shared.reolink(access)
            var moving = false
            var ringing = false
            var reported: DoorbellButtonState?
            func report(_ s: DoorbellButtonState) {
                if s != reported { reported = s; state(s) }
            }
            // Older models answer GetMdState (motion only) rather than GetEvents.
            var motionOnly = false
            // A process's first connections fail while macOS decides whether it may use the local network:
            // a first failure is tried again shortly before it is reported.
            var failedOnce = false
            while !Task.isCancelled {
                do throws(ReolinkAPI.Failure) {
                    if motionOnly {
                        let value = try await api.command("GetMdState", param: ["channel": 0])
                        let movingNow = (value["state"] as? Int) == 1
                        if movingNow != moving { motion(movingNow) }
                        moving = movingNow
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    let value = try await api.command("GetEvents", param: ["channel": 0])
                    failedOnce = false
                    report(.watching)
                    let movingNow = Self.motion(in: value)
                    if movingNow != moving { motion(movingNow) }
                    moving = movingNow
                    let visitor = (value["visitor"] as? [String: Any])?["alarm_state"] as? Int
                    let now = visitor == 1
                    if now, !ringing { pressed() }
                    ringing = now
                    try? await Task.sleep(for: .seconds(1))
                } catch .notSupported {
                    // A doorbell's button can't be seen without GetEvents; motion still can, the older way.
                    report(.notSupported)
                    if motionOnly { return }
                    motionOnly = true
                } catch .loginRefused {
                    report(.loginRefused)
                    try? await Task.sleep(for: .seconds(60))
                } catch .tooManyLogins {
                    // Its logins lapse after a while.
                    report(.unreachable)
                    try? await Task.sleep(for: .seconds(60))
                } catch .loggedOut {
                    try? await api.login()
                } catch {
                    if !failedOnce {
                        failedOnce = true
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }
                    report(.unreachable)
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
        lock.withLock { task = t }
    }

    func stop() { lock.withLock { task?.cancel() } }
}
