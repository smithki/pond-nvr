// `pond remote pair|devices|unpair ID|join CODE`: remote access's pairing, asked of the service (it keeps this Mac
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
    do {
        let host = try RemoteHost(keys: RemoteKeys(store: KeychainCredentialStore(service: Brand.remoteKeychainService)),
                                  name: Host.current().localizedName ?? "Pond", signaling: url, log: log)
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
        default:
            reply.error = .notSupported
        }
        return reply
    }

    /// The command line's side.
    static func run(_ args: [String], configPath: String) -> Int32 {
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
        default:
            return SearchCommand.fail("pond remote pair | devices | unpair ID | join CODE")
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
        default:
            print("✓ Paired with \(reply.paired?.name ?? "it").")
        }
        return 0
    }
}
#endif
