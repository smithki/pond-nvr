import Foundation
import HAP
import Testing
@testable import HAPCamera

@Suite struct StreamManagementTests {
    @Test func setupEndpointsAnswersWithOurAddressPortsAndKeys() throws {
        let streams = StreamManagement(main: ("rtsp://x/main", "u", "p"), sub: ("rtsp://x/sub", "u", "p")) { _ in }
        let session = Array(0 ..< 16 as Range<UInt8>)
        let key = Array(repeating: UInt8(7), count: 16), salt = Array(repeating: UInt8(9), count: 14)
        let address = CameraTLV.item(0x01, 0) + CameraTLV.item(0x02, Array("127.0.0.1".utf8))
            + CameraTLV.item(0x03, LE.bytes16(50000)) + CameraTLV.item(0x04, LE.bytes16(50002))
        let srtp = CameraTLV.item(0x01, 0) + CameraTLV.item(0x02, key) + CameraTLV.item(0x03, salt)
        let request = CameraTLV.item(0x01, session) + CameraTLV.item(0x03, address)
            + CameraTLV.item(0x04, srtp) + CameraTLV.item(0x05, srtp)

        let reply = try TLV8.decode(streams.setupEndpoints(request))
        #expect(reply.value(0x01) == session)
        #expect(reply.value(0x02) == [0])                                   // success
        let ours = try TLV8.decode(try #require(reply.value(0x03)))
        #expect(ours.value(0x02) == Array("127.0.0.1".utf8))               // reached from loopback
        #expect((LE.u16(ours.value(0x03)) ?? 0) > 0)
        let video = try TLV8.decode(try #require(reply.value(0x04)))
        #expect(video.value(0x02) == key && video.value(0x03) == salt)
        #expect(reply.value(0x06)?.count == 4 && reply.value(0x07)?.count == 4)

        // A second setup while none is live is fine; a malformed one gets an error.
        #expect(try TLV8.decode(streams.setupEndpoints(request)).value(0x02) == [0])
        #expect(streams.setupEndpoints([1, 2, 3]) == CameraTLV.item(0x02, 2))
    }
}

@Suite struct StreamChoiceTests {
    @Test func theMainStreamOnlyForALargeViewWithTheBandwidth() {
        let streams = StreamManagement(main: ("rtsp://x/main", "u", "p"), sub: ("rtsp://x/sub", "u", "p")) { _ in }
        #expect(streams.source(width: 1920, maxBitrate: 2000).url == "rtsp://x/main")
        #expect(streams.source(width: 1920, maxBitrate: 800).url == "rtsp://x/sub")
        #expect(streams.source(width: 640, maxBitrate: 2000).url == "rtsp://x/sub")
    }
}

@Suite struct RateControlTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test func lossCutsQuicklyAndCleanRaisesSlowly() {
        var rate = RateControl(bitrate: 1500, at: t0)
        #expect(rate.report(lost: 0.10, at: t0.addingTimeInterval(1)) == 1050)
        #expect(rate.report(lost: 0.10, at: t0.addingTimeInterval(1.5)) == nil)        // not twice within a second
        #expect(rate.report(lost: 0.10, at: t0.addingTimeInterval(2.1)) == 735)
        for s in stride(from: 3.0, to: 10.0, by: 1) { #expect(rate.report(lost: 0, at: t0.addingTimeInterval(s)) == nil) }
        #expect(rate.report(lost: 0, at: t0.addingTimeInterval(11)) == 882)            // 8 s clean
        #expect(rate.report(lost: 0.02, at: t0.addingTimeInterval(12)) == nil)         // a little loss: hold
    }

    @Test func boundsAndAsks() {
        var rate = RateControl(bitrate: 10_000, at: t0)
        #expect(rate.bitrate == RateControl.ceiling)
        var low = RateControl(bitrate: 160, at: t0)
        #expect(low.report(lost: 0.5, at: t0.addingTimeInterval(2)) == RateControl.floor)
        #expect(low.report(lost: 0.5, at: t0.addingTimeInterval(4)) == nil)
        #expect(rate.asked(299) == nil)
        #expect(low.asked(1000, at: t0.addingTimeInterval(5)) == 1000)
    }

    @Test func theSizeAndFrameRateFollowTheRate() {
        #expect(RateControl.target(bitrate: 1500, profile: 1).width == 1280)
        #expect(RateControl.target(bitrate: 2500, profile: 1).height == 1080)
        let thin = RateControl.target(bitrate: 200, profile: 1)
        #expect(thin.width == 480 && thin.fps == 15)
        // The doorbell's 4:3 picture in the 1080p box: 1440×1080.
        #expect(RateControl.target(bitrate: 2500, profile: 1).fitting(width: 2560, height: 1920) == (1440, 1080))
    }
}

@Suite struct ReceptionReportTests {
    @Test func aReceiverReportsLossForOurStream() {
        // RR (PT 201), one block: sender SSRC 0xAA, about SSRC 0x01020304, 64/256 lost, 10 cumulative.
        let rr: [UInt8] = [0x81, 201, 0, 7, 0, 0, 0, 0xAA,
                           1, 2, 3, 4, 64, 0, 0, 10, 0, 0, 0x10, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0]
        let reports = ReceptionReport.parse(rr)
        #expect(reports.count == 1)
        #expect(reports.first?.ssrc == 0x0102_0304)
        #expect(reports.first?.lostShare == 0.25)
        #expect(reports.first?.cumulativeLost == 10)
    }

    @Test func srtcpRoundTrips() {
        let key = [UInt8](repeating: 7, count: 16), salt = [UInt8](repeating: 9, count: 14)
        var sender = SRTPSender(masterKey: key, masterSalt: salt)
        let report = [UInt8]([0x81, 201, 0, 7, 0, 0, 0, 0xAA]) + [UInt8](repeating: 3, count: 24)
        let protected = sender.protect(rtcp: report)
        #expect(SRTCPReceiver(masterKey: key, masterSalt: salt).unprotect(protected) == report)
        var tampered = protected
        tampered[10] ^= 1
        #expect(SRTCPReceiver(masterKey: key, masterSalt: salt).unprotect(tampered) == nil)
    }
}

@Suite struct AudioSettingsTests {
    /// Selected audio as the Home app sends it: AAC-ELD, mono, VBR, 16 kHz, 30 ms; payload type 110,
    /// 24 kbit/s, RTCP every 5 s.
    static let selected: [TLV8Item] = [
        TLV8Item(0x01, [2]),
        TLV8Item(0x02, CameraTLV.item(0x01, 1) + CameraTLV.item(0x02, 0) + CameraTLV.item(0x03, 1) + CameraTLV.item(0x04, 30)),
        TLV8Item(0x03, CameraTLV.item(0x01, 110) + CameraTLV.item(0x02, LE.bytes32(0x1234)) + CameraTLV.item(0x03, LE.bytes16(24))
            + CameraTLV.item(0x04, LE.bytes32(Float(5).bitPattern)) + CameraTLV.item(0x06, 13)),
        TLV8Item(0x04, [0]),
    ]

    @Test func aacELDIsTaken() {
        let audio = StreamManagement.audioSettings(Self.selected, ssrc: 99)
        #expect(audio == LiveSession.Audio(payloadType: 110, ssrc: 99, sampleRate: 16000, maxBitrate: 24, rtcpInterval: 5,
                                           packetTime: 30))
        #expect(audio?.framesPerPacket == 1)
    }

    @Test func framesFillThePacketTime() {
        func frames(_ rate: Int, _ ms: Int) -> Double {
            LiveSession.Audio(payloadType: 110, ssrc: 1, sampleRate: rate, maxBitrate: 24, rtcpInterval: 5, packetTime: ms).framesPerPacket
        }
        #expect(frames(24000, 20) == 1)
        #expect(frames(16000, 30) == 1)
        #expect(frames(16000, 60) == 2)
        #expect(frames(24000, 40) == 2)
        #expect(frames(24000, 60) == 3)
        #expect(frames(24000, 30) == 1.5)
    }

    @Test func otherCodecsAreNot() {
        var opus = Self.selected
        opus[0] = TLV8Item(0x01, [3])
        #expect(StreamManagement.audioSettings(opus, ssrc: 99) == nil)
        #expect(StreamManagement.audioSettings(nil, ssrc: 99) == nil)
    }

    @Test func onlyAACELDIsOffered() throws {
        let items = try TLV8.decode(CameraStreamOptions.standard.supportedAudio)
        let codecs = items.filter { $0.type == 0x01 }
        #expect(codecs.count == 1)
        let codec = try TLV8.decode(codecs[0].value)
        #expect(codec.value(0x01) == [2])
    }
}
