// SPDX-License-Identifier: MIT
// A relay of one's own (TURN, RFC 8656), for when no direct path works: the relay gives this side an address of its
// own (a relayed candidate), and passes what's sent to it on to this side, and what this side sends through it on
// to the other. Pond's relay is coturn, run by whoever runs the signaling service (deploy/, its relay profile), with
// a shared secret: each side makes its own short-lived username and password from it (coturn's REST credentials),
// and signs its requests with TURN's long-term key, MD5(username:realm:password), as its RFC has it.
//
// What goes through: Send and Data indications (each packet wrapped with the peer's address). (ChannelData, TURN's
// four-byte framing, would save a little on video; not used.) Permissions are asked for each peer's address before
// anything's sent it, and kept; the allocation is refreshed at half its lifetime, and let go on close. It runs on
// its PathFinder's queue: nothing in it is locked.
import Foundation

public final class TURNClient {
    public struct Server: Equatable, Sendable {
        public var address: STUNAddress
        public var username: String
        public var password: String

        public init(address: STUNAddress, username: String, password: String) {
            self.address = address
            self.username = username
            self.password = password
        }
    }

    /// coturn's shared-secret credentials (use-auth-secret): the username says until when it's good, the password is
    /// an HMAC-SHA1 of it under the secret, base64.
    public static func credentials(secret: String, name: String, lifetime: TimeInterval = 86400, now: Date = Date()) -> (username: String, password: String) {
        let username = "\(Int(now.timeIntervalSince1970 + lifetime)):\(name)"
        let password = Data(Hashes.hmac(Array(secret.utf8), Array(username.utf8))).base64EncodedString()
        return (username, password)
    }

    // Methods (a request's type is its method; success adds 0x100, an error 0x110) and indications.
    static let allocate: UInt16 = 0x003, refresh: UInt16 = 0x004, createPermission: UInt16 = 0x008
    static let sendIndication: UInt16 = 0x0016, dataIndication: UInt16 = 0x0017
    // Attributes.
    static let lifetime: UInt16 = 0x000D, xorPeerAddress: UInt16 = 0x0012, data: UInt16 = 0x0013, realm: UInt16 = 0x0014,
               nonce: UInt16 = 0x0015, xorRelayedAddress: UInt16 = 0x0016, requestedTransport: UInt16 = 0x0019

    public let server: Server
    let output: ([UInt8], STUNAddress) -> Void
    /// The relayed address it was given, and the public one the relay saw it at.
    public private(set) var relayed: STUNAddress?, mapped: STUNAddress?
    /// The relay's last refusal, in words (for a diagnosis).
    public private(set) var problem: String?
    private var realmValue: [UInt8]?, nonceValue: [UInt8]?
    private var allocated: ((STUNAddress?) -> Void)?
    private var refreshAt: Date?
    private var permissions: [[UInt8]: Date] = [:]
    /// Addresses a permission's been asked for (first, or renewed while the old one still holds).
    private var asked: Set<[UInt8]> = []
    private var waiting: [[UInt8]: [([UInt8], STUNAddress)]] = [:]
    private var transactions: [[UInt8]: Request] = [:]

    struct Request {
        var method: UInt16
        var attributes: [STUNMessage.Attribute]
        /// The peer a permission is for (its XOR-PEER-ADDRESS made anew for each transaction, as it's XORed with it).
        var peer: STUNAddress?
        var bytes: [UInt8]
        var tries = 5, wait = 0.25
        var next = Date()
        /// Sent again after a 401 or 438 already (once is enough: twice is a wrong password).
        var retried = false
    }

    /// A relay at `server`; `output` sends it bytes (through the PathFinder's socket).
    init(server: Server, output: @escaping ([UInt8], STUNAddress) -> Void) {
        self.server = server
        self.output = output
    }

    /// The long-term key, once the relay has said its realm.
    private var key: [UInt8]? {
        realmValue.map { Hashes.md5(Array("\(server.username):".utf8) + $0 + Array(":\(server.password)".utf8)) }
    }

    // MARK: Asking

    /// An allocation asked for: `done` with the relayed address, or nil (refused, or no answer).
    func allocate(_ done: @escaping (STUNAddress?) -> Void) {
        allocated = done
        ask(Self.allocate, [.init(Self.requestedTransport, [17, 0, 0, 0])])   // UDP
    }

    /// Bytes to a peer through the relay (once it lets them through: a permission asked for first, if need be).
    func send(_ bytes: [UInt8], to peer: STUNAddress) {
        guard relayed != nil else { return }
        if let until = permissions[peer.ip], until > Date() {
            let indication = STUNMessage(type: Self.sendIndication)
            var message = indication
            message.attributes = [.init(Self.xorPeerAddress, peer.xorEncoded(transaction: indication.transaction)), .init(Self.data, bytes)]
            output(message.encoded(fingerprint: false), server.address)
            return
        }
        waiting[peer.ip, default: []].append((bytes, peer))
        permit(peer)
    }

    /// A permission for the peer's address asked for (the port is ignored: a permission is for an address).
    private func permit(_ peer: STUNAddress) {
        guard asked.insert(peer.ip).inserted else { return }
        ask(Self.createPermission, [], peer: peer)
    }

    /// The allocation let go (a refresh with no lifetime).
    func close() {
        guard relayed != nil else { return }
        ask(Self.refresh, [.init(Self.lifetime, STUNMessage.be32(0))])
        relayed = nil
    }

    private func ask(_ method: UInt16, _ attributes: [STUNMessage.Attribute], peer: STUNAddress? = nil, retried: Bool = false) {
        let transaction = STUNMessage.newTransaction()
        var message = STUNMessage(type: method, transaction: transaction, attributes: attributes)
        if let peer { message.attributes.append(.init(Self.xorPeerAddress, peer.xorEncoded(transaction: transaction))) }
        var bytes: [UInt8]
        if let key, let realmValue, let nonceValue {
            message.attributes += [.init(STUNMessage.Attribute.username, Array(server.username.utf8)),
                                   .init(Self.realm, realmValue), .init(Self.nonce, nonceValue)]
            bytes = message.encoded(integrity: key)
        } else {
            bytes = message.encoded()
        }
        transactions[transaction] = Request(method: method, attributes: attributes, peer: peer, bytes: bytes, retried: retried)
        transmit(transaction)
    }

    private func transmit(_ id: [UInt8]) {
        guard var r = transactions[id] else { return }
        output(r.bytes, server.address)
        r.tries -= 1
        r.next = Date().addingTimeInterval(r.wait)
        r.wait *= 2
        transactions[id] = r
    }

    // MARK: Time passing

    func tick(_ now: Date) {
        for (id, r) in transactions where now >= r.next {
            if r.tries > 0 {
                transmit(id)
            } else {
                transactions.removeValue(forKey: id)
                failed(r, "the relay didn't answer")
            }
        }
        if let refreshAt, now >= refreshAt {
            self.refreshAt = nil
            ask(Self.refresh, [.init(Self.lifetime, STUNMessage.be32(600))])
        }
        // Permissions last 5 minutes: renewed a minute before they'd go (the old one holding meanwhile).
        for (ip, until) in permissions where until.timeIntervalSince(now) < 60 {
            permit(STUNAddress(ip: ip, port: 0))
        }
    }

    // MARK: What it answers

    /// Bytes from the relay: its answers (taken here), or a peer's packet passed on (returned, with where from).
    func handle(_ bytes: [UInt8]) -> (data: [UInt8], from: STUNAddress)? {
        guard let message = try? STUNMessage(bytes) else { return nil }
        if message.type == Self.dataIndication {
            guard let peer = message.attribute(Self.xorPeerAddress).flatMap({ STUNAddress(xorEncoded: $0, transaction: message.transaction) }),
                  let data = message.attribute(Self.data) else { return nil }
            return (data, peer)
        }
        guard let r = transactions[message.transaction] else { return nil }
        // A success, or an error answered, is signed once there's a key (an unsigned one isn't the relay's).
        if let key, (try? STUNMessage(bytes, integrity: key)) == nil, message.type & 0x0110 != 0x0110 { return nil }
        transactions.removeValue(forKey: message.transaction)
        if message.type == r.method | 0x0110 {
            let code = message.attribute(STUNMessage.Attribute.errorCode).flatMap { $0.count >= 4 ? Int($0[2] & 0x07) * 100 + Int($0[3]) : nil }
            // Unauthorized (the first ask, or a credential it won't take) or a stale nonce: asked again, signed, once.
            if code == 401 || code == 438, !r.retried, let realm = message.attribute(Self.realm) ?? realmValue,
               let nonce = message.attribute(Self.nonce) {
                realmValue = realm
                nonceValue = nonce
                ask(r.method, r.attributes, peer: r.peer, retried: true)
                return nil
            }
            failed(r, code == 401 ? "the relay refused this Mac's credentials (is the secret right?)"
                       : "the relay refused (error \(code.map(String.init) ?? "?"))")
            return nil
        }
        guard message.type == r.method | 0x0100 else { return nil }
        switch r.method {
        case Self.allocate:
            relayed = message.attribute(Self.xorRelayedAddress).flatMap { STUNAddress(xorEncoded: $0, transaction: message.transaction) }
            mapped = message.attribute(STUNMessage.Attribute.xorMappedAddress).flatMap { STUNAddress(xorEncoded: $0, transaction: message.transaction) }
            let seconds = message.attribute(Self.lifetime).flatMap { $0.count == 4 ? Double(STUNMessage.be32($0, 0)) : nil } ?? 600
            refreshAt = Date().addingTimeInterval(seconds / 2)
            allocated?(relayed)
            allocated = nil
        case Self.refresh:
            let seconds = message.attribute(Self.lifetime).flatMap { $0.count == 4 ? Double(STUNMessage.be32($0, 0)) : nil } ?? 600
            if seconds > 0 { refreshAt = Date().addingTimeInterval(seconds / 2) }
        case Self.createPermission:
            guard let peer = r.peer else { return nil }
            asked.remove(peer.ip)
            permissions[peer.ip] = Date().addingTimeInterval(300)
            for (bytes, to) in waiting.removeValue(forKey: peer.ip) ?? [] { send(bytes, to: to) }
        default:
            break
        }
        return nil
    }

    private func failed(_ r: Request, _ why: String) {
        problem = why
        if r.method == Self.allocate {
            allocated?(nil)
            allocated = nil
        }
        // A permission refused: what waited for it dropped, and asked again when something's next sent.
        if r.method == Self.createPermission, let peer = r.peer {
            asked.remove(peer.ip)
            waiting.removeValue(forKey: peer.ip)
        }
    }
}
