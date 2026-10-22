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
}
