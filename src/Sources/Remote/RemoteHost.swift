// Remote access in the service: this Mac's identity, its connection to the signaling service, pairing (codes made,
// devices kept), and pairing with another Pond by its code. What arrives in its mailbox is opened here: requests to
// pair from anyone with a good code, everything else only from those paired (paths to connect over: PathSessions).
import Foundation
import NVRCore

public final class RemoteHost: @unchecked Sendable {
    public let keys: RemoteKeys
    public let identity: RemoteIdentity
    let signaling: URL
    let pairing: PairingHost
    let replay = ReplayGuard()
    let log: @Sendable (String) -> Void
    /// Connections with paired peers: paths found, offered and answered through the signaling service.
    public private(set) var paths: PathSessions!
    private var client: SignalClient?
    /// Joins under way: the code each was made with (by the Pond's signing key), and who's waiting for its answer.
    private var joining: [Data: (code: PairingCode, answer: CheckedContinuation<RemotePeer?, Never>)] = [:]
    private let lock = NSLock()

    /// Over a credential store (the Keychain's, service `pond-remote`), named as this Mac is, using a signaling
    /// service (its WebSocket address).
    public init(keys: RemoteKeys, name: String, signaling: URL, paths settings: PathSessions.Settings = .init(),
                log: @escaping @Sendable (String) -> Void) throws {
        self.keys = keys
        identity = try keys.identity(name: name)
        self.signaling = signaling
        pairing = PairingHost(keys: keys, identity: identity)
        self.log = log
        paths = PathSessions(settings: settings, send: { [weak self] kind, body, peer in
            guard let self, let envelope = try? Envelope.seal(kind: kind, body: body, from: identity, to: peer),
                  let client = lock.withLock({ self.client }) else { return false }
            return await client.send(envelope)
        }, log: log)
    }

    /// A path to a paired device or Pond (by its id or its name) found, and how it went.
    public func connect(to device: String) async -> PathSessions.Outcome? {
        guard let peer = devices().first(where: { $0.id == device || $0.name == device }) else { return nil }
        return await paths.connect(to: peer)
    }

    public func start() {
        let client = SignalClient(url: signaling, identity: identity, received: { [weak self] in self?.received($0) }, log: log)
        lock.withLock { self.client = client }
        client.start()
    }

    public func stop() { lock.withLock { client }?.stop() }

    /// A new pairing code: for a device (or another Pond) to pair with this one, for ten minutes, once.
    public func newCode() -> PairingCode { pairing.newCode(signaling: signaling.absoluteString) }

    public func devices() -> [RemotePeer] { keys.peers() }

    public func unpair(_ id: String) throws { try keys.remove(id) }

    /// Paired with another Pond, by the code it showed: its answer awaited (half a minute at most; a refusal isn't
    /// answered, so that's how one looks).
    public func join(_ code: PairingCode, waiting: Duration = .seconds(30)) async -> RemotePeer? {
        guard code.expires > Date(), let request = try? PairingGuest.request(code, from: identity) else { return nil }
        // Through its signaling service (this one's, if they share it; else connected to it for this).
        let shared = code.signaling == signaling.absoluteString
        let other = shared ? nil : URL(string: code.signaling).map {
            SignalClient(url: $0, identity: identity, received: { [weak self] in self?.received($0) }, log: log)
        }
        other?.start()
        defer { other?.stop() }
        guard let sender = other ?? lock.withLock({ client }) else { return nil }
        for _ in 0 ..< 100 where !sender.isConnected { try? await Task.sleep(for: .milliseconds(100)) }
        let pond = code.pond.signingKey
        let answer: RemotePeer? = await withCheckedContinuation { continuation in
            lock.withLock { joining[pond] = (code, continuation) }
            Task {
                guard await sender.send(request) else { return finish(pond, nil) }
                try? await Task.sleep(for: waiting)
                finish(pond, nil)
            }
        }
        if let answer {
            try? keys.add(answer)
            log("remote: paired with \(answer.name)")
        }
        return answer
    }

    func finish(_ pond: Data, _ peer: RemotePeer?) {
        let waiting = lock.withLock { joining.removeValue(forKey: pond) }
        waiting?.answer.resume(returning: peer)
    }

    /// An envelope from the signaling service.
    func received(_ envelope: Envelope) {
        let opened: (kind: String, body: Data, sender: Data)
        do {
            opened = try envelope.open(as: identity, replay: replay, strangers: [PairingMessage.request, PairingMessage.accepted],
                                       known: keys.peers())
        } catch {
            log("! remote: an envelope refused (\(error))")
            return
        }
        switch opened.kind {
        case PairingMessage.request:
            do {
                let (device, answer) = try pairing.handle(opened.body)
                log("remote: paired with \(device.name)")
                Task { _ = await lock.withLock({ client })?.send(answer) }
            } catch {
                log("! remote: a request to pair refused (\(error))")
            }
        case PairingMessage.accepted:
            // An answer to a join under way: from the Pond its code named.
            guard let code = lock.withLock({ joining[opened.sender]?.code }),
                  let pond = PairingGuest.accepted(kind: opened.kind, body: opened.body, sender: opened.sender, code: code) else { return }
            finish(code.pond.signingKey, pond)
        case let kind where kind.hasPrefix("path."):
            guard let peer = keys.peer(signingKey: opened.sender) else { return }
            paths.handle(kind: kind, body: opened.body, from: peer)
        default:
            break
        }
    }
}
