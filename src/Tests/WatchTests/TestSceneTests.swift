import Detection
import Foundation
import Testing
@testable import Watch

struct TestSceneTests {
    typealias E = TestScene.Expected

    @Test func aSceneIsScoredForWhatItMissedAndWhatItMadeThatItShouldnt() {
        let expected = [E(kind: "person", from: 4, to: 19), E(kind: "package", from: 18, to: 20)]
        // The person made (a little late), the package missed, a vehicle made that shouldn't have been.
        let s = SceneScore.score(expected: expected, made: [MadeEvent(kind: "person", from: 5.5, to: 18),
                                                            MadeEvent(kind: "vehicle", from: 30, to: 40)])
        #expect(s == SceneScore(hits: 1, misses: 1, falseEvents: 1, splits: 0))
        // Nothing expected, nothing made: clean.
        #expect(SceneScore.score(expected: [], made: []) == .zero)
        // One expected made as two: a split, not a false event.
        let split = SceneScore.score(expected: [E(kind: "person", from: 0, to: 20)],
                                     made: [MadeEvent(kind: "person", from: 0, to: 8), MadeEvent(kind: "person", from: 12, to: 20)])
        #expect(split == SceneScore(hits: 1, misses: 0, falseEvents: 0, splits: 1))
    }

    // Whole scenes through the pipeline, made up: a motion grid (MotionGate's, 32 × 24) and what the model would say.

    static let columns = 32, rows = 24

    /// A still picture's grid, with these cells brightened by `by` (something there, or light on it).
    static func cells(lit: Set<Int> = [], by: Float = 0) -> [Float] {
        (0 ..< columns * rows).map { lit.contains($0) ? 100 + by : 100 }
    }

    /// The grid cells a box covers.
    static func covered(_ box: Detection.Box) -> Set<Int> {
        var out = Set<Int>()
        for r in 0 ..< rows {
            for c in 0 ..< columns {
                let x = (Double(c) + 0.5) / Double(columns), y = (Double(r) + 0.5) / Double(rows)
                if x >= box.x, x <= box.x + box.width, y >= box.y, y <= box.y + box.height { out.insert(r * columns + c) }
            }
        }
        return out
    }

    func replay(seconds: Double, every: Double = 0.2, scene: (Double) -> (cells: [Float], found: [Detection])) -> [MadeEvent] {
        var replay = SceneReplay(scene: TestScene(name: "made up", expect: []))
        var t = 0.0
        while t <= seconds {
            let now = scene(t)
            replay.picture(at: t, cells: { now.cells }, detect: { _ in now.found })
            t += every
        }
        return replay.finish()
    }

    @Test func someoneWalkingAcrossMakesOnePersonEvent() {
        let made = replay(seconds: 14) { t in
            guard t >= 2, t <= 12 else { return (Self.cells(), []) }
            let box = Detection.Box(x: 0.05 + (t - 2) * 0.07, y: 0.4, width: 0.1, height: 0.35)
            return (Self.cells(lit: Self.covered(box), by: 60), [Detection(label: "person", category: .person, confidence: 0.9, box: box)])
        }
        #expect(SceneScore.score(expected: [E(kind: "person", from: 2, to: 12)], made: made) == SceneScore(hits: 1, misses: 0, falseEvents: 0, splits: 0))
    }

    @Test func aParkedCarWithLightFlickeringOverItAtNightMakesNothing() {
        let car = Detection.Box(x: 0.55, y: 0.5, width: 0.3, height: 0.2)
        let made = replay(seconds: 120) { t in
            // Headlights and infrared: the car's cells brighten and dim every second, the car itself still.
            let flicker: Float = Int(t) % 2 == 0 ? 50 : 0
            return (Self.cells(lit: Self.covered(car), by: flicker), [Detection(label: "car", category: .vehicle, confidence: 0.8, box: car)])
        }
        #expect(SceneScore.score(expected: [], made: made) == .zero)
    }
}
