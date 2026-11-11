// The demo cameras' make, as Reolink's and ONVIF's providers are for real ones: it says what a demo camera is, and
// serves its controls on the demo world (PTZ moves and zooms what the scene shows, day and night and brightness
// change how it's drawn, a restart drops its streams for a while), and a doorbell's presses from the script.
import Devices
import Foundation
import PondCore

public struct DemoProvider: CameraProvider {
    public let id = Demo.scheme
    public let name = "Demo"
    public var maker: String? { "Demo" }
    public var appName: String? { "the demo" }
    public var subStreamName: String? { "Sub" }

    public init() {}

    /// The demo provider offered beside the real ones, from now on (in a demo's service).
    public static func register() {
        if !CameraProviders.extra.contains(where: { $0.id == Demo.scheme }) { CameraProviders.extra.append(DemoProvider()) }
    }

    /// A demo camera's id, from its host (`<camera>.<scenario>`), if it's this world's.
    static func camera(_ host: String) -> (DemoWorld, Demo.Camera)? {
        guard let world = DemoWorld.current, let dot = host.firstIndex(of: "."), String(host[host.index(after: dot)...]) == world.scenario.name,
              let camera = world.camera(String(host[..<dot])) else { return nil }
        return (world, camera)
    }

    public func identify(host: String, username: String, password: String) async -> Config.Device? {
        guard let (world, camera) = Self.camera(host) else { return nil }
        return camera.config(in: world.scenario.name).device
    }

    public func streams(host: String) -> (main: String, sub: String)? {
        guard Self.camera(host) != nil else { return nil }
        return ("\(Demo.scheme)://\(host)/main", "\(Demo.scheme)://\(host)/sub")
    }

    public func events(host: String, username: String, password: String) -> CameraEvents? {
        guard let (world, camera) = Self.camera(host) else { return nil }
        return DemoEvents(world: world, camera: camera)
    }

    public func ptz(_ access: CameraAccess) async -> Offer<any PTZControl> {
        guard let (world, camera) = Self.camera(access.host), camera.ptz else { return .no }
        return .yes(DemoPTZ(world: world, id: camera.id))
    }

    public func items(_ access: CameraAccess) async -> Offer<[any ItemControl]> {
        guard let (world, camera) = Self.camera(access.host) else { return .no }
        var items: [any ItemControl] = [
            DemoItem(world: world, id: camera.id,
                     item: .init(id: "dayNight", title: "Day & Night", symbol: "circle.lefthalf.filled", group: .picture, order: 10,
                                 kind: .choice([.init(value: "auto", title: "Auto", symbol: "circle.lefthalf.filled"),
                                                .init(value: "day", title: "Day", symbol: "sun.max.fill"),
                                                .init(value: "night", title: "Night", symbol: "moon.stars.fill")]),
                                 provider: id)),
            DemoItem(world: world, id: camera.id,
                     item: .init(id: "brightness", title: "Brightness", symbol: "sun.max", group: .picture, order: 30,
                                 kind: .slider(min: 0, max: 100, step: 1), provider: id)),
            DemoItem(world: world, id: camera.id,
                     item: .init(id: "statusLight", title: "Status Light", symbol: "lightbulb.led", group: .light, order: 20,
                                 kind: .toggle, provider: id)),
            DemoItem(world: world, id: camera.id,
                     item: .init(id: "restart", title: "Restart", symbol: "arrow.clockwise", group: .device, order: 90,
                                 kind: .action(confirm: "Restart the camera? It goes offline for about 20 seconds."), provider: id)),
        ]
        if camera.ptz {
            items.append(DemoItem(world: world, id: camera.id,
                                  item: .init(id: "home.go", title: "Home", symbol: "house", group: .move, order: 10,
                                              kind: .action(confirm: nil), provider: id)))
        }
        return .yes(items)
    }
}

struct DemoPTZ: PTZControl {
    let world: DemoWorld
    let id: String

    var abilities: Config.Controls.PTZ { .init(provider: Demo.scheme, panTilt: true, zoom: true, presets: 8) }

    func move(_ velocity: PTZVelocity) async throws(ControlFailure) {
        world.move(id, pan: velocity.pan, tilt: velocity.tilt, zoom: velocity.zoom)
    }

    func stop() async throws(ControlFailure) { world.move(id, pan: 0, tilt: 0, zoom: 0) }

    func presets() async throws(ControlFailure) -> [PTZPreset] { world.presets(id).map { PTZPreset(id: $0.id, name: $0.name) } }

    func goTo(_ preset: String) async throws(ControlFailure) { world.go(to: preset, id) }

    func savePreset(_ name: String, replacing: String?) async throws(ControlFailure) -> PTZPreset {
        let kept = world.save(preset: name, id, replacing: replacing)
        return PTZPreset(id: kept, name: name)
    }

    func removePreset(_ preset: String) async throws(ControlFailure) { world.remove(preset: preset, id) }
}

struct DemoItem: ItemControl {
    let world: DemoWorld
    let id: String
    let item: Config.Controls.Item

    func value() async throws(ControlFailure) -> Config.Controls.Value? {
        switch item.id {
        case "dayNight": .choice(world.nightMode(id))
        case "brightness": .number(world.brightness(id))
        case "statusLight": .on(world.statusLight(id))
        default: nil
        }
    }

    func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
        switch (item.id, value) {
        case let ("dayNight", .choice(mode)): world.setNightMode(id, mode)
        case let ("brightness", .number(n)): world.setBrightness(id, n)
        case let ("statusLight", .on(on)): world.setStatusLight(id, on)
        default: throw .notSupported
        }
    }

    func perform() async throws(ControlFailure) {
        switch item.id {
        case "restart": world.restart(id)
        case "home.go": world.home(id)
        default: throw .notSupported
        }
    }
}

/// A doorbell's presses (and any camera's movement), as the script has them, checked twice a second.
final class DemoEvents: CameraEvents, @unchecked Sendable {
    let world: DemoWorld
    let camera: Demo.Camera
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(world: DemoWorld, camera: Demo.Camera) {
        self.world = world
        self.camera = camera
    }

    func start(motion: @escaping @Sendable (Bool) -> Void, pressed: @escaping @Sendable () -> Void,
               state: @escaping @Sendable (DoorbellButtonState) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "demo.events.\(camera.id)"))
        var last = Date()
        var moving = false
        let world = world, camera = camera
        timer.setEventHandler {
            let now = Date()
            if camera.doorbell {
                for _ in DemoScript.rings(scenario: world.scenario.name, camera: camera, busyness: world.scenario.busyness, from: last, to: now) {
                    pressed()
                }
            }
            let now_moving = world.figures(camera.id, at: now).contains { $0.moving }
            if now_moving != moving {
                moving = now_moving
                motion(moving)
            }
            last = now
        }
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        state(.watching)
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    func stop() { lock.withLock { timer }?.cancel() }
}
