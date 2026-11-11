import Foundation
import Testing
@testable import Ingest

/// A camera sending H.264 RTP: a keyframe (SPS, then an IDR slice's first FU-A piece) every `gop` frames,
/// P-slices between, one packet each, numbered in the payload's last byte.
final class FakeH264Camera: PacketSource, @unchecked Sendable {
    let video = SDP("v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n").video!
    let audio: SDP.Media? = nil
    let gop: Int
    private let lock = NSLock()
    private var n = 0

    init(gop: Int = 5) { self.gop = gop }

    static func rtp(_ payload: [UInt8], timestamp: UInt32, sequence: UInt16) -> [UInt8] {
        [0x80, 96, UInt8(sequence >> 8), UInt8(sequence & 0xFF),
         UInt8(timestamp >> 24), UInt8(timestamp >> 16 & 0xFF), UInt8(timestamp >> 8 & 0xFF), UInt8(timestamp & 0xFF),
         0, 0, 0, 1] + payload
    }

    func next(timeout: Double) throws(RTSPError) -> InterleavedPacket? {
        Thread.sleep(forTimeInterval: 0.005)
        let i = lock.withLock { () -> Int in
            defer { n += 1 }
            return n
        }
        let frame = i / 2, keyframe = frame % gop == 0
        let payload: [UInt8]
        if keyframe {
            payload = i % 2 == 0 ? [0x67, UInt8(i & 0xFF)] : [0x7C, 0x85, UInt8(i & 0xFF)]   // SPS; FU-A start of IDR
        } else {
            payload = [0x41, UInt8(i & 0xFF)]                                                 // P-slice
        }
        return InterleavedPacket(channel: 0, data: Self.rtp(payload, timestamp: UInt32(frame) * 3000, sequence: UInt16(i)))
    }

    func close() {}
}

@Suite(.serialized) struct StreamReplayTests {
    func hub(_ camera: FakeH264Camera) -> StreamHub {
        StreamHub { _, _, _ throws(RTSPError) in camera }
    }

    func read(_ source: PacketSource, packets: Int) throws -> [InterleavedPacket] {
        var got: [InterleavedPacket] = []
        let deadline = Date().addingTimeInterval(3)
        while got.count < packets, Date() < deadline {
            if let p = try source.next(timeout: 0.2) { got.append(p) }
        }
        return got
    }

    @Test func aLateReaderStartsAtTheLatestKeyframe() throws {
        let hub = hub(FakeH264Camera(gop: 5))
        let first = try hub.open(url: "rtsp://cam/sub", username: "u", password: "p")
        _ = try read(first, packets: 13)   // into the second group of pictures
        let late = try hub.open(url: "rtsp://cam/sub", username: "u", password: "p", replay: true)
        let got = try read(late, packets: 4)
        let firstPacket = try #require(got.first)
        #expect(firstPacket.replayed)
        #expect(try #require(RTPPacket(firstPacket.data)).startsH264Keyframe)
        first.close()
        late.close()
    }

    @Test func withoutReplayNothingFromBefore() throws {
        let hub = hub(FakeH264Camera(gop: 5))
        let first = try hub.open(url: "rtsp://cam/sub", username: "u", password: "p")
        _ = try read(first, packets: 13)
        let recorder = try hub.open(url: "rtsp://cam/sub", username: "u", password: "p")
        #expect(try read(recorder, packets: 6).allSatisfy { !$0.replayed })
        first.close()
        recorder.close()
    }

    // (The relay and the stream keeper are the Mac's.)
    #if canImport(Darwin)
    @Test func theRelayCarriesReplayedPackets() throws {
        let camera = FakeH264Camera(gop: 5)
        let hub = hub(camera)
        let first = try hub.open(url: "rtsp://cam/sub", username: "u", password: "p")
        _ = try read(first, packets: 13)
        let path = "/tmp/pond-replay-\(UUID().uuidString.prefix(8)).sock"
        let relay = StreamRelayServer(path: path, hub: hub, lookup: { _ in ("u", "p") }, log: { _ in })
        #expect(relay.start())
        defer { relay.stop() }
        let view = try #require(try RelaySession.open(path: path, url: "rtsp://cam/sub"))
        let got = try read(view, packets: 4)
        #expect(got.first?.replayed == true)
        #expect(got.first?.channel == 0)
        view.close()
        first.close()
    }

    @Test func aKeptStreamGivesTheFirstViewerAReplay() throws {
        let hub = hub(FakeH264Camera(gop: 5))
        let keeper = StreamKeeper(url: "rtsp://cam/sub", username: "u", password: "p", hub: hub)
        keeper.start()
        defer { keeper.stop() }
        Thread.sleep(forTimeInterval: 0.2)   // into the stream, past a keyframe
        #expect(hub.readers(of: "rtsp://cam/sub") == 1)
        let viewer = try hub.open(url: "rtsp://cam/sub", username: "u", password: "p", replay: true)
        let got = try read(viewer, packets: 2)
        #expect(got.first?.replayed == true)
        viewer.close()
    }
    #endif

    @Test func keyframesAreRecognisedHoweverPacked() {
        func starts(_ payload: [UInt8]) -> Bool { RTPPacket(FakeH264Camera.rtp(payload, timestamp: 0, sequence: 0))!.startsH264Keyframe }
        #expect(starts([0x67, 1]))                         // SPS
        #expect(starts([0x65, 1]))                         // a whole IDR slice
        #expect(starts([0x7C, 0x85, 1]))                   // FU-A, first piece of an IDR slice
        #expect(!starts([0x7C, 0x45, 1]))                  // FU-A, a later piece
        #expect(starts([0x78, 0, 2, 0x67, 1, 0, 2, 0x68, 1]))   // STAP-A with SPS and PPS
        #expect(!starts([0x41, 1]))                        // P-slice
    }
}
