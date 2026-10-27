// `pond remote pair|devices|unpair ID|join CODE|connect DEVICE`: remote access's pairing, asked of the service (it keeps this Mac
// reachable, so it has to be running, with remote access on). `pair` shows a code and its QR code, for a device or
// another Pond to pair with this one; `join` pairs this one with another, by the code it showed. `watch`, `cameras`,
// `events`, `search`, `picture` and `clip` ask a paired Pond, over a session made for each (its remote API).
#if canImport(NVRMac)
import Devices
import Foundation
import HAPCamera
import NVRCore
import NVRMac
import Remote

/// Remote access in the service, if it's on (and set up right).
func startRemote(_ settings: Config.Remote?, log: @escaping @Sendable (String) -> Void) -> RemoteHost? {
    guard let settings, settings.enabled else { return nil }
    guard let address = settings.signaling, let url = URL(string: address), ["ws", "wss"].contains(url.scheme) else {
        log("! remote access is off: no signaling service set (remote.signaling, a wss:// address)")
        return nil
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
    let keys = RemoteKeys(store: KeychainCredentialStore(service: Brand.remoteKeychainService))
    paths.name = (Host.current().localizedName ?? "Pond").filter { $0.isLetter || $0.isNumber }
    if let relay = settings.relay, !settings.mesh {
        let addresses = PathSessions.resolve(relay, port: 3480)
        if let secret = keys.relaySecret(), !addresses.isEmpty {
            paths.relay = (addresses, secret)
        } else {
            log(addresses.isEmpty ? "! remote: the relay \(relay) couldn't be looked up"
                                  : "! remote: no secret for the relay (pond remote relay-secret): it isn't used")
        }
    }
    do {
        let host = try RemoteHost(keys: keys, name: Host.current().localizedName ?? "Pond", signaling: url, paths: paths, log: log)
        host.start()
        log("remote: reachable through \(url.host() ?? address), \(host.devices().count) paired")
        return host
    } catch {
        log("! remote access is off: this Mac's keys can't be kept (\(error))")
        return nil
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
            do throws(RemoteClient.Failure) {
                reply = try await host.asking(device) { client throws(RemoteClient.Failure) in try await ask(request, of: client) }
            } catch {
                reply.error = .failed(error.description)
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
            let size: Int
            if request.action == "remote.picture" {
                let picture = try await client.picture(event)
                do { try picture.write(to: url) } catch { throw .refused("\(file) can't be written") }
                size = picture.count
            } else {
                size = try await client.clip(event, to: url)
            }
            reply.connection = "kept in \(file) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
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
        let reply = SearchCommand.blocking { await client.ask(asked, timeout: asked.action == "remote.watch" ? 45 + (asked.seconds ?? 0) : 120) }
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
                print("\(time.string(from: e.start))  \(e.camera)  \(e.seen.isEmpty ? e.category : e.seen)"
                      + (e.sentence.map { ": \($0)" } ?? "") + (has.isEmpty ? "" : "  (\(has.joined(separator: ", ")))") + "  \(e.id)")
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
        print("✓ Kept in the Keychain. Restart the service to use it: pond service restart")
        return 0
    }
}
#endif
