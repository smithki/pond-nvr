import Foundation
import Testing
@testable import PondCore

@Suite struct VideoMeterTests {
    /// An RTP packet: its sequence number and timestamp, and an H.264 payload starting with `nal`.
    static func rtp(_ sequence: UInt16, _ timestamp: UInt32, nal: [UInt8] = [0x41, 0x9A]) -> [UInt8] {
        [0x80, 96, UInt8(sequence >> 8), UInt8(sequence & 0xFF),
         UInt8(timestamp >> 24), UInt8(timestamp >> 16 & 0xFF), UInt8(timestamp >> 8 & 0xFF), UInt8(timestamp & 0xFF),
         0, 0, 0, 1] + nal
    }

    @Test func framesLossAndKeyframes() throws {
        var meter = VideoMeter(camera: "porch")
        let t0 = HealthSample.bucket(Date()).addingTimeInterval(10)
        _ = meter.add(channel: 0, data: Self.rtp(1, 1000, nal: [0x65, 0x88]), at: t0)            // an IDR
        _ = meter.add(channel: 0, data: Self.rtp(2, 1000), at: t0.addingTimeInterval(0.01))
        _ = meter.add(channel: 0, data: Self.rtp(5, 4000), at: t0.addingTimeInterval(0.1))       // 3 and 4 lost
        _ = meter.add(channel: 0, data: Self.rtp(6, 7000, nal: [0x7C, 0x85]), at: t0.addingTimeInterval(0.2))   // FU-A IDR start
        let finished = meter.finish()
        let sample = try #require(finished)
        #expect(sample.received == 4 && sample.lost == 2)
        #expect(sample.frames == 3 && sample.keyframes == 2)
        #expect(abs(sample.flowing - 0.2) < 0.001)
    }

    @Test func aSampleIsHandedOverEachFiveMinutes() {
        var meter = VideoMeter(camera: "porch")
        let start = HealthSample.bucket(Date())
        #expect(meter.add(channel: 0, data: Self.rtp(1, 0), at: start.addingTimeInterval(299)) == nil)
        let done = meter.add(channel: 0, data: Self.rtp(2, 3000), at: start.addingTimeInterval(301))
        #expect(done?.start == start && done?.received == 1)
    }

    @Test func theCamerasClockFromASenderReport() {
        // NTP seconds for 2026-01-01 00:00:00 UTC, the report's other fields zero.
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let ntp = UInt32(1_767_225_600 + 2_208_988_800 + 90)
        let report: [UInt8] = [0x80, 200, 0, 6, 0, 0, 0, 1,
                               UInt8(ntp >> 24), UInt8(ntp >> 16 & 0xFF), UInt8(ntp >> 8 & 0xFF), UInt8(ntp & 0xFF),
                               0, 0, 0, 0] + [UInt8](repeating: 0, count: 12)
        #expect(abs((VideoMeter.clockOffset(rtcp: report, now: now) ?? 0) - 90) < 0.01)
    }
}

@Suite struct HealthDiagnosisTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ minutesAgo: Double, _ camera: String, _ kind: HealthIncident.Kind) -> HealthIncident {
        HealthIncident(camera: camera, time: now.addingTimeInterval(-minutesAgo * 60), kind: kind)
    }

    @Test func stallsInAnHourAreUnstableVideo() {
        let incidents = [Self.at(50, "porch", .stalled), Self.at(30, "porch", .stalled), Self.at(5, "porch", .stalled)]
        let found = HealthDiagnosis.findings(camera: "porch", incidents: incidents, samples: [], now: Self.now)
        #expect(found.map(\.kind) == [.unstableVideo])
        #expect(found[0].severity == .problem && found[0].marksTile)
        #expect(found[0].since == Self.now.addingTimeInterval(-50 * 60))
        // Two aren't enough; old ones don't count.
        #expect(HealthDiagnosis.findings(camera: "porch", incidents: Array(incidents.suffix(2)) + [Self.at(90, "porch", .stalled)],
                                         samples: [], now: Self.now).isEmpty)
    }

    @Test func everyCameraGoingAtOnceIsThisMacsNetwork() {
        var incidents: [HealthIncident] = []
        for minutes in [40.0, 20, 10] {
            incidents += [Self.at(minutes, "porch", .unreachable), Self.at(minutes - 0.1, "garden", .unreachable)]
        }
        let found = HealthDiagnosis.findings(camera: "porch", incidents: incidents, samples: [], now: Self.now)
        // Not the camera's: a notice, not on its tile.
        #expect(found.map(\.kind) == [.macNetwork])
        #expect(!found[0].marksTile)
        // Connected again since: over, so nothing to say.
        #expect(HealthDiagnosis.findings(camera: "porch", incidents: incidents + [Self.at(9, "porch", .connected)],
                                         samples: [], now: Self.now).isEmpty)
        // The same, the porch alone: it drops off.
        let alone = incidents.filter { $0.camera == "porch" } + [Self.at(5, "garden", .connected)]
        #expect(HealthDiagnosis.findings(camera: "porch", incidents: alone, samples: [], now: Self.now).map(\.kind) == [.dropsOff])
    }

    @Test func videoThatDidntComeBackAfterPrivacyIsAProblemUntilItDoes() {
        let incidents = [Self.at(10, "porch", .madePublic), Self.at(9, "porch", .wakeFailed),
                         Self.at(9, "porch", .unreachable)]
        let found = HealthDiagnosis.findings(camera: "porch", incidents: incidents, samples: [], now: Self.now)
        #expect(found.first?.kind == .didntWake && found.first?.marksTile == true)
        // Its video came back (restarted), or it's private again: over.
        for after in [HealthIncident.Kind.connected, .madePrivate] {
            #expect(!HealthDiagnosis.findings(camera: "porch", incidents: incidents + [Self.at(2, "porch", after)], samples: [], now: Self.now)
                .contains { $0.kind == .didntWake })
        }
    }

    @Test func unreachableJustAfterTheServiceStartsIsntTheCameras() {
        let incidents = [Self.at(30, "", .serviceStarted), Self.at(29.8, "porch", .unreachable),
                         Self.at(20, "", .serviceStarted), Self.at(19.8, "porch", .unreachable),
                         Self.at(10, "", .serviceStarted), Self.at(9.8, "porch", .unreachable)]
        #expect(!HealthDiagnosis.findings(camera: "porch", incidents: incidents, samples: [], now: Self.now).contains { $0.kind == .dropsOff })
    }

    @Test func oneCameraUnreachableAsTheServiceStartsWhileTheOthersConnectIsThatCameras() {
        // Each time the service started, the garden connected and the porch didn't: the porch's, not this Mac's.
        var incidents: [HealthIncident] = []
        for minutes in [40.0, 25, 10] {
            incidents += [Self.at(minutes, "", .serviceStarted), Self.at(minutes - 0.2, "porch", .unreachable),
                          Self.at(minutes - 0.2, "garden", .connected)]
        }
        let found = HealthDiagnosis.findings(camera: "porch", incidents: incidents, samples: [], now: Self.now).map(\.kind)
        #expect(!found.contains(.macNetwork))
        #expect(found.contains(.dropsOff))
        // Both unreachable as it started: this Mac's network, as before.
        let both = incidents.filter { $0.kind != .connected } + [40.0, 25, 10].map { Self.at($0 - 0.2, "garden", .unreachable) }
        #expect(HealthDiagnosis.findings(camera: "porch", incidents: both, samples: [], now: Self.now).map(\.kind) == [.macNetwork])
    }

    static func sample(_ minutesAgo: Double, _ edit: (inout HealthSample) -> Void) -> HealthSample {
        var sample = HealthSample(camera: "porch", start: now.addingTimeInterval(-minutesAgo * 60))
        edit(&sample)
        return sample
    }

    @Test func lostPacketsAndFarKeyframesAreWarningsWithAFix() {
        let samples = (0 ..< 12).map { i in
            Self.sample(Double(i) * 5) { $0.flowing = 300; $0.received = 9000; $0.lost = 200; $0.frames = 4500; $0.keyframes = 30 }
        }
        let found = HealthDiagnosis.findings(camera: "porch", incidents: [], samples: samples, now: Self.now, app: "the Reolink app")
        #expect(Set(found.map(\.kind)) == [.packetLoss, .keyframesFarApart])
        #expect(found.allSatisfy { $0.severity == .warning && $0.fix != nil && $0.marksTile })
        #expect(found.first { $0.kind == .keyframesFarApart }?.fix?.contains("the Reolink app") == true)
    }

    @Test func aClockOffBySecondsIsSaidButNotOneThatNeverKnewTheTime() {
        let off = HealthDiagnosis.findings(camera: "porch", incidents: [], samples: [Self.sample(5) { $0.clockOffset = 125 }], now: Self.now)
        #expect(off.map(\.kind) == [.clockOff])
        #expect(off[0].evidence == "2 min ahead of this Mac")
        // Years off: it sends no real time at all.
        #expect(HealthDiagnosis.findings(camera: "porch", incidents: [], samples: [Self.sample(5) { $0.clockOffset = -1e9 }],
                                         now: Self.now).isEmpty)
    }

    @Test func privacyIsNeverAProblem() {
        let found = HealthDiagnosis.findings(camera: "porch", incidents: [Self.at(60 * 30, "porch", .madePrivate)], samples: [], now: Self.now)
        #expect(found.map(\.kind) == [.longPrivate])
        #expect(found[0].severity == .notice)
        #expect(HealthDiagnosis.findings(camera: "porch", incidents: [Self.at(60 * 30, "porch", .madePrivate), Self.at(60, "porch", .madePublic)],
                                         samples: [], now: Self.now).isEmpty)
    }

    @Test func aRefusedLoginHoldsUntilItConnects() {
        #expect(HealthDiagnosis.findings(camera: "porch", incidents: [Self.at(10, "porch", .loginRefused)], samples: [], now: Self.now)
            .map(\.kind) == [.loginRefused])
        #expect(HealthDiagnosis.findings(camera: "porch", incidents: [Self.at(10, "porch", .loginRefused), Self.at(5, "porch", .connected)],
                                         samples: [], now: Self.now).isEmpty)
    }
}
