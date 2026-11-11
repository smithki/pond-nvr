// SPDX-License-Identifier: MIT
// A made-up internet for PathFinder's tests: hosts on home networks behind routers (each router's mapping and filtering as
// real ones behave), hosts on the internet itself, a STUN server, and as much loss and delay as asked for.
//
// Mapping: endpoint-independent (one public port for a socket, whoever it sends to: most home routers) or per
// destination (a new public port for each address it sends to: "symmetric", as some carrier and office NATs are,
// which defeats peer-reflexive tricks unless the other side is easy). Filtering: open (anything to a mapped port is
// let in), address-dependent (from any port of an address the inside host has sent to), or address-and-port-
// dependent (only from exactly where it has sent to).
import Foundation
@testable import Traversal

final class FakeNetwork: @unchecked Sendable {
    enum Mapping { case endpointIndependent, perDestination }
    enum Filtering { case open, address, addressAndPort }

    final class Router: @unchecked Sendable {
        let publicIP: [UInt8]
        let mapping: Mapping
        let filtering: Filtering
        var nextPort: UInt16 = 40000
        /// Outbound mappings: (inside address, destination if per destination) → public port.
        var ports: [String: UInt16] = [:]
        /// Public port → the inside address it maps to.
        var inside: [UInt16: STUNAddress] = [:]
        /// What each public port has sent to (for filtering).
        var sentTo: [UInt16: Set<STUNAddress>] = [:]

        init(publicIP: [UInt8], mapping: Mapping, filtering: Filtering) {
            self.publicIP = publicIP
            self.mapping = mapping
            self.filtering = filtering
        }
    }

    final class Host: PacketTransport, @unchecked Sendable {
        let network: FakeNetwork
        var ip: [UInt8]
        var router: Router?
        let port: UInt16
        var handler: (@Sendable ([UInt8], STUNAddress) -> Void)?
        var closed = false

        init(network: FakeNetwork, ip: [UInt8], port: UInt16, router: Router?) {
            self.network = network
            self.ip = ip
            self.port = port
            self.router = router
        }

        var address: STUNAddress { STUNAddress(ip: ip, port: port) }
        /// To another network (Wi-Fi to cellular): a new address, behind another router.
        func move(to ip: [UInt8], behind router: Router?) { network.lock.withLock { self.ip = ip; self.router = router } }
        func send(_ bytes: [UInt8], to: STUNAddress) { network.route(bytes, from: self, to: to) }
        func receive(_ handler: @escaping @Sendable ([UInt8], STUNAddress) -> Void) { network.lock.withLock { self.handler = handler } }
        func close() { network.lock.withLock { closed = true } }
    }

    let lock = NSLock()
    let queue = DispatchQueue(label: "fake network")
    var loss = 0.0
    var latency = 0.003
    /// Every packet's path cut (as a network going away).
    var cut = false
    private var hosts: [Host] = []
    private var nextPort: UInt16 = 5000

    /// A host on a home network behind `router` (nil: on the internet itself, `ip` public).
    func host(_ ip: [UInt8], behind router: Router? = nil) -> Host {
        lock.withLock {
            nextPort += 1
            let host = Host(network: self, ip: ip, port: nextPort, router: router)
            hosts.append(host)
            return host
        }
    }

    /// A STUN server on the internet: answers each binding request with where it came from.
    func stunServer(_ ip: [UInt8]) -> STUNAddress {
        let server = host(ip)
        server.receive { [weak server] bytes, from in
            guard let server, let request = try? STUNMessage(bytes), request.type == STUNMessage.bindingRequest else { return }
            server.send(STUNMessage(type: STUNMessage.bindingSuccess, transaction: request.transaction, attributes: [
                .init(STUNMessage.Attribute.xorMappedAddress, from.xorEncoded(transaction: request.transaction)),
            ]).encoded(), to: from)
        }
        return server.address
    }

    func route(_ bytes: [UInt8], from host: Host, to destination: STUNAddress) {
        lock.lock()
        defer { lock.unlock() }
        guard !cut, !host.closed, Double.random(in: 0 ..< 1) >= loss else { return }
        // On the same home network: straight there.
        if let router = host.router, let peer = hosts.first(where: { $0.router === router && $0.ip == destination.ip && $0.port == destination.port }) {
            deliver(bytes, to: peer, from: host.address)
            return
        }
        // Out through the router: the source becomes its public address and a port it maps.
        var source = host.address
        if let router = host.router {
            let key = "\(host.address)" + (router.mapping == .perDestination ? "→\(destination)" : "")
            let port = router.ports[key] ?? {
                router.nextPort += 1
                router.ports[key] = router.nextPort
                router.inside[router.nextPort] = host.address
                return router.nextPort
            }()
            router.sentTo[port, default: []].insert(destination)
            source = STUNAddress(ip: router.publicIP, port: port)
        }
        // In: to a host on the internet, or through a router to the host its port maps to (if it lets it in).
        if let peer = hosts.first(where: { $0.router == nil && $0.ip == destination.ip && $0.port == destination.port }) {
            deliver(bytes, to: peer, from: source)
            return
        }
        let routers = Set(hosts.compactMap(\.router).map(ObjectIdentifier.init))
        guard let router = hosts.compactMap(\.router).first(where: { routers.contains(ObjectIdentifier($0)) && $0.publicIP == destination.ip }),
              let inside = router.inside[destination.port] else { return }
        let sent = router.sentTo[destination.port] ?? []
        switch router.filtering {
        case .open: break
        case .address: guard sent.contains(where: { $0.ip == source.ip }) else { return }
        case .addressAndPort: guard sent.contains(source) else { return }
        }
        guard let peer = hosts.first(where: { $0.router === router && $0.address == inside }) else { return }
        deliver(bytes, to: peer, from: source)
    }

    private func deliver(_ bytes: [UInt8], to host: Host, from: STUNAddress) {
        guard !host.closed, let handler = host.handler else { return }
        queue.asyncAfter(deadline: .now() + latency * Double.random(in: 0.5 ... 1.5)) { handler(bytes, from) }
    }

    // MARK: A relay

    /// A TURN server on the internet, as coturn with a shared secret answers: unauthorized at first (its realm and
    /// a nonce), then requests signed with the long-term key of a username and password made from the secret.
    /// Allocations, permissions and refreshes; what's sent through it goes out from the relayed address, and what
    /// comes in from a permitted peer is passed back as a Data indication.
    final class Relay: @unchecked Sendable {
        let network: FakeNetwork
        let secret: String
        let control: Host
        let realm = Array("pond".utf8), nonce = Array("n0nce".utf8)
        let lock = NSLock()
        /// Each client's allocation: its relayed host, and the addresses it may hear from.
        var allocations: [STUNAddress: (relayed: Host, permitted: Set<[UInt8]>)] = [:]
        var refused = 0

        init(network: FakeNetwork, ip: [UInt8], secret: String) {
            self.network = network
            self.secret = secret
            control = network.host(ip)
            control.receive { [weak self] bytes, from in self?.handle(bytes, from: from) }
        }

        var address: STUNAddress { control.address }

        /// The key a username's requests are signed with (its password made from the secret, as the client makes it).
        func key(for username: [UInt8]) -> [UInt8] {
            let password = Data(Hashes.hmac(Array(secret.utf8), username)).base64EncodedString()
            return Hashes.md5(username + Array(":".utf8) + realm + Array(":\(password)".utf8))
        }

        func handle(_ bytes: [UInt8], from client: STUNAddress) {
            guard let message = try? STUNMessage(bytes) else { return }
            if message.type == TURNClient.sendIndication {
                guard let peer = message.attribute(TURNClient.xorPeerAddress).flatMap({ STUNAddress(xorEncoded: $0, transaction: message.transaction) }),
                      let data = message.attribute(TURNClient.data),
                      let allocation = lock.withLock({ allocations[client] }), allocation.permitted.contains(peer.ip) else { return }
                allocation.relayed.send(data, to: peer)
                return
            }
            let method = message.type
            // Unsigned (or signed with the wrong key): unauthorized, with the realm and a nonce to sign with.
            guard let username = message.attribute(STUNMessage.Attribute.username),
                  let key = Optional(key(for: username)), (try? STUNMessage(bytes, integrity: key)) != nil else {
                if message.attribute(STUNMessage.Attribute.username) != nil { lock.withLock { refused += 1 } }
                control.send(STUNMessage(type: method | 0x0110, transaction: message.transaction, attributes: [
                    .init(STUNMessage.Attribute.errorCode, [0, 0, 4, 1] + Array("Unauthorized".utf8)),
                    .init(TURNClient.realm, realm), .init(TURNClient.nonce, nonce),
                ]).encoded(), to: client)
                return
            }
            var answer: [STUNMessage.Attribute] = []
            switch method {
            case TURNClient.allocate:
                let relayed = lock.withLock { allocations[client]?.relayed } ?? network.host(control.ip)
                lock.withLock { if allocations[client] == nil { allocations[client] = (relayed, []) } }
                relayed.receive { [weak self] data, peer in
                    guard let self, let allocation = lock.withLock({ allocations[client] }), allocation.permitted.contains(peer.ip) else { return }
                    let indication = STUNMessage(type: TURNClient.dataIndication)
                    var message = indication
                    message.attributes = [.init(TURNClient.xorPeerAddress, peer.xorEncoded(transaction: indication.transaction)),
                                          .init(TURNClient.data, data)]
                    control.send(message.encoded(), to: client)
                }
                answer = [.init(TURNClient.xorRelayedAddress, relayed.address.xorEncoded(transaction: message.transaction)),
                          .init(STUNMessage.Attribute.xorMappedAddress, client.xorEncoded(transaction: message.transaction)),
                          .init(TURNClient.lifetime, STUNMessage.be32(600))]
            case TURNClient.createPermission:
                guard let peer = message.attribute(TURNClient.xorPeerAddress).flatMap({ STUNAddress(xorEncoded: $0, transaction: message.transaction) })
                else { return }
                _ = lock.withLock { allocations[client]?.permitted.insert(peer.ip) }
            case TURNClient.refresh:
                answer = [.init(TURNClient.lifetime, message.attribute(TURNClient.lifetime) ?? STUNMessage.be32(600))]
            default:
                return
            }
            control.send(STUNMessage(type: method | 0x0100, transaction: message.transaction, attributes: answer).encoded(integrity: key), to: client)
        }
    }

    func relay(_ ip: [UInt8], secret: String) -> Relay { Relay(network: self, ip: ip, secret: secret) }
}
