import CryptoKit
import Devices
import Foundation
import Ingest
import NVRCore
import Signal
import Testing
import Watch
@testable import Remote

/// The remote API between two Ponds: one's cameras, events, pictures, clips and controls, asked for by the other.
@Suite(.serialized) struct RemoteAPITests {
    /// The home Pond's world: two cameras (one private), an events folder with an event's picture and clip, and
    /// another's picture pointing outside it.
    final class Home: @unchecked Sendable {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-api-\(UUID().uuidString)")
        let events: EventStore
        let privacy: PrivacyState
        let picture = Data((0 ..< 5000).map { UInt8($0 % 251) })
        // (Over three pieces: two whole, one not.)
        let clip = Data((0 ..< 2_600_000).map { UInt8(($0 * 7) % 256) })
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
        let lock = NSLock()
        var asked: [ControlSocket.Request] = []

        init() throws {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("events/porch"), withIntermediateDirectories: true)
            events = try #require(EventStore(path: folder.appendingPathComponent("pond.sqlite").path))
            privacy = PrivacyState(path: folder.appendingPathComponent("privacy.json").path)
            privacy.set("garden", private: true)
            try picture.write(to: folder.appendingPathComponent("events/porch/one.jpg"))
            try clip.write(to: folder.appendingPathComponent("events/porch/one.mp4"))
            try Data("secret".utf8).write(to: folder.appendingPathComponent("pond.json"))
            events.save(CameraEvent(id: "one", camera: "porch", start: start, end: start + 20, category: .person,
                                    labels: ["person": 2, "dog": 1], snapshot: "events/porch/one.jpg"), ongoing: false)
            events.clipped("one", clip: "events/porch/one.mp4", start: start - 3)
            events.understood("one", .init(description: "Two people walk a dog up the path."))
            events.save(CameraEvent(id: "two", camera: "garden", start: start + 60, end: start + 70, category: .animal,
                                    labels: ["cat": 1], snapshot: "../pond.json"), ongoing: false)
            events.save(CameraEvent(id: "old", camera: "porch", start: start - 86400, end: start - 86390, category: .vehicle), ongoing: false)
            events.flush()
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        func server() -> RemoteAPI.Server {
            let cameras = [
                Config.Camera(id: "porch", name: "Porch", main: "rtsp://porch/main", sub: "rtsp://porch/sub", username: "u", kind: .doorbell,
                              device: .init(manufacturer: "Maker", model: "D1")),
                Config.Camera(id: "garden", name: "Garden", main: "rtsp://garden/main", sub: "", username: "u"),
            ]
            return RemoteAPI.Server(cameras: { cameras }, password: { _ in "p" }, events: events, eventsFolder: { self.folder.path },
                                    control: { request in
                                        self.lock.withLock { self.asked.append(request) }
                                        return ControlSocket.Reply(privateCameras: ["garden"])
                                    }, privacy: privacy, live: LiveSender { _ in })
        }
    }

    /// Two Ponds paired over a signaling server of their own, the home one answering with `server`; the away one
    /// given a session with it.
    func withPair(_ server: RemoteAPI.Server, _ body: (RemoteHost, RemoteClient) async throws -> Void) async throws {
        let signal = SignalServer(port: 0) { _ in }
        try signal.start()
        defer { signal.stop() }
        let url = URL(string: "ws://127.0.0.1:\(signal.boundPort)")!
        let home = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Home", signaling: url) { _ in }
        let away = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Away", signaling: url) { _ in }
        home.start()
        away.start()
        defer { home.stop(); away.stop() }
        let code = try #require(PairingCode(text: home.newCode().text))
        let peer = try #require(await away.join(code))
        for _ in 0 ..< 50 where home.devices().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        home.paths.requests = { await server.serve($0, action: $1, body: $2) }
        home.paths.sessionEnded = { server.ended($0) }
        let (outcome, opened) = await away.paths.open(to: peer)
        let session = try #require(opened, "\(outcome.summary)")
        defer { away.paths.close(session) }
        try await body(away, RemoteClient(session: session))
    }

    /// How asking failed (nil: it didn't).
    func failure(_ work: () async throws(RemoteClient.Failure) -> Void) async -> RemoteClient.Failure? {
        do { try await work() } catch { return error }
        return nil
    }

    @Test func camerasEventsPicturesAndClips() async throws {
        let home = try Home()
        try await withPair(home.server()) { _, client in
            let cameras = try await client.cameras()
            #expect(cameras.map(\.id) == ["porch", "garden"])
            #expect(cameras[0].doorbell && !cameras[0].isPrivate && cameras[0].subStream && cameras[0].model == "D1")
            #expect(cameras[1].isPrivate && !cameras[1].subStream)

            // The last day's, oldest first, with what was seen in words and the sentence.
            let events = try await client.events(.init(since: home.start - 60))
            #expect(events.map(\.id) == ["one", "two"])
            let one = try #require(events.first)
            #expect(one.seen == CameraEvent.words(["person": 2, "dog": 1]))
            #expect(one.sentence == "Two people walk a dog up the path.")
            #expect(one.picture && one.clipBytes == home.clip.count && one.clipStart == home.start - 3)
            #expect(events.last?.clipBytes == nil)
            // One camera's (by its name), the newest few, and by ids.
            #expect(try await client.events(.init(since: home.start - 86400 * 2, camera: "Porch")).map(\.id) == ["old", "one"])
            #expect(try await client.events(.init(since: home.start - 86400 * 2, limit: 1)).map(\.id) == ["two"])
            #expect(try await client.events(.init(ids: ["two", "old", "gone"])).map(\.id) == ["old", "two"])

            // The picture whole, and the clip in pieces (it's longer than one).
            #expect(try await client.picture("one") == home.picture)
            let file = home.folder.appendingPathComponent("away/one.mp4")
            let done = try await client.clip("one", to: file)
            #expect(done.bytes == home.clip.count && done.resumed == 0)
            #expect(try Data(contentsOf: file) == home.clip)
            // Nothing's left beside it.
            #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["one.mp4"])

            // Nothing outside the events folder, even when an event names it; and nothing that isn't there.
            #expect(await failure { () async throws(RemoteClient.Failure) in _ = try await client.picture("two") } == .refused("it has no picture"))
            #expect(await failure { () async throws(RemoteClient.Failure) in _ = try await client.clip("old", to: file) } == .refused("it has no clip (yet)"))
            #expect(await failure { () async throws(RemoteClient.Failure) in _ = try await client.picture("gone") } == .refused("no event gone"))
        }
    }

    @Test func controlsAsTheAppAsksButNotPairingOrSettings() async throws {
        let home = try Home()
        try await withPair(home.server()) { _, client in
            let reply = try await client.control(ControlSocket.Request(camera: "", action: "privacy.list"))
            #expect(reply.privateCameras == ["garden"])
            for action in ["remote.pair", "remote.unpair", "reload", "talk"] {
                let asked = ControlSocket.Request(camera: "porch", action: action)
                #expect(await failure { () async throws(RemoteClient.Failure) in _ = try await client.control(asked) } == .refused("not supported remotely: \(action)"))
            }
            #expect(home.lock.withLock { home.asked.map(\.action) } == ["privacy.list"])
            #expect(await failure { () async throws(RemoteClient.Failure) in _ = try await client.call("settings") } == .refused("not supported: settings"))
            // A private camera's live video isn't sent.
            let garden = try JSONEncoder().encode(LiveRequest(camera: "garden", main: false))
            #expect(await failure { () async throws(RemoteClient.Failure) in _ = try await client.call("live.start", garden) } == .refused("Garden is private"))
        }
    }

    @Test func askedByNameAndNotOfOneThatIsntPaired() async throws {
        let home = try Home()
        try await withPair(home.server()) { away, _ in
            let cameras = try await away.asking("Home") { client throws(RemoteClient.Failure) in try await client.cameras() }
            #expect(cameras.count == 2)
            #expect(await failure { () async throws(RemoteClient.Failure) in _ = try await away.asking("Elsewhere") { client throws(RemoteClient.Failure) in try await client.cameras() } }
                == .noDevice("Elsewhere"))
        }
    }

    @Test func aClipCutOffCarriesOnWhereItGotTo() async throws {
        let home = try Home()
        try await withPair(home.server()) { _, client in
            // What came before it was cut off, kept beside it under its hash's name.
            let hash = SHA256.hash(data: home.clip).map { String(format: "%02x", $0) }.joined()
            let folder = home.folder.appendingPathComponent("away")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try home.clip.prefix(1_500_000).write(to: folder.appendingPathComponent(".one.mp4.\(hash.prefix(16)).partial"))
            let done = try await client.clip("one", to: folder.appendingPathComponent("one.mp4"))
            #expect(done.resumed == 1_500_000 && done.bytes == home.clip.count)
            #expect(try Data(contentsOf: folder.appendingPathComponent("one.mp4")) == home.clip)

            // What came before but wrongly (it doesn't match at the end): thrown away, and fetched from the start.
            try Data(repeating: 9, count: 1000).write(to: folder.appendingPathComponent(".two.mp4.\(hash.prefix(16)).partial"))
            let again = try await client.clip("one", to: folder.appendingPathComponent("two.mp4"))
            #expect(again.resumed == 0)
            #expect(try Data(contentsOf: folder.appendingPathComponent("two.mp4")) == home.clip)
        }
    }

    @Test func aBigClipComesQuickly() async throws {
        let home = try Home()
        // 20 MB, over the loopback (both Ponds on this Mac): seconds, not the minute a piece at a time took.
        let big = Data((0 ..< 20_000_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })
        try big.write(to: home.folder.appendingPathComponent("events/porch/one.mp4"))
        try await withPair(home.server()) { _, client in
            let file = home.folder.appendingPathComponent("away/big.mp4")
            let done = try await client.clip("one", to: file)
            #expect(try Data(contentsOf: file) == big)
            #expect(done.seconds < 5, "\(done.seconds) s")
        }
    }
}
