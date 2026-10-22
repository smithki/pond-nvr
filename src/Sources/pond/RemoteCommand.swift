// `pond remote pair|devices|unpair ID|join CODE|connect DEVICE`: remote access's pairing, asked of the service (it keeps this Mac
// reachable, so it has to be running, with remote access on). `pair` shows a code and its QR code, for a device or
// another Pond to pair with this one; `join` pairs this one with another, by the code it showed.
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
        default:
            reply.error = .notSupported
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
        default:
            return SearchCommand.fail("pond remote pair | devices | unpair ID | join CODE | connect DEVICE | relay-secret [--remove]")
        }
        let client = ControlClient(path: ControlSocket.path(nextTo: configPath))
        let asked = request
        let reply = SearchCommand.blocking { await client.ask(asked, timeout: 45) }
        if let error = reply.error {
            return SearchCommand.fail(error == .unreachable
                ? "Remote access is kept by Pond's service, which isn't running (pond service start)."
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
        case "remote.connect":
            print("✓ \(reply.connection ?? "connected")")
        default:
            print("✓ Paired with \(reply.paired?.name ?? "it").")
        }
        return 0
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
