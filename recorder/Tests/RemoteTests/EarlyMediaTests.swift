import Foundation
import PondProtocol
import Testing
import Traversal
@testable import Remote

/// A stream's first packets can arrive before its viewer knows its SSRC (they're sent as live.start is answered): the
/// session keeps them a moment and hands them to the stream's route, first, when it's set.
@Suite struct EarlyMediaTests {
    final class NoNetwork: PacketTransport, @unchecked Sendable {
        let port: UInt16 = 0
        func send(_ bytes: [UInt8], to: STUNAddress) {}
        func receive(_ handler: @escaping @Sendable ([UInt8], STUNAddress) -> Void) {}
        func close() {}
    }

    final class Taken: @unchecked Sendable {
        let lock = NSLock()
        var sequences: [UInt8] = []
    }

    func session() -> PathSessions.Session {
        let peer = RemotePeer(name: "Away", signingKey: Data(), agreementKey: Data(), mailbox: "")
        return PathSessions.Session(id: UUID(), peer: peer, finder: PathFinder(role: .controlling, transport: NoNetwork()), port: 0)
    }

    /// An RTP packet of `ssrc`, its sequence number's low byte `n`.
    func rtp(_ ssrc: UInt32, _ n: UInt8) -> [UInt8] {
        [0x80, 99, 0, n, 0, 0, 0, 0, UInt8(ssrc >> 24), UInt8(ssrc >> 16 & 0xFF), UInt8(ssrc >> 8 & 0xFF), UInt8(ssrc & 0xFF), 0]
    }

    @Test func whatCameBeforeTheRouteIsTakenFirstInOrder() {
        let session = session(), taken = Taken()
        for n in UInt8(1) ... 3 { session.deliver(rtp(7, n)) }
        session.deliver(rtp(8, 1))   // another stream's: not handed to this one
        session.route(7) { bytes in taken.lock.withLock { taken.sequences.append(bytes[3]) } }
        session.deliver(rtp(7, 4))
        #expect(taken.lock.withLock { taken.sequences } == [1, 2, 3, 4])
        session.deliver(rtp(7, 5))
        #expect(taken.lock.withLock { taken.sequences } == [1, 2, 3, 4, 5])
    }

    @Test func whatsTooOldIsNotHandedOver() {
        let session = session(), start = Date()
        _ = session.taker(of: rtp(7, 1), now: start)
        session.route(7) { _ in }
        let later = start.addingTimeInterval(PathSessions.Session.earlyFor + 1)
        #expect(session.taker(of: rtp(7, 2), now: later)?.earlier.isEmpty == true)
    }

    @Test func itKeepsNoMoreThanItsLimit() {
        let session = session(), taken = Taken()
        for n in 0 ..< PathSessions.Session.earlyLimit + 50 { session.deliver(rtp(7, UInt8(n & 0xFF))) }
        session.route(7) { bytes in taken.lock.withLock { taken.sequences.append(bytes[3]) } }
        session.deliver(rtp(7, 0))
        #expect(taken.lock.withLock { taken.sequences.count } == PathSessions.Session.earlyLimit + 1)
    }
}
