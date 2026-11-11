// One HomeKit accessory's server logic: each connection starts in plain HTTP for pair setup and pair verify,
// then switches to encrypted frames, after which it may read the database, read and write characteristics,
// subscribe to their changes, ask for snapshots and manage pairings. The network side (HAPListener) only
// moves bytes.
import CryptoKit
import Foundation

public final class AccessoryServer: @unchecked Sendable {
    public let identity: AccessoryIdentity
    public let store: PairingStore
    public let accessory: Accessory
    public let setupCode: String
    /// Snapshots for POST /resource: width and height asked for, JPEG back.
    public var snapshot: (@Sendable (_ width: Int, _ height: Int) async -> [UInt8]?)?
    /// Told when pairings change (paired, unpaired), so Bonjour's status flag can follow.
    public var pairingsChanged: (@Sendable () -> Void)?
    /// Pairing steps and failures, for following a setup.
    public var log: (@Sendable (String) -> Void)?
    /// Its name, in the pairing steps logged (several accessories share the log).
    public var name: String?
    /// Told about each connection's session (for HomeKit Data Stream, which reuses its secret).
    public var sessionVerified: (@Sendable (SessionKeys) -> Void)?
    let pairSetup: PairSetup
    private var connections: [ObjectIdentifier: HAPConnection] = [:]
    private let lock = NSLock()

    public init(identity: AccessoryIdentity, store: PairingStore, accessory: Accessory, setupCode: String) {
        self.identity = identity
        self.store = store
        self.accessory = accessory
        self.setupCode = setupCode
        pairSetup = PairSetup(identity: identity, store: store, setupCode: setupCode)
        for service in accessory.services {
            for c in service.characteristics {
                c.changed = { [weak self] c, value in self?.notify(c, value: value, except: nil) }
            }
        }
    }

    public var isPaired: Bool { !store.pairings().isEmpty }

    /// A new connection; `send` puts bytes on the wire.
    public func connect(send: @escaping @Sendable ([UInt8]) -> Void) -> HAPConnection {
        let c = HAPConnection(server: self, send: send)
        lock.withLock { connections[ObjectIdentifier(c)] = c }
        return c
    }

    func disconnected(_ c: HAPConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(c)) }
    }

    /// Sends a characteristic's new value to every connection subscribed to it.
    func notify(_ c: Characteristic, value: HAPValue? = nil, except sender: HAPConnection?) {
        let list = lock.withLock { Array(connections.values) }
        let body = Self.json(["characteristics": [["aid": accessory.aid, "iid": c.iid, "value": (value ?? c.value).json]]])
        for conn in list where conn !== sender && conn.isSubscribed(c.iid) {
            conn.sendEvent(body)
        }
    }

    static func json(_ object: Any) -> [UInt8] {
        Array((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }

    // MARK: - Routing

    func handle(_ request: HTTPRequest, on conn: HAPConnection) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("POST", "/pair-setup"):
            let req = (try? TLV8.decode(request.body)) ?? []
            let reply = pairSetup.handle(req)
            logStep("pair setup", req, reply, conn)
            return tlv(reply, after: { [weak self] in self?.pairingsChanged?() })
        case ("POST", "/pair-verify"):
            let req = (try? TLV8.decode(request.body)) ?? []
            let reply = conn.verifier.handle(req)
            logStep("pair verify", req, reply, conn)
            return tlv(reply)
        default:
            break
        }
        guard let keys = conn.keys else { return HTTPResponse(status: 470) }
        switch (request.method, request.path) {
        case ("GET", "/accessories"):
            // Read when a controller first meets it, or after its shape changed (its configuration number went up).
            log?("… HomeKit: its services read by controller \(keys.controller.identifier.prefix(8))…")
            return HTTPResponse(status: 200, contentType: "application/hap+json",
                                body: Self.json(["accessories": [accessory.json()]]))
        case ("GET", "/characteristics"):
            return read(request)
        case ("PUT", "/characteristics"):
            return write(request, on: conn)
        case ("PUT", "/prepare"):
            // A timed write announced: its id, good for `ttl` milliseconds.
            guard let body = try? JSONSerialization.jsonObject(with: Data(request.body)) as? [String: Any],
                  let ttl = (body["ttl"] as? NSNumber)?.doubleValue, let pid = (body["pid"] as? NSNumber)?.uint64Value else {
                return HTTPResponse(status: 400)
            }
            conn.prepare(pid, until: Date().addingTimeInterval(ttl / 1000))
            return HTTPResponse(status: 200, contentType: "application/hap+json", body: Self.json(["status": 0]))
        case ("POST", "/pairings"):
            let reply = Pairings.handle((try? TLV8.decode(request.body)) ?? [], from: keys.controller, store: store)
            // Removing this controller's own pairing ends its session.
            if !store.pairings().contains(where: { $0.identifier == keys.controller.identifier }) { conn.closeAfterReply = true }
            pairingsChanged?()
            return tlv(reply)
        case ("POST", "/resource"):
            guard let body = try? JSONSerialization.jsonObject(with: Data(request.body)) as? [String: Any],
                  body["resource-type"] as? String == "image" else { return HTTPResponse(status: 400) }
            let width = (body["image-width"] as? NSNumber)?.intValue ?? 640
            let height = (body["image-height"] as? NSNumber)?.intValue ?? 360
            guard let jpeg = await snapshot?(width, height) else { return HTTPResponse(status: 503) }
            return HTTPResponse(status: 200, contentType: "image/jpeg", body: jpeg)
        default:
            return HTTPResponse(status: 404)
        }
    }

    private func logStep(_ what: String, _ request: [TLV8Item], _ reply: [TLV8Item], _ conn: HAPConnection) {
        let step = request.value(PairingTLV.state)?.first ?? 0
        // Which accessory, and who's asking.
        let whose = (name.map { " (\($0))" } ?? "") + ":"
        let from = conn.peer.map { " from \($0)" } ?? ""
        if let e = reply.value(PairingTLV.error)?.first {
            log?("! HomeKit\(whose) \(what) M\(step) refused\(from): \(PairingError(rawValue: e).map { "\($0)" } ?? "error \(e)")")
        } else {
            log?("… HomeKit\(whose) \(what) M\(step) → M\(reply.value(PairingTLV.state)?.first ?? 0)\(from)")
        }
    }

    private func tlv(_ items: [TLV8Item], after: (() -> Void)? = nil) -> HTTPResponse {
        after?()
        return HTTPResponse(status: 200, contentType: "application/pairing+tlv8", body: TLV8.encode(items))
    }

    private func ids(_ text: String) -> [(aid: Int, iid: Int)] {
        text.split(separator: ",").compactMap { pair in
            let p = pair.split(separator: ".")
            guard p.count == 2, let a = Int(p[0]), let i = Int(p[1]) else { return nil }
            return (a, i)
        }
    }

    private func read(_ request: HTTPRequest) -> HTTPResponse {
        let wanted = ids(request.query["id"] ?? "")
        var results: [[String: Any]] = []
        var failed = false
        for (aid, iid) in wanted {
            guard aid == accessory.aid, let c = accessory.characteristic(iid: iid) else {
                results.append(["aid": aid, "iid": iid, "status": HAPStatus.resourceDoesNotExist.rawValue])
                failed = true
                continue
            }
            guard c.permissions.contains(.read) else {
                results.append(["aid": aid, "iid": iid, "status": HAPStatus.writeOnly.rawValue])
                failed = true
                continue
            }
            var entry: [String: Any] = ["aid": aid, "iid": iid, "value": c.value.json]
            if request.query["meta"] == "1" || request.query["type"] == "1" || request.query["perms"] == "1" {
                entry.merge(c.json(aid: aid, includeValue: false)) { a, _ in a }
            }
            results.append(entry)
        }
        if failed {
            for i in results.indices where results[i]["status"] == nil { results[i]["status"] = 0 }
        }
        return HTTPResponse(status: failed ? 207 : 200, contentType: "application/hap+json",
                            body: Self.json(["characteristics": results]))
    }

    private func write(_ request: HTTPRequest, on conn: HAPConnection) -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: Data(request.body)) as? [String: Any],
              let list = body["characteristics"] as? [[String: Any]] else { return HTTPResponse(status: 400) }
        var results: [[String: Any]] = []
        var anyFailed = false, anyResponse = false
        for item in list {
            let aid = (item["aid"] as? NSNumber)?.intValue ?? 0, iid = (item["iid"] as? NSNumber)?.intValue ?? 0
            var entry: [String: Any] = ["aid": aid, "iid": iid, "status": 0]
            guard aid == accessory.aid, let c = accessory.characteristic(iid: iid) else {
                entry["status"] = HAPStatus.resourceDoesNotExist.rawValue
                anyFailed = true
                results.append(entry)
                continue
            }
            if let ev = item["ev"] as? Bool {
                if c.permissions.contains(.notify) {
                    conn.subscribe(iid, ev)
                } else {
                    entry["status"] = HAPStatus.notificationNotSupported.rawValue
                    anyFailed = true
                }
            }
            if let raw = item["value"] {
                do throws(HAPStatus) {
                    guard c.permissions.contains(.write) else { throw .readOnly }
                    // A characteristic that needs a timed write takes one only under a prepared, unexpired id.
                    if c.permissions.contains(.timedWrite) {
                        guard let pid = (body["pid"] as? NSNumber)?.uint64Value, conn.takePrepared(pid) else { throw .invalidValue }
                    }
                    guard let value = HAPValue.from(json: raw, format: c.format) else { throw .invalidValue }
                    let outcome = HAPRequest.$session.withValue(conn.keys) { () -> Result<HAPValue?, HAPStatus> in
                        do throws(HAPStatus) { return .success(try c.write(value)) } catch { return .failure(error) }
                    }
                    let reply = try outcome.get()
                    if item["r"] as? Bool == true, let reply {
                        entry["value"] = reply.json
                        anyResponse = true
                    }
                    notify(c, except: conn)
                } catch {
                    entry["status"] = error.rawValue
                    anyFailed = true
                }
            }
            results.append(entry)
        }
        guard anyFailed || anyResponse else { return HTTPResponse(status: 204) }
        return HTTPResponse(status: 207, contentType: "application/hap+json", body: Self.json(["characteristics": results]))
    }
}

/// One controller's connection to the accessory.
/// What a characteristic write's handler may need about the session it comes on.
public enum HAPRequest {
    /// The session's keys (its shared secret derives the HomeKit Data Stream's keys).
    @TaskLocal public static var session: SessionKeys?
}

public final class HAPConnection: @unchecked Sendable {
    weak var server: AccessoryServer?
    /// Where it comes from ("192.168.1.20:52114"), for the log.
    public var peer: String?
    /// A timed write announced with PUT /prepare: its id and until when it may be made.
    private var prepared: (pid: UInt64, until: Date)?
    private let preparedLock = NSLock()

    func prepare(_ pid: UInt64, until: Date) { preparedLock.withLock { prepared = (pid, until) } }

    /// Whether `pid` is the announced timed write and still in time (used up either way).
    func takePrepared(_ pid: UInt64) -> Bool {
        preparedLock.withLock {
            defer { prepared = nil }
            guard let p = prepared else { return false }
            return p.pid == pid && p.until >= Date()
        }
    }
    let send: @Sendable ([UInt8]) -> Void
    let verifier: PairVerify
    private var reader = HTTPRequestReader()
    private var outgoing: FrameCipher?
    private var incoming: FrameCipher?
    private(set) var keys: SessionKeys?
    private var subscriptions: Set<Int> = []
    var closeAfterReply = false
    /// Set when the connection should be closed (bad frame, unpaired).
    public private(set) var shouldClose = false
    private let lock = NSLock()
    /// Requests are answered one at a time, in order.
    private var queue: [HTTPRequest] = []
    private var working = false

    init(server: AccessoryServer, send: @escaping @Sendable ([UInt8]) -> Void) {
        self.server = server
        self.send = send
        verifier = PairVerify(identity: server.identity, store: server.store)
    }

    func isSubscribed(_ iid: Int) -> Bool { lock.withLock { subscriptions.contains(iid) } }

    func subscribe(_ iid: Int, _ on: Bool) {
        lock.withLock { if on { subscriptions.insert(iid) } else { subscriptions.remove(iid) } }
    }

    /// Bytes from the controller.
    public func receive(_ bytes: [UInt8]) {
        let requests: [HTTPRequest]? = lock.withLock {
            var plain = bytes
            if incoming != nil {
                do throws(FrameCipher.OpenError) {
                    plain = try incoming!.open(bytes)
                } catch {
                    shouldClose = true
                    return nil
                }
            }
            return try? reader.add(plain)
        }
        guard let requests else {
            shouldClose = true
            return
        }
        lock.withLock { queue += requests }
        pump()
    }

    private func pump() {
        let next: HTTPRequest? = lock.withLock {
            guard !working, !queue.isEmpty else { return nil }
            working = true
            return queue.removeFirst()
        }
        guard let next, let server else { return }
        Task {
            let response = await server.handle(next, on: self)
            respond(response, to: next)
            lock.withLock { working = false }
            pump()
        }
    }

    private func respond(_ response: HTTPResponse, to request: HTTPRequest) {
        let bytes = response.serialized()
        lock.withLock {
            if var out = outgoing {
                send(out.seal(bytes))
                outgoing = out
            } else {
                send(bytes)
            }
            // Pair verify's last reply goes out in plain; everything after is encrypted.
            if request.path == "/pair-verify", outgoing == nil, let keys = verifier.keys {
                self.keys = keys
                outgoing = FrameCipher(key: keys.outgoing)
                incoming = FrameCipher(key: keys.incoming)
            }
            if closeAfterReply { shouldClose = true }
        }
        if request.path == "/pair-verify", let keys { server?.sessionVerified?(keys) }
    }

    func sendEvent(_ body: [UInt8]) {
        let bytes = HTTPResponse(status: 200, contentType: "application/hap+json", body: body).serialized(event: true)
        lock.withLock {
            guard var out = outgoing else { return }
            send(out.seal(bytes))
            outgoing = out
        }
    }

    public func closed() { server?.disconnected(self) }
}
