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
