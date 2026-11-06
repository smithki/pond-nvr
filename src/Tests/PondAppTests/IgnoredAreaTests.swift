import Detection
import Foundation
import Testing
@testable import PondApp

struct IgnoredAreaTests {
    func event(_ kind: TimelineEvent.Kind, box: Detection.Box?) -> TimelineEvent {
        var e = TimelineEvent(id: "e", camera: "porch", kind: kind, start: Date(), end: Date().addingTimeInterval(5), summary: "")
        e.box = box
        return e
    }

    @Test func anEventsBoxGrowsALittleAndStaysInThePicture() throws {
        let area = try #require(IgnoredArea(event(.vehicle, box: .init(x: 0.5, y: 0.6, width: 0.2, height: 0.2))))
        // 15% of its size more on each side.
        #expect(area.points[0][0] == 0.47 && abs(area.points[0][1] - 0.57) < 1e-9)
        #expect(abs(area.points[2][0] - 0.73) < 1e-9 && abs(area.points[2][1] - 0.83) < 1e-9)
        // By the picture's edge: up to it, not past it.
        let edge = try #require(IgnoredArea(event(.person, box: .init(x: 0, y: 0.9, width: 0.3, height: 0.1))))
        #expect(edge.points[0][0] == 0 && edge.points[2][1] == 1)
    }

    @Test func itIgnoresTheEventsKindAlone() {
        #expect(IgnoredArea(event(.vehicle, box: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1)))?.categories == ["vehicle"])
        #expect(IgnoredArea(event(.bike, box: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1)))?.categories == ["vehicle"])
        // What a zone doesn't sort (motion, a ring): everything there.
        #expect(IgnoredArea(event(.motion, box: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1)))?.categories == nil)
        // No box, nothing to draw.
        #expect(IgnoredArea(event(.person, box: nil)) == nil)
    }
}
