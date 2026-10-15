import Foundation
import Testing
@testable import Ingest

@Suite(.serialized) struct StreamRelayTests {
    /// A socket path short enough for a local socket, unique to the test.
    func socketPath() -> String { "/tmp/pond-relay-\(UUID().uuidString.prefix(8)).sock" }

    func server(_ connector: FakeConnector, path: String) -> StreamRelayServer {
        let hub = StreamHub { _, _, _ throws(RTSPError) in try connector.connect() }
        return StreamRelayServer(path: path, hub: hub, lookup: { url in
            url == "rtsp://camera/sub" ? ("admin", "secret") : nil
        }, log: { _ in })
    }

    func read(_ source: PacketSource, packets: Int) throws -> [InterleavedPacket] {
        var got: [InterleavedPacket] = []
        let deadline = Date().addingTimeInterval(2)
        while got.count < packets, Date() < deadline {
            if let p = try source.next(timeout: 0.2) { got.append(p) }
        }
        return got
    }

    @Test func viewsShareTheServicesConnection() throws {
        let connector = FakeConnector()
        let path = socketPath()
        let relay = server(connector, path: path)
        #expect(relay.start())
        defer { relay.stop() }
        let a = try #require(try RelaySession.open(path: path, url: "rtsp://camera/sub"))
        let b = try #require(try RelaySession.open(path: path, url: "rtsp://camera/sub"))
        #expect(a.video.encoding == "H264")
        #expect(try read(a, packets: 5).count == 5)
        #expect(try read(b, packets: 5).count == 5)
        #expect(connector.count == 1)
        a.close()
        b.close()
    }

    @Test func noServiceOrNoSuchStreamMeansConnectingDirectly() throws {
        #expect(try RelaySession.open(path: socketPath(), url: "rtsp://camera/sub") == nil)
        let path = socketPath()
        let relay = server(FakeConnector(), path: path)
        #expect(relay.start())
        defer { relay.stop() }
        #expect(try RelaySession.open(path: path, url: "rtsp://elsewhere/sub") == nil)
    }

    @Test func theCamerasErrorsComeThrough() throws {
        let connector = FakeConnector()
        connector.refuse = true
        let path = socketPath()
        let relay = server(connector, path: path)
        #expect(relay.start())
        defer { relay.stop() }
        #expect(throws: RTSPError.transport(.unreachable("refused"))) {
            _ = try RelaySession.open(path: path, url: "rtsp://camera/sub")
        }
    }

    @Test func aCameraFailingMidStreamEndsTheViewsStream() throws {
        let connector = FakeConnector()
        let path = socketPath()
        let relay = server(connector, path: path)
        #expect(relay.start())
        defer { relay.stop() }
        let a = try #require(try RelaySession.open(path: path, url: "rtsp://camera/sub"))
        _ = try read(a, packets: 2)
        connector.cameras[0].fail(.timeout("PLAY"))
        #expect(throws: RTSPError.timeout("PLAY")) {
            for _ in 0 ..< 400 { _ = try a.next(timeout: 0.2) }
        }
    }

    @Test func aViewLeavingFreesTheConnection() throws {
        let connector = FakeConnector()
        let path = socketPath()
        let relay = server(connector, path: path)
        #expect(relay.start())
        defer { relay.stop() }
        let a = try #require(try RelaySession.open(path: path, url: "rtsp://camera/sub"))
        _ = try read(a, packets: 2)
        a.close()
        let deadline = Date().addingTimeInterval(3)
        while connector.cameras.first?.closed != true, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(connector.cameras.first?.closed == true)
    }
}
