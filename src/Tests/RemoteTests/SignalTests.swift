import Foundation
import Network
import NVRCore
import Signal
import Testing
import Traversal
@testable import Remote

/// The signaling service and its client, together on this Mac.
@Suite(.serialized) struct SignalTests {
    static func server() throws -> SignalServer {
        let server = SignalServer(port: 0) { _ in }
        try server.start()
        return server
    }

    static func waitConnected(_ clients: SignalClient...) async {
        for _ in 0 ..< 100 where !clients.allSatisfy(\.isConnected) { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func twoMailboxesPassAnEnvelope() async throws {
        let server = try Self.server()
        defer { server.stop() }
        let url = URL(string: "ws://127.0.0.1:\(server.boundPort)")!
        let home = RemoteIdentity(name: "Home"), phone = RemoteIdentity(name: "Phone")
        let got = Received()
        let homeClient = SignalClient(url: url, identity: home) { got.add($0) }
        let phoneClient = SignalClient(url: url, identity: phone) { _ in }
        homeClient.start()
        phoneClient.start()
        defer { homeClient.stop(); phoneClient.stop() }
        await Self.waitConnected(homeClient, phoneClient)
        #expect(server.connected == 2)

        let envelope = try Envelope.seal(kind: "offer", body: Data("hi".utf8), from: phone, to: home.peer)
        #expect(await phoneClient.send(envelope))
        for _ in 0 ..< 50 where got.all.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let arrived = try #require(got.all.first)
        #expect(arrived == envelope)
        #expect(try arrived.open(as: home, replay: ReplayGuard(), known: [phone.peer]).body == Data("hi".utf8))

        // To a mailbox nobody's at: undelivered.
        let nobody = try Envelope.seal(kind: "offer", body: Data(), from: phone, to: RemoteIdentity(name: "Away").peer)
        #expect(await phoneClient.send(nobody) == false)
    }

    @Test func twoPondsPairThroughTheService() async throws {
        let server = try Self.server()
        defer { server.stop() }
        let url = URL(string: "ws://127.0.0.1:\(server.boundPort)")!
        let home = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Home", signaling: url) { _ in }
        let away = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Away", signaling: url) { _ in }
        home.start()
        away.start()
        defer { home.stop(); away.stop() }

        let code = try #require(PairingCode(text: home.newCode().text))
        let paired = try #require(await away.join(code))
        #expect(paired == home.identity.peer)
        #expect(away.devices() == [home.identity.peer])
        for _ in 0 ..< 50 where home.devices().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(home.devices() == [away.identity.peer])

        // A code is good once: used again (by another), no answer, and nobody new kept.
        let late = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Late", signaling: url) { _ in }
        late.start()
        defer { late.stop() }
        #expect(await late.join(code, waiting: .seconds(1)) == nil)
        #expect(home.devices().count == 1)

        // Unpaired: gone from the list.
        try home.unpair(away.identity.peer.id)
        #expect(home.devices().isEmpty)
    }

    @Test func twoPairedPondsFindAPathAndPing() async throws {
        let server = try Self.server()
        defer { server.stop() }
        let stun = STUNResponder(port: 0)
        try stun.start()
        defer { stun.stop() }
        let url = URL(string: "ws://127.0.0.1:\(server.boundPort)")!
        var settings = PathSessions.Settings()
        settings.stun = [STUNAddress(ip: [127, 0, 0, 1], port: stun.boundPort)]
        let home = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Home", signaling: url, paths: settings) { _ in }
        let away = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Away", signaling: url, paths: settings) { _ in }
        home.start()
        away.start()
        defer { home.stop(); away.stop() }
        let code = try #require(PairingCode(text: home.newCode().text))
        _ = try #require(await away.join(code))
        for _ in 0 ..< 50 where home.devices().isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        // By name: offered, answered, checked, chosen, pinged; both sealed through the signaling service.
        let outcome = try #require(await away.connect(to: "Home"))
        #expect(outcome.problem == nil, "\(outcome.summary)")
        #expect(outcome.pair != nil && outcome.roundTrip != nil)
        #expect(outcome.summary.hasPrefix("connected over"))
        // Not paired: nothing to connect to.
        #expect(await away.connect(to: "Nobody") == nil)
    }

    @Test func aRestartedPathCarriesOn() async throws {
        let server = try Self.server()
        defer { server.stop() }
        let url = URL(string: "ws://127.0.0.1:\(server.boundPort)")!
        let home = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Home", signaling: url) { _ in }
        let away = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Away", signaling: url) { _ in }
        home.start()
        away.start()
        defer { home.stop(); away.stop() }
        let code = try #require(PairingCode(text: home.newCode().text))
        let peer = try #require(await away.join(code))
        for _ in 0 ..< 50 where home.devices().isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        let (outcome, opened) = await away.paths.open(to: peer)
        let session = try #require(opened, "\(outcome.summary)")
        defer { away.paths.close(session) }
        let before = session.finder.local
        // As if this Mac's network had changed: found again, with new credentials on both sides.
        await away.paths.restart(session)
        #expect(session.finder.local != before)
        for _ in 0 ..< 100 { try await Task.sleep(for: .milliseconds(20)) }
        guard case .connected = session.finder.state else { Issue.record("\(session.finder.state)"); return }
        // Still carrying: a ping answered.
        final class Pong: @unchecked Sendable { let lock = NSLock(); var got = false }
        let pong = Pong()
        session.finder.received = { bytes in if bytes.first == PathSessions.pong { pong.lock.withLock { pong.got = true } } }
        session.finder.send([PathSessions.ping, 1])
        for _ in 0 ..< 50 where !pong.lock.withLock({ pong.got }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pong.lock.withLock { pong.got })
    }

    @Test func noPathSaysWhy() async throws {
        let server = try Self.server()
        defer { server.stop() }
        let url = URL(string: "ws://127.0.0.1:\(server.boundPort)")!
        // Neither side offers its own addresses, and there's no STUN to learn public ones: nothing to check.
        var settings = PathSessions.Settings()
        settings.shareLocalAddresses = false
        settings.timing.giveUp = 1
        let home = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Home", signaling: url, paths: settings) { _ in }
        let away = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Away", signaling: url, paths: settings) { _ in }
        home.start()
        away.start()
        defer { home.stop(); away.stop() }
        let code = try #require(PairingCode(text: home.newCode().text))
        _ = try #require(await away.join(code))
        let outcome = try #require(await away.connect(to: "Home"))
        #expect(outcome.pair == nil)
        #expect(outcome.summary.hasPrefix("This Mac couldn't learn its public address"), "\(outcome.summary)")
        #expect(outcome.summary.contains("To fix it:"))
    }

    @Test func aStrangersOfferGoesUnanswered() async throws {
        let server = try Self.server()
        defer { server.stop() }
        let url = URL(string: "ws://127.0.0.1:\(server.boundPort)")!
        var settings = PathSessions.Settings()
        settings.timing.giveUp = 2
        let home = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Home", signaling: url, paths: settings) { _ in }
        let stranger = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Stranger", signaling: url, paths: settings) { _ in }
        home.start()
        stranger.start()
        defer { home.stop(); stranger.stop() }
        await Self.waitConnected()
        for _ in 0 ..< 100 { try await Task.sleep(for: .milliseconds(20)); if server.connected == 2 { break } }
        // The stranger knows the home Pond's keys (as anyone shown its code might), but isn't paired with it.
        let outcome = await stranger.paths.connect(to: home.identity.peer)
        #expect(outcome.pair == nil && outcome.problem?.contains("didn't answer") == true, "\(outcome.summary)")
    }

    @Test func aMailboxIsOnlyItsOwners() async throws {
        let server = try Self.server()
        defer { server.stop() }
        // A raw connection claiming the home's mailbox with the wrong secret: refused, and not connected.
        let home = RemoteIdentity(name: "Home")
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(server.boundPort)")!)
        task.resume()
        let hello = SignalServer.Message(op: "hello", mailbox: home.peer.mailbox, secret: Data(repeating: 1, count: 32))
        try await task.send(.string(String(decoding: try JSONEncoder().encode(hello), as: UTF8.self)))
        guard case let .string(text) = try await task.receive() else { Issue.record("no answer"); return }
        #expect(try JSONDecoder().decode(SignalServer.Message.self, from: Data(text.utf8)).op == "error")
        #expect(server.connected == 0)
        task.cancel()
    }

    @Test func stunTellsAnAskerItsAddress() async throws {
        let stun = STUNResponder(port: 0)
        try stun.start()
        defer { stun.stop() }
        let request = STUNMessage(type: STUNMessage.bindingRequest)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: stun.boundPort)!, using: .udp)
        let answer: [UInt8] = try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.send(content: Data(request.encoded()), completion: .contentProcessed { _ in })
                connection.receiveMessage { data, _, _, error in
                    if let data { continuation.resume(returning: Array(data)) } else { continuation.resume(throwing: error ?? POSIXError(.EIO)) }
                }
            }
            connection.start(queue: .global())
        }
        connection.cancel()
        let message = try STUNMessage(answer)
        #expect(message.type == STUNMessage.bindingSuccess && message.transaction == request.transaction)
        let mapped = try #require(message.attribute(STUNMessage.Attribute.xorMappedAddress)
            .flatMap { STUNAddress(xorEncoded: $0, transaction: request.transaction) })
        #expect(mapped.ip == [127, 0, 0, 1] && mapped.port != 0)
    }
}

final class Received: @unchecked Sendable {
    private var list: [Envelope] = []
    private let lock = NSLock()
    func add(_ e: Envelope) { lock.withLock { list.append(e) } }
    var all: [Envelope] { lock.withLock { list } }
}
