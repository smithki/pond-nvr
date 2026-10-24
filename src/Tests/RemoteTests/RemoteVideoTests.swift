import AVFoundation
import Foundation
import HAPCamera
import Ingest
import NVRCore
import Signal
import Testing
@testable import Remote

/// Live video between two Ponds over a session: a made-up camera's stream sent by one, watched by the other.
@Suite(.serialized) struct RemoteVideoTests {
    /// A camera that plays a test pattern (160×120 H.264, 10 fps, a keyframe every 2 s) as RTP, over and over.
    final class Camera: PacketSource, @unchecked Sendable {
        let video: SDP.Media
        let audio: SDP.Media? = nil
        let frames: [[[UInt8]]]
        var packets: [[UInt8]] = []
        var packetizer = RTPPacketizer(payloadType: 96, ssrc: 0x1234, maxPayload: 1400)
        var frame = 0
        var next = Date()
        let lock = NSLock()

        init() throws {
            // The HomeKit tests' fixture: its SPS, PPS and frames (one slice each).
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("HAPCameraTests/Fixtures/in-order.h264")
            let bytes = [UInt8](try Data(contentsOf: fixture))
            var nalus: [[UInt8]] = []
            var start: Int?
            var i = 0
            while i + 2 < bytes.count {
                if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                    if let s = start { nalus.append(Array(bytes[s ..< (bytes[i - 1] == 0 && i - 1 > s ? i - 1 : i)])) }
                    start = i + 3
                    i += 3
                } else {
                    i += 1
                }
            }
            if let s = start { nalus.append(Array(bytes[s...])) }
            let sps = nalus.first { $0[0] & 0x1F == 7 }!, pps = nalus.first { $0[0] & 0x1F == 8 }!
            frames = nalus.filter { [1, 5].contains($0[0] & 0x1F) }.map { $0[0] & 0x1F == 5 ? [sps, pps, $0] : [$0] }
            let sprop = Data(sps).base64EncodedString() + "," + Data(pps).base64EncodedString()
            video = SDP("v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 sprop-parameter-sets=\(sprop)\r\n").video!
        }

        func next(timeout: Double) throws(RTSPError) -> InterleavedPacket? {
            lock.lock()
            if packets.isEmpty {
                let wait = next.timeIntervalSinceNow
                lock.unlock()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                lock.lock()
                packets = packetizer.packetize(frames[frame % frames.count], timestamp: UInt32(truncatingIfNeeded: frame * 9000))
                frame += 1
                next = Date().addingTimeInterval(0.1)
            }
            let packet = packets.removeFirst()
            lock.unlock()
            return InterleavedPacket(channel: CameraSession.videoChannel, data: packet)
        }

        func close() {}
    }

    @Test func aCamerasStreamWatchedFromAnotherPond() async throws {
        let server = SignalServer(port: 0) { _ in }
        try server.start()
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

        // The home Pond: its one (made-up) camera, sent to whoever asks.
        let camera = try Camera()
        let sender = LiveSender(hub: StreamHub { _, _, _ in camera }) { _ in }
        home.paths.requests = { session, action, body in
            switch action {
            case "live.start":
                guard let body, let request = try? JSONDecoder().decode(LiveRequest.self, from: body), request.camera == "porch",
                      let answer = sender.start(session, source: ("rtsp://porch/main", "u", "p")) else { return (nil, "no such camera") }
                return (try? JSONEncoder().encode(answer), nil)
            case "live.stop":
                sender.stop(session)
                return (nil, nil)
            default:
                return (nil, "not supported: \(action)")
            }
        }

        let (outcome, opened) = await away.paths.open(to: peer)
        let session = try #require(opened, "\(outcome.summary)")
        defer { away.paths.close(session) }
        #expect(await session.ask("live.start", try JSONEncoder().encode(LiveRequest(camera: "nowhere", main: true)))?.error == "no such camera")
        let reply = try #require(await session.ask("live.start", try JSONEncoder().encode(LiveRequest(camera: "porch", main: true))))
        let answer = try JSONDecoder().decode(LiveAnswer.self, from: try #require(reply.body))
        let viewer = try #require(LiveViewer(session: session, answer: answer))
        defer { viewer.stop() }
        final class Seen: @unchecked Sendable { let lock = NSLock(); var keyframeWithParameterSets = false }
        let seen = Seen()
        viewer.picture = { nalus, keyframe, _ in
            if keyframe, nalus.count >= 3, nalus[0][0] & 0x1F == 7, nalus[1][0] & 0x1F == 8 {
                seen.lock.withLock { seen.keyframeWithParameterSets = true }
            }
        }
        // Three seconds of it: about 30 pictures, from its first keyframe on.
        try await Task.sleep(for: .seconds(3))
        let counts = viewer.received
        #expect(counts.pictures >= 15, "\(counts)")
        #expect(counts.keyframes >= 1 && seen.lock.withLock { seen.keyframeWithParameterSets })
        #expect(counts.lost == 0)
        #expect(sender.sending == 1)

        // Stopped when asked.
        #expect(await session.ask("live.stop")?.error == nil)
        for _ in 0 ..< 50 where sender.sending > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(sender.sending == 0)
        let after = viewer.received.pictures
        try await Task.sleep(for: .seconds(0.5))
        #expect(viewer.received.pictures <= after + 1)
    }

    @Test func watchingKeepsAPlayableFile() async throws {
        let server = SignalServer(port: 0) { _ in }
        try server.start()
        defer { server.stop() }
        let url = URL(string: "ws://127.0.0.1:\(server.boundPort)")!
        let home = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Home", signaling: url) { _ in }
        let away = try RemoteHost(keys: RemoteKeys(store: MemoryCredentialStore()), name: "Away", signaling: url) { _ in }
        home.start()
        away.start()
        defer { home.stop(); away.stop() }
        let code = try #require(PairingCode(text: home.newCode().text))
        _ = try #require(await away.join(code))
        for _ in 0 ..< 50 where home.devices().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let camera = try Camera()
        let sender = LiveSender(hub: StreamHub { _, _, _ in camera }) { _ in }
        home.paths.requests = { session, action, _ in
            action == "live.start" ? ((sender.start(session, source: ("rtsp://porch", "u", "p"))).flatMap { try? JSONEncoder().encode($0) }, nil)
                : (nil, nil)
        }
        home.paths.sessionEnded = { sender.stop($0) }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await away.watch(device: "Home", camera: "porch", main: false, seconds: 2, file: file)
        #expect(result.problem == nil && result.counts.pictures >= 10, "\(result.summary)")
        #expect(result.summary.contains("none lost"))
        // The file plays: a video track at the camera's size, over a second long.
        let asset = AVURLAsset(url: try #require(result.file))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 160, height: 120))
        #expect(try await asset.load(.duration).seconds > 1)
        // And the session's end stopped the stream.
        for _ in 0 ..< 50 where sender.sending > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(sender.sending == 0)
    }

    @Test func aWeakLinkGetsItReencodedSmaller() async throws {
        let server = SignalServer(port: 0) { _ in }
        try server.start()
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
        let camera = try Camera()
        let sender = LiveSender(hub: StreamHub { _, _, _ in camera }) { _ in }
        home.paths.requests = { session, _, body in
            let ask = body.flatMap { try? JSONDecoder().decode(LiveRequest.self, from: $0) }
            return (sender.start(session, source: ("rtsp://porch", "u", "p"), reencode: ask?.reencode).flatMap { try? JSONEncoder().encode($0) }, nil)
        }

        let (outcome, opened) = await away.paths.open(to: peer)
        let session = try #require(opened, "\(outcome.summary)")
        defer { away.paths.close(session) }
        let small = LiveRequest(camera: "porch", main: true, reencode: .init(width: 80, height: 60, kbps: 100, fps: 10))
        let body = try #require(await session.ask("live.start", try JSONEncoder().encode(small))?.body)
        let viewer = try #require(LiveViewer(session: session, answer: try JSONDecoder().decode(LiveAnswer.self, from: body)))
        defer { viewer.stop() }
        final class Size: @unchecked Sendable { let lock = NSLock(); var seen: (Int, Int)? }
        let size = Size()
        viewer.picture = { nalus, keyframe, _ in
            if keyframe, let sps = nalus.first, let info = H264SPS(nal: sps) { size.lock.withLock { size.seen = (info.width, info.height) } }
        }
        try await Task.sleep(for: .seconds(3))
        #expect(viewer.received.pictures >= 10, "\(viewer.received)")
        // Encoded again at the size asked for (the camera's is 160×120).
        let seen = size.lock.withLock { size.seen }
        #expect(seen?.0 == 80 && seen?.1 == 60, "\(String(describing: seen))")
    }
}
