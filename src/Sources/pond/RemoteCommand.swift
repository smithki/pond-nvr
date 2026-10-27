// `pond remote pair|devices|unpair ID|join CODE|connect DEVICE`: remote access's pairing, asked of the service (it keeps this Mac
// reachable, so it has to be running, with remote access on). `pair` shows a code and its QR code, for a device or
// another Pond to pair with this one; `join` pairs this one with another, by the code it showed. `watch`, `cameras`,
// `events`, `search`, `picture` and `clip` ask a paired Pond, over a session made for each (its remote API).
#if canImport(NVRMac)
import Demo
import Devices
import Foundation
import HAPCamera
import Ingest
import NVRCore
import NVRMac
import Remote

/// Remote access in the service, as its settings say: started, changed and stopped as they change (the service's
/// reload), recording untouched. Its sessions are answered by the remote API.
final class RemoteAccess: @unchecked Sendable {
    let api: RemoteAPI.Server
    let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var host: RemoteHost?
    /// Other Ponds' cameras shown in this Mac's app (sessions kept open to them while they are).
    private var viewing: RemoteViewing?
    /// What it was started with (the settings, and the relay's secret: a new one starts it again too); why it
    /// isn't on, if the settings can fix that.
    private var applied: (settings: Config.Remote?, secret: String?, name: String?)?
    private var problem: String?

    /// The service's (for what's made before it: the app's stream relay).
    nonisolated(unsafe) static weak var running: RemoteAccess?

    init(api: RemoteAPI.Server, log: @escaping @Sendable (String) -> Void) {
        self.api = api
        self.log = log
        Self.running = self
        registerStreams()
    }

    var current: RemoteHost? { lock.withLock { host } }

    /// The settings taken up: started again if they (or the relay's secret) changed. What changed, in words.
    @discardableResult
    func apply(_ settings: Config.Remote?, name: String? = nil) -> String? {
        let secret = Self.keys.relaySecret()
        let changed = lock.withLock { () -> Bool in
            guard let applied, applied.settings == settings, applied.secret == secret, applied.name == name else { return true }
            return false
        }
        guard changed else { return nil }
        let (old, wasOn) = lock.withLock { (host, applied != nil) }
        old?.stop()
        let (started, problem) = startRemote(settings, pondName: name, log: log)
        if let started {
            started.paths.requests = { [api] in await api.serve($0, action: $1, body: $2) }
            started.paths.sessionEnded = { [api] in api.ended($0) }
        }
        lock.withLock {
            host = started
            viewing = started.map { RemoteViewing(host: $0) }
            applied = (settings, secret, name)
            self.problem = problem
        }
        guard wasOn else { return nil }
        return started == nil ? "remote access off" : "remote access started again"
    }

    func stop() { lock.withLock { host }?.stop() }

    /// For the app's live view: other Ponds' cameras' streams, opened through StreamHub (`pond-remote://`).
    func registerStreams() {
        StreamHub.openers[RemoteViewing.scheme] = { [weak self] url in
            guard let viewing = self?.lock.withLock({ self?.viewing }) else { throw RTSPError.notFound(url) }
            return try viewing.open(url)
        }
    }

    /// Whether a stream's address is a paired Pond's camera's (the app's live view may read it).
    func isKnownStream(_ url: String) -> Bool { lock.withLock { viewing }?.isKnown(url) ?? false }

    /// Another Pond's camera's request (its id `camera@pond`), asked of it with the camera's own id.
    func forward(_ request: ControlSocket.Request) async -> ControlSocket.Reply {
        guard let viewing = lock.withLock({ viewing }), let (camera, pond) = ControlSocket.RemotePond.split(request.camera) else {
            return ControlSocket.Reply(error: .failed("remote access is off"))
        }
        if request.action == "remote.still" {
            // Its latest picture, for the app's rail.
            guard let still = await viewing.still(pond: pond, camera: camera) else { return ControlSocket.Reply(error: .notSupported) }
            var reply = ControlSocket.Reply()
            reply.body = still.jpeg
            reply.taken = still.time
            return reply
        }
        var asked = request
        asked.camera = camera
        return await viewing.control(pond: pond, asked)
    }

    static var keys: RemoteKeys { RemoteKeys(store: KeychainCredentialStore(service: Brand.remoteKeychainService)) }

    /// A "remote." request from the app or `pond`.
    func handle(_ request: ControlSocket.Request) async -> ControlSocket.Reply {
        switch request.action {
        case "remote.status":
            var reply = ControlSocket.Reply()
            let (host, problem) = lock.withLock { (self.host, self.problem) }
            let relaySecret = Self.keys.relaySecret() != nil
            guard let host else {
                reply.remote = .init(on: false, relaySecret: relaySecret, problem: problem)
                return reply
            }
            reply.remote = .init(on: true, reachable: host.isReachable, signaling: host.signalingHost,
                                 devices: host.devices().map { .init(id: $0.id, name: $0.name) },
                                 connected: host.paths.connected.map { .init(device: $0.peer, how: $0.how) },
                                 relaySecret: relaySecret, problem: problem)
            return reply
        case "remote.all-events":
            // Every other Pond's events, begun in the last `seconds` (for the app; `remote.events` is one Pond's, for `pond`).
            guard let viewing = lock.withLock({ viewing }) else { return ControlSocket.Reply(error: .failed("remote access is off")) }
            var reply = ControlSocket.Reply()
            reply.remoteEvents = await viewing.allEvents(seconds: request.seconds ?? 86400)
            return reply
        case "remote.event-file":
            // An event's picture or clip (`file`: "picture" or "clip"), fetched or on its way.
            guard let viewing = lock.withLock({ viewing }), let event = request.event else {
                return ControlSocket.Reply(error: .failed("which event?"))
            }
            var reply = ControlSocket.Reply()
            reply.remoteFile = viewing.file(event, clip: request.file == "clip")
            return reply
        case "remote.still":
            // Another Pond's camera's latest picture (its id `camera@pond`).
            return await forward(request)
        case "remote.ponds":
            // Each paired Pond's cameras, with their streams' addresses through this service.
            guard let viewing = lock.withLock({ viewing }) else { return ControlSocket.Reply(error: .failed("remote access is off")) }
            var reply = ControlSocket.Reply()
            reply.ponds = await viewing.allCameras().map { pond, cameras, problem in
                ControlSocket.RemotePond(id: pond.id, name: pond.name, cameras: cameras?.map { c in
                    .init(id: ControlSocket.RemotePond.cameraID(c.id, pond: pond.id), name: c.name, doorbell: c.doorbell,
                          isPrivate: c.isPrivate, waking: c.waking, model: c.model,
                          main: RemoteViewing.url(pond: pond.id, camera: c.id, main: true),
                          sub: RemoteViewing.url(pond: pond.id, camera: c.id, main: c.subStream ? false : true), controls: c.controls)
                }, problem: problem)
            }
            return reply
        case "remote.relay-secret":
            // Kept (or removed), then remote access started again with it.
            let secret = request.code?.trimmingCharacters(in: .whitespaces) ?? ""
            do { try Self.keys.setRelaySecret(secret.isEmpty ? nil : secret) } catch {
                return ControlSocket.Reply(error: .failed("it couldn\u{2019}t be kept (\(error))"))
            }
            let (settings, name) = lock.withLock { (applied?.settings, applied?.name) }
            apply(settings, name: name)
            return ControlSocket.Reply()
        case "remote.rename":
            // A paired Pond or device called something else here.
            guard let id = request.device, let name = request.code?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                return ControlSocket.Reply(error: .failed("which device, and what name?"))
            }
            do { try Self.keys.rename(id, to: name) } catch {
                return ControlSocket.Reply(error: .failed("it couldn\u{2019}t be kept (\(error))"))
            }
            return ControlSocket.Reply()
        default:
            guard let host = current else {
                return ControlSocket.Reply(error: .failed("remote access is off (remote.enabled and remote.signaling in the settings)"))
            }
            return await RemoteCommand.handle(request, host: host)
        }
    }
}

/// Remote access in the service, if it's on (and set up right); else why not, if it should be.
func startRemote(_ settings: Config.Remote?, pondName: String? = nil, log: @escaping @Sendable (String) -> Void) -> (RemoteHost?, String?) {
    guard let settings, settings.enabled else { return (nil, nil) }
    guard let address = settings.signaling, let url = URL(string: address), ["ws", "wss"].contains(url.scheme) else {
        log("! remote access is off: no signaling service set (remote.signaling, a wss:// address)")
        return (nil, "No signaling server is set: a wss:// address.")
    }
    // How connections are made: where to learn this Mac's public address (the signaling host's STUN, unless one's
    // given), the port to answer from, whether its own addresses are offered, and the mesh.
    var paths = PathSessions.Settings()
    paths.port = settings.port
    paths.shareLocalAddresses = settings.shareLocalAddresses
    if settings.mesh {
        let subnets = settings.meshSubnets?.compactMap(Subnet.init) ?? []
        paths.mode = .mesh(subnets: subnets.isEmpty ? Gatherer.tailnet : subnets)
    } else {
        // ("host:port", or a host alone: port 3478.)
        let server = settings.stun ?? url.host() ?? ""
        paths.stun = PathSessions.resolve(server)
        if paths.stun.isEmpty { log("! remote: \(server) couldn't be looked up: only this Mac's own addresses will be offered") }
    }
    let keys = RemoteAccess.keys
    var problem: String?
    // (A demo's Pond is named as its scenario has it, and reached over the link it sets.)
    let name = pondName ?? DemoWorld.current?.scenario.pondName ?? Host.current().localizedName ?? "Pond"
    paths.name = name.filter { $0.isLetter || $0.isNumber }
    if DemoWorld.current?.scenario.link == .slow { paths.shape = .init(delay: 0.06, loss: 0.02, rate: 300_000) }
    if let relay = settings.relay, !settings.mesh {
        let addresses = PathSessions.resolve(relay, port: 3480)
        if let secret = keys.relaySecret(), !addresses.isEmpty {
            paths.relay = (addresses, secret)
        } else {
            log(addresses.isEmpty ? "! remote: the relay \(relay) couldn't be looked up"
                                  : "! remote: no secret for the relay (pond remote relay-secret): it isn't used")
            problem = addresses.isEmpty ? "The relay \(relay) couldn\u{2019}t be found." : "The relay has no secret, so it isn\u{2019}t used."
        }
    }
    do {
        let host = try RemoteHost(keys: keys, name: name, signaling: url, paths: paths, log: log)
        host.start()
        log("remote: reachable through \(url.host() ?? address), \(host.devices().count) paired")
        return (host, problem)
    } catch {
        log("! remote access is off: this Mac's keys can't be kept (\(error))")
        return (nil, "This Mac\u{2019}s keys can\u{2019}t be kept in the Keychain (\(error)).")
    }
}

enum RemoteCommand {
    /// The service's side: a "remote." request answered.
    static func handle(_ request: ControlSocket.Request, host: RemoteHost) async -> ControlSocket.Reply {
        var reply = ControlSocket.Reply()
        switch request.action {
        case "remote.pair":
            let code = host.newCode()
            reply.pairing = code.text
            reply.pairingExpires = code.expires
        case "remote.devices":
            reply.devices = host.devices().map { ControlSocket.RemoteDevice(id: $0.id, name: $0.name) }
        case "remote.unpair":
            guard let id = request.device, host.devices().contains(where: { $0.id == id }) else {
                reply.error = .failed("no device \(request.device ?? "")")
                break
            }
            do { try host.unpair(id) } catch { reply.error = .failed("it couldn't be removed (\(error))") }
        case "remote.join":
            guard let code = request.code.flatMap(PairingCode.init(text:)) else {
                reply.error = .failed("that isn't a pairing code")
                break
            }
            guard code.expires > Date() else {
                reply.error = .failed("that code has run out: ask for a new one")
                break
            }
            if let pond = await host.join(code) {
                reply.paired = ControlSocket.RemoteDevice(id: pond.id, name: pond.name)
            } else {
                reply.error = .failed("\(code.pond.name) didn't answer (is its service running, and the code unused?)")
            }
        case "remote.connect":
            guard let device = request.device, let outcome = await host.connect(to: device) else {
                reply.error = .failed("no device \(request.device ?? "") (pond remote devices)")
                break
            }
            if outcome.pair == nil { reply.error = .failed(outcome.summary) } else { reply.connection = outcome.summary }
        case "remote.watch":
            guard let device = request.device, let file = request.file else { reply.error = .failed("which device, and where to keep it?"); break }
            let size = request.size?.split(separator: "x").compactMap { Int($0) }
            let reencode = request.kbps.map { kbps in
                LiveRequest.Reencode(width: size?.first ?? 640, height: size?.last ?? 360, kbps: kbps, fps: 15)
            }
            let result = await host.watch(device: device, camera: request.camera, main: request.main ?? false, reencode: reencode,
                                          seconds: request.seconds ?? 10, file: URL(fileURLWithPath: file))
            if result.problem != nil || result.counts.pictures == 0 { reply.error = .failed(result.summary) } else { reply.connection = result.summary }
        case "remote.cameras", "remote.events", "remote.search", "remote.picture", "remote.clip":
            guard let device = request.device else { reply.error = .failed("which device?"); break }
            // A picture or clip cut off (the session lost, no answer) asked for again on a new one, twice at most:
            // it carries on from where it got to.
            var tries = request.action == "remote.picture" || request.action == "remote.clip" ? 3 : 1
            while tries > 0 {
                tries -= 1
                do throws(RemoteClient.Failure) {
                    reply = try await host.asking(device) { client throws(RemoteClient.Failure) in try await ask(request, of: client) }
                    break
                } catch .noAnswer where tries > 0 {
                    continue
                } catch {
                    reply.error = .failed(error.description)
                }
            }
        default:
            reply.error = .notSupported
        }
        return reply
    }

    /// A paired Pond asked, for the command line.
    static func ask(_ request: ControlSocket.Request, of client: RemoteClient) async throws(RemoteClient.Failure) -> ControlSocket.Reply {
        var reply = ControlSocket.Reply()
        switch request.action {
        case "remote.cameras":
            reply.body = try? JSONEncoder().encode(try await client.cameras())
        case "remote.events":
            let since = Date().addingTimeInterval(-(request.seconds ?? 86400))
            reply.body = try? JSONEncoder().encode(try await client.events(.init(since: since, camera: request.camera.isEmpty ? nil : request.camera)))
        case "remote.search":
            let (result, events) = try await client.search(request.question ?? "")
            reply.search = result
            reply.body = try? JSONEncoder().encode(events)
        default:
            guard let event = request.event, let file = request.file else { throw .refused("which event, and where to keep it?") }
            let url = URL(fileURLWithPath: file)
            let done = request.action == "remote.picture" ? try await client.picture(event, to: url) : try await client.clip(event, to: url)
            func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
            let fetched = done.bytes - done.resumed
            reply.connection = "kept in \(file): \(size(done.bytes)), checked" + String(format: ", in %.1f s", done.seconds)
                + (fetched > 0 && done.seconds > 0 ? " (\(size(Int(Double(fetched) / done.seconds)))/s)" : "")
                + (done.resumed > 0 ? ", carrying on after the first \(size(done.resumed))" : "")
        }
        return reply
    }

    /// The command line's side.
    static func run(_ args: [String], configPath: String) -> Int32 {
        // The relay's secret: kept in the Keychain here (the service reads it when it starts).
        if args.first == "relay-secret" { return relaySecret(Array(args.dropFirst())) }
        var request = ControlSocket.Request(camera: "", action: "")
        switch args.first {
        case "pair" where args.count == 1: request.action = "remote.pair"
        case "devices" where args.count == 1: request.action = "remote.devices"
        case "unpair" where args.count == 2:
            request.action = "remote.unpair"
            request.device = args[1]
        case "join" where args.count == 2:
            request.action = "remote.join"
            request.code = args[1]
        case "connect" where args.count == 2:
            request.action = "remote.connect"
            request.device = args[1]
        case "watch" where args.count >= 3:
            // pond remote watch DEVICE CAMERA [--main] [--seconds N] [--out PATH] [--kbps N [--size WxH]]
            var rest = Array(args.dropFirst(3))
            request.action = "remote.watch"
            request.device = args[1]
            request.camera = args[2]
            request.main = rest.contains("--main")
            rest.removeAll { $0 == "--main" }
            func value(_ name: String) -> String? {
                guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
                return rest[i + 1]
            }
            request.seconds = value("--seconds").flatMap(Double.init) ?? 10
            request.kbps = value("--kbps").flatMap(Int.init)
            request.size = value("--size")
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            request.file = value("--out").map { NSString(string: $0).expandingTildeInPath }
                ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("pond-watch-\(args[2])-\(stamp).mp4")
            if !request.file!.hasPrefix("/") { request.file = FileManager.default.currentDirectoryPath + "/" + request.file! }
        case "cameras" where args.count == 2:
            request.action = "remote.cameras"
            request.device = args[1]
        case "events" where args.count >= 2:
            // pond remote events DEVICE [--hours N] [--camera CAMERA]
            request.action = "remote.events"
            request.device = args[1]
            request.seconds = option(args, "--hours").flatMap(Double.init).map { $0 * 3600 } ?? 86400
            request.camera = option(args, "--camera") ?? ""
        case "search" where args.count >= 3:
            request.action = "remote.search"
            request.device = args[1]
            request.question = args.dropFirst(2).joined(separator: " ")
        case "picture" where args.count >= 3, "clip" where args.count >= 3:
            // pond remote picture|clip DEVICE EVENT [--out PATH]
            request.action = "remote." + args[0]
            request.device = args[1]
            request.event = args[2]
            let out = option(args, "--out").map { NSString(string: $0).expandingTildeInPath }
                ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("pond-\(args[2]).\(args[0] == "picture" ? "jpg" : "mp4")")
            request.file = out.hasPrefix("/") ? out : FileManager.default.currentDirectoryPath + "/" + out
        default:
            return SearchCommand.fail("pond remote pair | devices | unpair ID | join CODE | connect DEVICE | watch DEVICE CAMERA [--main] [--seconds N] [--out PATH] [--kbps N [--size WxH]] | cameras DEVICE | events DEVICE [--hours N] [--camera CAMERA] | search DEVICE QUESTION | picture|clip DEVICE EVENT [--out PATH] | relay-secret [--remove]")
        }
        let client = ControlClient(path: ControlSocket.path(nextTo: configPath))
        let asked = request
        // (A picture or clip takes as long as the other home's upload does: its own pieces time out when nothing comes.)
        let wait: Double = switch asked.action {
        case "remote.watch": 45 + (asked.seconds ?? 0)
        case "remote.picture", "remote.clip": 3600
        default: 120
        }
        let reply = SearchCommand.blocking { await client.ask(asked, timeout: wait) }
        if let error = reply.error {
            return SearchCommand.fail(error == .unreachable
                ? "Remote access is kept by Pond's service, which isn't running (pond service install)."
                : "\(error.description).")
        }
        switch request.action {
        case "remote.pair":
            guard let code = reply.pairing else { return SearchCommand.fail("No code came back.") }
            let until = reply.pairingExpires.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "ten minutes from now"
            print("Pair a device with this Mac: scan the QR code, or paste the code (good once, until \(until)):\n")
            print(code)
            if let qr = TerminalQR.render(code) { print("\n" + qr) }
        case "remote.devices":
            let devices = reply.devices ?? []
            if devices.isEmpty { print("No devices paired (pond remote pair).") }
            for d in devices { print("\(d.id)  \(d.name)") }
        case "remote.unpair":
            print("✓ Removed: it can't reach this Mac any more.")
        case "remote.connect", "remote.watch", "remote.picture", "remote.clip":
            print("✓ \(reply.connection ?? "connected")")
        case "remote.cameras":
            let cameras = reply.body.flatMap { try? JSONDecoder().decode([RemoteAPI.Camera].self, from: $0) } ?? []
            if cameras.isEmpty { print("It has no cameras.") }
            for c in cameras {
                let notes = [c.doorbell ? "doorbell" : nil, c.isPrivate ? "private" : nil, c.waking ? "waking" : nil, c.model].compactMap { $0 }
                print("\(c.id)  \(c.name)" + (notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"))
            }
        case "remote.events", "remote.search":
            let events = reply.body.flatMap { try? JSONDecoder().decode([RemoteAPI.Event].self, from: $0) } ?? []
            if events.isEmpty { print(request.action == "remote.search" ? "Nothing found." : "No events.") }
            let time = DateFormatter()
            time.dateFormat = "MMM d HH:mm"
            for e in events {
                let has = [e.picture ? "picture" : nil,
                           e.clipBytes.map { "clip " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }].compactMap { $0 }
                let what = e.seen.isEmpty ? e.category : e.seen
                let sentence = e.sentence.map { ": \($0)" } ?? ""
                let extras = has.isEmpty ? "" : "  (\(has.joined(separator: ", ")))"
                print("\(time.string(from: e.start))  \(e.camera)  \(what)\(sentence)\(extras)  \(e.id)")
            }
        default:
            print("✓ Paired with \(reply.paired?.name ?? "it").")
        }
        return 0
    }

    /// The value after `name` in the arguments, if it's there.
    static func option(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `pond remote relay-secret [--remove]`: the relay's shared secret (coturn's static-auth-secret), read from
    /// standard input (never an argument, where other programs could see it), kept in the Keychain.
    static func relaySecret(_ args: [String]) -> Int32 {
        let keys = RemoteKeys(store: KeychainCredentialStore(service: Brand.remoteKeychainService))
        if args == ["--remove"] {
            do { try keys.setRelaySecret(nil) } catch { return SearchCommand.fail("It couldn't be removed: \(error)") }
            print("✓ The relay's secret removed.")
            return 0
        }
        guard args.isEmpty else { return SearchCommand.fail("pond remote relay-secret [--remove] (the secret on standard input)") }
        if isatty(STDIN_FILENO) != 0 { FileHandle.standardError.write(Data("The relay's secret (then Return): ".utf8)) }
        guard let secret = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces), !secret.isEmpty else {
            return SearchCommand.fail("No secret given.")
        }
        do { try keys.setRelaySecret(secret) } catch { return SearchCommand.fail("It couldn't be kept: \(error)") }
        print("✓ Kept in the Keychain. The service takes it up with: pond service reload")
        return 0
    }
}
#endif
