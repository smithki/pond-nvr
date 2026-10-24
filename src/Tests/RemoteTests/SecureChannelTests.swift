import CryptoKit
import Foundation
import Testing
@testable import Remote

@Suite struct SecureChannelTests {
    /// Two ends of a channel over a made-up link that loses, delays and reorders packets as asked.
    final class Link: @unchecked Sendable {
        let lock = NSLock()
        var loss = 0.0, jitter = 0.0
        var tamper = false
        var a: SecureChannel!, b: SecureChannel!
        var seen: [[UInt8]] = []
        let queue = DispatchQueue(label: "link", attributes: .concurrent)

        init() {
            let home = Curve25519.KeyAgreement.PrivateKey(), away = Curve25519.KeyAgreement.PrivateKey()
            let session = UUID()
            let atHome = try! SessionKeys.derive(mine: home, theirs: away.publicKey.rawRepresentation, session: session, controlling: true)
            let atAway = try! SessionKeys.derive(mine: away, theirs: home.publicKey.rawRepresentation, session: session, controlling: false)
            // (Weakly: a channel's timer can outlast its test.)
            a = SecureChannel(keys: atHome) { [weak self] frame in self?.carry(frame, to: { [weak self] in self?.b }) }
            b = SecureChannel(keys: atAway) { [weak self] frame in self?.carry(frame, to: { [weak self] in self?.a }) }
        }

        func carry(_ frame: [UInt8], to: @escaping @Sendable () -> SecureChannel?) {
            let (lost, delay, tampering) = lock.withLock { () -> (Bool, Double, Bool) in
                seen.append(frame)
                return (Double.random(in: 0 ..< 1) < loss, Double.random(in: 0 ... jitter), tamper)
            }
            guard !lost else { return }
            var altered = frame
            if tampering { altered[altered.count - 1] ^= 1 }
            let sent = altered
            queue.asyncAfter(deadline: .now() + 0.002 + delay) { to()?.handle(sent) }
        }
    }

    final class Inbox: @unchecked Sendable {
        let lock = NSLock()
        var messages: [Data] = []
        func add(_ m: Data) { lock.withLock { messages.append(m) } }
        var all: [Data] { lock.withLock { messages } }
    }

    func wait(_ inbox: Inbox, for count: Int, seconds: Double = 20) async {
        let deadline = Date().addingTimeInterval(seconds)
        while inbox.all.count < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func messagesArriveOnceAndInOrderThroughLossAndReordering() async {
        let link = Link()
        link.loss = 0.2
        link.jitter = 0.03
        defer { link.a.close(); link.b.close() }
        let inbox = Inbox()
        link.b.received = { inbox.add($0) }
        // Small ones and big ones (a picture's worth: many frames each).
        let sent = (0 ..< 40).map { i in Data((0 ..< (i % 5 == 0 ? 50_000 + i : i + 1)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ i) }) }
        for m in sent { link.a.send(m) }
        await wait(inbox, for: sent.count)
        #expect(inbox.all == sent)
    }

    @Test func bothWaysAtOnce() async {
        let link = Link()
        link.loss = 0.1
        defer { link.a.close(); link.b.close() }
        let atA = Inbox(), atB = Inbox()
        link.a.received = { atA.add($0) }
        link.b.received = { atB.add($0) }
        for i in 0 ..< 30 {
            link.a.send(Data("to b \(i)".utf8))
            link.b.send(Data("to a \(i)".utf8))
        }
        await wait(atA, for: 30)
        await wait(atB, for: 30)
        #expect(atB.all == (0 ..< 30).map { Data("to b \($0)".utf8) })
        #expect(atA.all == (0 ..< 30).map { Data("to a \($0)".utf8) })
    }

    @Test func nothingTamperedWithOrReplayedGetsThrough() async throws {
        let link = Link()
        defer { link.a.close(); link.b.close() }
        let inbox = Inbox()
        link.b.received = { inbox.add($0) }
        link.a.send(Data("one".utf8))
        await wait(inbox, for: 1)
        #expect(inbox.all == [Data("one".utf8)])
        // A frame seen on the wire, sent again: dropped (already delivered).
        let first = try #require(link.lock.withLock { link.seen.first })
        link.b.handle(first)
        // Every frame altered on the way: none opens, nothing more delivered.
        link.lock.withLock { link.tamper = true }
        link.a.send(Data("two".utf8))
        try await Task.sleep(for: .milliseconds(500))
        #expect(inbox.all == [Data("one".utf8)])
        // And it's all encrypted: the words aren't on the wire.
        #expect(!link.lock.withLock { link.seen }.contains { String(decoding: $0, as: UTF8.self).contains("one") })
    }

    @Test func anEmptyMessageIsOne() async {
        let link = Link()
        defer { link.a.close(); link.b.close() }
        let inbox = Inbox()
        link.b.received = { inbox.add($0) }
        link.a.send(Data())
        await wait(inbox, for: 1, seconds: 3)
        #expect(inbox.all == [Data()])
    }
}
