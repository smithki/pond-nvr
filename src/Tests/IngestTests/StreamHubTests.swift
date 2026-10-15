import Foundation
import Testing
@testable import Ingest

/// A camera connection that sends a numbered packet every 10 ms until closed, or fails when told to.
final class FakeCamera: PacketSource, @unchecked Sendable {
    let video = SDP("v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n").video!
    let audio: SDP.Media? = nil
    private let lock = NSLock()
    private var n: UInt8 = 0
    private var failWith: RTSPError?
    private(set) var closed = false

    func next(timeout: Double) throws(RTSPError) -> InterleavedPacket? {
        Thread.sleep(forTimeInterval: 0.01)
        let (failure, value) = lock.withLock { () -> (RTSPError?, UInt8) in
            n &+= 1
            return (failWith, n)
        }
        if let failure { throw failure }
        return InterleavedPacket(channel: 0, data: [value])
    }

    func fail(_ error: RTSPError) { lock.withLock { failWith = error } }
    func close() { lock.withLock { closed = true } }
}

/// Counts connections and hands out fake cameras (or refuses).
final class FakeConnector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var cameras: [FakeCamera] = []
    var refuse = false

    func connect() throws(RTSPError) -> PacketSource {
        lock.lock()
        defer { lock.unlock() }
        if refuse { throw .transport(.unreachable("refused")) }
        let c = FakeCamera()
        cameras.append(c)
        return c
    }
    var count: Int { lock.withLock { cameras.count } }
}

@Suite struct StreamHubTests {
    func hub(_ connector: FakeConnector) -> StreamHub {
        StreamHub { _, _, _ throws(RTSPError) in try connector.connect() }
    }

    func read(_ source: PacketSource, packets: Int) throws -> [InterleavedPacket] {
        var got: [InterleavedPacket] = []
        let deadline = Date().addingTimeInterval(2)
        while got.count < packets, Date() < deadline {
            if let p = try source.next(timeout: 0.2) { got.append(p) }
        }
        return got
    }

    @Test func readersShareOneConnection() throws {
        let connector = FakeConnector()
        let hub = hub(connector)
        let a = try hub.open(url: "rtsp://cam/main", username: "u", password: "p")
        let b = try hub.open(url: "rtsp://cam/main", username: "u", password: "p")
        #expect(connector.count == 1)
        #expect(hub.readers(of: "rtsp://cam/main") == 2)
        #expect(try read(a, packets: 5).count == 5)
        #expect(try read(b, packets: 5).count == 5)
        a.close()
        b.close()
    }

    @Test func eachStreamHasItsOwnConnection() throws {
        let connector = FakeConnector()
        let hub = hub(connector)
        let main = try hub.open(url: "rtsp://cam/main", username: "u", password: "p")
        let sub = try hub.open(url: "rtsp://cam/sub", username: "u", password: "p")
        #expect(connector.count == 2)
        main.close()
        sub.close()
    }

    @Test func theLastReaderHangsUp() throws {
        let connector = FakeConnector()
        let hub = hub(connector)
        let a = try hub.open(url: "rtsp://cam/main", username: "u", password: "p")
        _ = try read(a, packets: 2)
        a.close()
        let deadline = Date().addingTimeInterval(2)
        while connector.cameras.first?.closed != true, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(connector.cameras.first?.closed == true)
        // Opening again connects again.
        let b = try hub.open(url: "rtsp://cam/main", username: "u", password: "p")
        #expect(connector.count == 2)
        #expect(try read(b, packets: 2).count == 2)
        b.close()
    }

    @Test func aDroppedCameraIsReportedToEveryReader() throws {
        let connector = FakeConnector()
        let hub = hub(connector)
        let a = try hub.open(url: "rtsp://cam/main", username: "u", password: "p")
        let b = try hub.open(url: "rtsp://cam/main", username: "u", password: "p")
        _ = try read(a, packets: 2)
        connector.cameras[0].fail(.transport(.closed))
        for reader in [a, b] {
            #expect(throws: RTSPError.self) {
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline { _ = try reader.next(timeout: 0.1) }
            }
        }
        let c = try hub.open(url: "rtsp://cam/main", username: "u", password: "p")
        #expect(connector.count == 2)
        c.close()
    }

    @Test func aRefusedConnectionIsTriedAgainNextTime() throws {
        let connector = FakeConnector()
        connector.refuse = true
        let hub = hub(connector)
        #expect(throws: RTSPError.self) { try hub.open(url: "rtsp://cam/main", username: "u", password: "p") }
        connector.refuse = false
        let a = try hub.open(url: "rtsp://cam/main", username: "u", password: "p")
        #expect(try read(a, packets: 2).count == 2)
        a.close()
    }
}
