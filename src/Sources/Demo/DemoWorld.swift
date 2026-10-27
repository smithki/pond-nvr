// A demo Pond's cameras as they are now: where a PTZ camera points (and its kept positions), day and night,
// brightness, and whether one is restarting. Changed by the demo provider's controls, read by each frame drawn;
// kept in the scenario's folder so they're as they were left when the demo opens again.
import Detection
import Foundation
import NVRCore

public final class DemoWorld: @unchecked Sendable {
    /// This process's demo, once it's started (`DemoWorld.start`).
    nonisolated(unsafe) public private(set) static var current: DemoWorld?

    public let scenario: Demo.Scenario
    let path: String?
    private let lock = NSLock()
    private var cameras: [String: CameraState] = [:]

    struct CameraState: Codable {
        /// The middle of what it shows, and how far it's zoomed in (1: all of the scene).
        var x = 0.5, y = 0.5, zoom = 1.0
        var presets: [String: [Double]] = [:]
        var nightMode = "auto"
        var brightness = 50.0
        var status = true
        /// Moving now: its speeds, and since when (not kept).
        var velocity: [Double]?
        var since: Date?
        var restartingUntil: Date?

        enum CodingKeys: String, CodingKey { case x, y, zoom, presets, nightMode, brightness, status }
    }

    public init(scenario: Demo.Scenario, folder: String?) {
        self.scenario = scenario
        path = folder.map { ($0 as NSString).appendingPathComponent("world.json") }
        if let path, let data = FileManager.default.contents(atPath: path),
           let kept = try? JSONDecoder().decode([String: CameraState].self, from: data) {
            cameras = kept
        }
    }

    /// This process's demo, from its folder (Demo.folder): its streams, controls and detection.
    @discardableResult
    public static func start(_ scenario: Demo.Scenario, folder: String?) -> DemoWorld {
        let world = DemoWorld(scenario: scenario, folder: folder)
        current = world
        return world
    }

    public func camera(_ id: String) -> Demo.Camera? { scenario.cameras.first { $0.id == id } }

    private func save() {
        guard let path else { return }
        let kept = lock.withLock { cameras }
        try? JSONEncoder().encode(kept).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// A camera's state now (a move under way carried on to this moment).
    func state(_ id: String, at t: Date = Date()) -> CameraState {
        lock.withLock {
            var s = cameras[id] ?? CameraState()
            if let v = s.velocity, let since = s.since {
                let dt = t.timeIntervalSince(since)
                s.zoom = min(4, max(1, s.zoom * pow(2, v[2] * dt * 0.5)))
                s.x += v[0] * dt * 0.18 / s.zoom
                s.y -= v[1] * dt * 0.18 / s.zoom
                s.since = t
                cameras[id] = s
            }
            // What it shows stays inside the scene.
            let half = 0.5 / s.zoom
            s.x = min(1 - half, max(half, s.x))
            s.y = min(1 - half, max(half, s.y))
            cameras[id] = s
            return s
        }
    }

    func change(_ id: String, _ change: (inout CameraState) -> Void) {
        _ = state(id)
        lock.withLock {
            var s = cameras[id] ?? CameraState()
            change(&s)
            cameras[id] = s
        }
        save()
    }

    // MARK: What the scene shows

    /// What part of the scene a camera shows: x, y, width and height, as fractions of it.
    func view(_ id: String, at t: Date = Date()) -> (x: Double, y: Double, width: Double, height: Double) {
        let s = state(id, at: t)
        return (s.x - 0.5 / s.zoom, s.y - 0.5 / s.zoom, 1 / s.zoom, 1 / s.zoom)
    }

    /// The camera's light: how much daylight (0 night, 1 day), and whether it sees in infrared now.
    func light(_ id: String, at t: Date) -> (daylight: Double, infrared: Bool, brightness: Double) {
        let s = state(id, at: t)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: drifted(id, t))
        let hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60
        // Dawn from 6 to 7:30, dusk from 18:00 to 19:30.
        let daylight = min(1, max(0, (hour - 6) / 1.5)) * min(1, max(0, (19.5 - hour) / 1.5))
        let infrared = s.nightMode == "night" || (s.nightMode == "auto" && daylight < 0.25)
        return (camera(id)?.scene == .livingRoom ? max(daylight, 0.7) : daylight, infrared, s.brightness)
    }

    /// The time as the camera's clock has it (one with a drifting clock runs ahead, more each day).
    func drifted(_ id: String, _ t: Date) -> Date {
        guard camera(id)?.trouble == .clockDrift else { return t }
        return t.addingTimeInterval(95 + t.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 86400 * 30)
    }

    func figures(_ id: String, at t: Date) -> [Figure] {
        guard let camera = camera(id) else { return [] }
        return DemoScript.figures(scenario: scenario.name, camera: camera, busyness: scenario.busyness, at: t)
    }

    func isRestarting(_ id: String, at t: Date = Date()) -> Bool {
        lock.withLock { cameras[id]?.restartingUntil.map { $0 > t } ?? false }
    }

    /// What detection finds in a camera's picture at `t`: each figure in view, as the frame shows it.
    public func detections(_ id: String, at t: Date) -> [Detection] {
        let v = view(id, at: t)
        return figures(id, at: t).compactMap { f in
            let box = Detection.Box(x: (f.x - v.x) / v.width, y: (f.y - v.y) / v.height, width: f.width / v.width,
                                    height: f.height / v.height)
            // Mostly in view, as a model would see it.
            let left = max(0, box.x), right = min(1, box.x + box.width), top = max(0, box.y), bottom = min(1, box.y + box.height)
            guard right > left, bottom > top, (right - left) * (bottom - top) >= box.area * 0.4 else { return nil }
            let clipped = Detection.Box(x: left, y: top, width: right - left, height: bottom - top)
            guard let visitor = f.visitor else { return Detection(label: "package", category: .package, confidence: 0.8, box: clipped) }
            let found = visitor.detected
            return Detection(label: found.label, category: found.category, confidence: 0.86, box: clipped)
        }
    }

    // MARK: Controls

    func move(_ id: String, pan: Double, tilt: Double, zoom: Double) {
        change(id) {
            $0.velocity = pan == 0 && tilt == 0 && zoom == 0 ? nil : [pan, tilt, zoom]
            $0.since = Date()
        }
    }

    func presets(_ id: String) -> [(id: String, name: String)] {
        let s = state(id)
        return s.presets.keys.sorted().map { ($0, $0) }
    }

    func save(preset name: String, _ id: String, replacing: String?) -> String {
        change(id) { s in
            if let replacing { s.presets[replacing] = nil }
            s.presets[name] = [s.x, s.y, s.zoom]
        }
        return name
    }

    func remove(preset: String, _ id: String) { change(id) { $0.presets[preset] = nil } }

    func go(to preset: String, _ id: String) {
        change(id) { s in
            guard let p = s.presets[preset], p.count == 3 else { return }
            (s.x, s.y, s.zoom, s.velocity) = (p[0], p[1], p[2], nil)
        }
    }

    func home(_ id: String) { change(id) { ($0.x, $0.y, $0.zoom, $0.velocity) = (0.5, 0.5, 1, nil) } }

    func nightMode(_ id: String) -> String { state(id).nightMode }
    func setNightMode(_ id: String, _ mode: String) { change(id) { $0.nightMode = mode } }
    func brightness(_ id: String) -> Double { state(id).brightness }
    func setBrightness(_ id: String, _ value: Double) { change(id) { $0.brightness = value } }
    func statusLight(_ id: String) -> Bool { state(id).status }
    func setStatusLight(_ id: String, _ on: Bool) { change(id) { $0.status = on } }

    /// Restarted: its streams end, and come back after 20 s.
    func restart(_ id: String) { change(id) { $0.restartingUntil = Date().addingTimeInterval(20) } }
}
