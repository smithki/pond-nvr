import Foundation
import Testing
@testable import PondCore

@Suite struct RecordingGapsTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    static func span(_ a: Double, _ b: Double) -> ClosedRange<Date> { at(a) ... at(b) }
    static func incident(_ minutes: Double, _ kind: HealthIncident.Kind, _ camera: String = "", _ detail: String? = nil) -> HealthIncident {
        HealthIncident(camera: camera, time: at(minutes), kind: kind, detail: detail)
    }

    func gaps(_ incidents: [HealthIncident], coverage: [ClosedRange<Date>] = [span(0, 60), span(120, 180)],
              through: Date? = nil, privateSpans: [ClosedRange<Date>] = []) -> [RecordingGap] {
        RecordingGaps.find(camera: "door", coverage: coverage, through: through, privateSpans: privateSpans, incidents: incidents)
    }

    @Test func aShortGapIsntSaid() {
        #expect(gaps([], coverage: [Self.span(0, 60), Self.span(61, 90)]).isEmpty)
    }

    @Test func aGapWithNothingRecordedHasNoReason() throws {
        let found = gaps([])
        #expect(found.count == 1)
        #expect(found.first?.range == Self.span(60, 120))
        #expect(found.first?.reason == .unknown)
        #expect(found.first?.sentence == "Not recorded.")
    }

    @Test func theMacAsleep() {
        let found = gaps([Self.incident(59.9, .macSleeping), Self.incident(119, .macWoke)])
        #expect(found.first?.reason == .macAsleep)
        #expect(found.first?.sentence == "Not recorded: this Mac was asleep.")
    }

    @Test func theMacRestartedOutweighsTheRecorderStopping() {
        // Shut down: the recorder stopped as it did, and the Mac started again within the gap.
        let found = gaps([Self.incident(60, .serviceStopped), Self.incident(110, .macStarted), Self.incident(111, .serviceStarted)])
        #expect(found.first?.reason == .macOff)
    }

    @Test func theRecorderStopped() {
        #expect(gaps([Self.incident(60, .serviceStopped), Self.incident(119, .serviceStarted)]).first?.reason == .recorderStopped)
    }

    @Test func theRecorderStartingAgainWithNoStopIsItNotRunning() {
        #expect(gaps([Self.incident(119, .serviceStarted)]).first?.reason == .recorderNotRunning)
    }

    @Test func theDriveSaysWhy() {
        let found = gaps([Self.incident(60, .storageFailed, "door", "the recordings drive was full"), Self.incident(120, .storageBack, "door")])
        #expect(found.first?.reason == .storage("the recordings drive was full"))
        #expect(found.first?.sentence == "Not recorded: the recordings drive was full.")
        // Another camera's: the drive is shared.
        #expect(gaps([Self.incident(60, .storageFailed, "yard", "the recordings drive wasn\u{2019}t there")]).first?.reason
            == .storage("the recordings drive wasn\u{2019}t there"))
    }

    @Test func whatTheCameraDidAsItBegan() {
        #expect(gaps([Self.incident(60.2, .unreachable, "door")]).first?.reason == .unreachable)
        #expect(gaps([Self.incident(60.2, .loginRefused, "door")]).first?.reason == .loginRefused)
        #expect(gaps([Self.incident(60.1, .stalled, "door")]).first?.reason == .videoStopped)
        #expect(gaps([Self.incident(60.5, .privacyMode, "door")]).first?.reason == .privacyMode)
        // Long before it began: not its cause.
        #expect(gaps([Self.incident(20, .unreachable, "door")]).first?.reason == .unknown)
        // Another camera's trouble isn't this one's.
        #expect(gaps([Self.incident(60.2, .unreachable, "yard")]).first?.reason == .unknown)
    }

    @Test func everyCameraUnreachableAtOnceIsTheMacsNetwork() {
        let found = RecordingGaps.find(camera: "door", coverage: [Self.span(0, 60), Self.span(120, 180)],
                                       incidents: [Self.incident(60.2, .unreachable, "door"), Self.incident(60.25, .unreachable, "yard")])
        #expect(found.first?.reason == .macNetwork)
    }

    @Test func aPrivateStretchIsntAGap() {
        #expect(gaps([], privateSpans: [Self.span(59, 121)]).isEmpty)
        // Private for part of it: the rest is a gap, on either side.
        let found = gaps([], privateSpans: [Self.span(70, 110)])
        #expect(found.map(\.range) == [Self.span(60, 70), Self.span(110, 120)])
    }

    @Test func notRecordingNow() {
        let found = gaps([Self.incident(180, .storageFailed, "door", "the recordings drive was full")], through: Self.at(200))
        #expect(found.count == 2)
        #expect(found.last?.ongoing == true)
        #expect(found.last?.sentence == "Not recording: the recordings drive was full.")
        #expect(found.first?.ongoing == false)
    }
}
