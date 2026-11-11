import Foundation
import Synchronization
import Testing
@testable import HAPCamera

@Suite struct PacedSenderTests {
    @Test func sendsInTimeOrderWhenDue() async throws {
        let pacer = PacedSender()
        defer { pacer.stop() }
        let sent = Mutex<[(Int, Double)]>([])
        let start = PacedSender.now
        // Out of order as handed over: sent by their times.
        for (i, after) in [(2, 0.2), (1, 0.1), (0, 0.0), (3, 0.3)] {
            pacer.enqueue(at: start + after) { sent.withLock { $0.append((i, PacedSender.now - start)) } }
        }
        try await Task.sleep(for: .milliseconds(500))
        let got = sent.withLock { $0 }
        #expect(got.map(\.0) == [0, 1, 2, 3])
        for (i, at) in got { #expect(at >= Double(i) * 0.1 - 0.001 && at < Double(i) * 0.1 + 0.08) }
    }

    @Test func stoppedDropsWhatsWaiting() async throws {
        let pacer = PacedSender()
        let sent = Mutex(0)
        pacer.enqueue(at: PacedSender.now + 0.2) { sent.withLock { $0 += 1 } }
        pacer.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(sent.withLock { $0 } == 0)
    }
}
