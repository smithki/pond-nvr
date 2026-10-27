import CryptoKit
import Foundation
import Testing
@testable import Remote

@Suite struct SecureChannelTests {
    /// Two ends of a channel over a made-up link that loses, delays and reorders packets as asked.
    final class Link: @unchecked Sendable {
        let lock = NSLock()
        var loss = 0.0, jitter = 0.0
        /// Each way: how long a packet takes, and (when set) a bottleneck: its rate (bytes a second) and how much
        /// it queues (seconds' worth) before dropping what comes.
        var delay = 0.002
        var rate = 0.0, queue = 0.1
        var free: [ObjectIdentifier: Date] = [:]
        var tamper = false
        var a: SecureChannel!, b: SecureChannel!
        var seen: [[UInt8]] = []
        let queue_ = DispatchQueue(label: "link", attributes: .concurrent)

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
                if seen.count < 1000 { seen.append(frame) }
                var wait = self.delay + Double.random(in: 0 ... jitter)
                if rate > 0, let target = to() {
                    // Through the bottleneck: after what's ahead of it in its queue, or dropped if that's full.
                    let now = Date(), key = ObjectIdentifier(target)
                    let start = max(now, free[key] ?? now)
                    if start.timeIntervalSince(now) > queue { return (true, 0, false) }
                    let done = start.addingTimeInterval(Double(frame.count) / rate)
                    free[key] = done
                    wait += done.timeIntervalSince(now)
                }
                return (Double.random(in: 0 ..< 1) < loss, wait, tamper)
            }
            guard !lost else { return }
            var altered = frame
            if tampering { altered[altered.count - 1] ^= 1 }
            let sent = altered
            self.queue_.asyncAfter(deadline: .now() + delay) { to()?.handle(sent) }
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

    /// How long a message of `bytes` takes from one end to the other.
    func transfer(_ link: Link, bytes: Int) async -> Double {
        let inbox = Inbox()
        link.b.received = { inbox.add($0) }
        let message = Data((0 ..< bytes).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let start = Date()
        link.a.send(message)
        await wait(inbox, for: 1, seconds: 60)
        #expect(inbox.all.first == message)
        return Date().timeIntervalSince(start)
    }

    @Test func aBigTransferFillsAFarLinkDespiteTheOddLoss() async {
        // 50 ms there and back, 1% of packets lost: 10 MB in a few seconds (a fixed window of 64 frames took 8 s).
        let link = Link()
        link.delay = 0.025
        link.loss = 0.01
        defer { link.a.close(); link.b.close() }
        let seconds = await transfer(link, bytes: 10_000_000)
        #expect(seconds < 4, "\(seconds) s")
    }

    @Test func aSlowLinkIsFilledNotSwamped() async {
        // A 2 MB/s bottleneck with a fifth of a second's queue, 40 ms there and back: most of its rate used (about
        // 3 s at all of it).
        let link = Link()
        link.delay = 0.02
        link.rate = 2_000_000
        link.queue = 0.2
        defer { link.a.close(); link.b.close() }
        let seconds = await transfer(link, bytes: 6_000_000)
        #expect(seconds < 4.5, "\(seconds) s: \(6.0 / seconds) MB/s of 2")
    }
}
