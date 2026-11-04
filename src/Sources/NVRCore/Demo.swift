// Demo mode: Pond with made-up cameras, to explore without any, and to try what one home doesn't have (many
// cameras, a doorbell, PTZ, a camera that keeps dropping, a full drive, another Pond to reach). Each scenario is a
// world of its own: a folder under `Demo.root` with its settings, recordings, database, log and secrets (in a file
// there, never the Keychain), and a service of its own (`pond run --config` on it, started by the app). Its cameras'
// streams are `demo://<camera>.<scenario>/main|sub`, drawn and encoded by the service (the Demo module), so the
// recorder, detection, live view and remote access run on them as on real ones.
import Foundation

public enum Demo {
    /// Where the scenarios' worlds are kept.
    public static let root = "~/Library/Application Support/Pond Demo"
    /// In a scenario's folder, beside its settings: which scenario it is (so a settings file there is known as a demo).
    public static let marker = "demo.json"
    /// A demo camera's streams' scheme.
    public static let scheme = "demo"

    /// The demo folder this process runs in, if it does (found from its settings file at start): its secrets and
    /// log are kept there instead of the Keychain and ~/Library/Logs.
    nonisolated(unsafe) public static var folder: String?
    /// Its drive's free space, as the storage checks and retention are told it (a scenario with a nearly full drive),
    /// for what's in its folder.
    nonisolated(unsafe) public static var freeGB: Double?

    /// The free space to say a folder's drive has, if this process's demo makes it up (bytes).
    public static func madeUpFree(_ path: String) -> Int64? {
        guard let folder, let freeGB, NSString(string: path).expandingTildeInPath.hasPrefix(folder) else { return nil }
        return Int64(freeGB * 1_000_000_000)
    }

    /// The scenario a settings file belongs to, if it's a demo's.
    public static func scenario(nextTo configPath: String) -> Scenario? {
        let folder = (NSString(string: configPath).expandingTildeInPath as NSString).deletingLastPathComponent
        guard let data = FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(marker)) else { return nil }
        return try? JSONDecoder().decode(Scenario.self, from: data)
    }

    /// Notes this process as running a demo, if its settings are one's.
    @discardableResult
    public static func adopt(configPath: String) -> Scenario? {
        guard let scenario = scenario(nextTo: configPath) else { return nil }
        folder = (NSString(string: configPath).expandingTildeInPath as NSString).deletingLastPathComponent
        freeGB = scenario.freeGB
        return scenario
    }

    /// A scenario's folder (a remote Pond's inside its scenario's).
    public static func folder(_ scenario: String, pond: String? = nil) -> String {
        let base = (NSString(string: root).expandingTildeInPath as NSString).appendingPathComponent(scenario)
        return pond.map { (base as NSString).appendingPathComponent("ponds/\($0)") } ?? base
    }

    public static func configPath(_ scenario: String, pond: String? = nil) -> String {
        (folder(scenario, pond: pond) as NSString).appendingPathComponent("config.json")
    }

    /// A scenario's world, made if it isn't yet (its remote Ponds' too): its settings and its marker. Made once; a
    /// world already there is kept as it is (what was recorded and changed in it), unless `fresh`.
    public static func prepare(_ scenario: Scenario, fresh: Bool = false) throws {
        try prepare(scenario, at: folder(scenario.name), fresh: fresh)
        for pond in scenario.ponds { try prepare(pond, at: folder(scenario.name, pond: pond.name), fresh: fresh) }
    }

    public static func prepare(_ scenario: Scenario, at folder: String, fresh: Bool) throws {
        let fm = FileManager.default
        if fresh {
            // Its services, if a demo app left them running, stopped first (they'd write into the new world).
            if let data = fm.contents(atPath: (folder as NSString).appendingPathComponent("pids.json")),
               let pids = try? JSONDecoder().decode([Int32].self, from: data) {
                for pid in pids { kill(pid, SIGTERM) }
            }
            try? fm.removeItem(atPath: folder)
        }
        let config = (folder as NSString).appendingPathComponent("config.json")
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(scenario).write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent(marker)))
        guard !fm.fileExists(atPath: config) else { return }
        let recordings = (folder as NSString).appendingPathComponent("Recordings")
        try StorageLocation.prepare(recordings)
        var settings = Config(storage: .init(recordings: recordings, database: (folder as NSString).appendingPathComponent("pond.sqlite")),
                              // (A nearly full drive's reserve below what's free: it's short of room, not emptied.)
                              retention: .init(continuous: .init(days: 2), events: .init(days: 7),
                                               minFreeGB: scenario.freeGB.map { max(1, $0 - 1) } ?? 5),
                              cameras: scenario.cameras.map { $0.config(in: scenario.name) })
        settings.name = scenario.pondName
        settings.remote = scenario.signaling.map { Config.Remote(enabled: true, signaling: $0, stun: "127.0.0.1:\(Demo.signalingPort + 1)") }
        try ConfigStore(path: config).save(settings)
        // Its cameras' passwords (made up; in its own secrets file, never the Keychain).
        let secrets = FileCredentialStore(path: (folder as NSString).appendingPathComponent("secrets.json"), service: Brand.keychainService)
        for camera in scenario.cameras { try secrets.setPassword("demo", for: camera.id) }
        // Its cameras made private to begin with.
        let privacy = scenario.cameras.filter(\.startsPrivate).map(\.id)
        if !privacy.isEmpty {
            try JSONEncoder().encode(["private": privacy]).write(to: URL(fileURLWithPath: PrivacyState.path(nextTo: config)))
        }
    }

    /// The scenarios there are.
    public static let scenarios: [Scenario] = [.home, .many, .trouble, .firstRun, .remoteSlow, .remoteUnreachable]

    public static func scenario(named name: String) -> Scenario? { scenarios.first { $0.name == name } }

    /// The signaling service the demo's Ponds share: pond-signal on this Mac, for them alone (its STUN on the next two
    /// ports).
    public static let signalingPort: UInt16 = 47_800
}

extension Demo {
    /// A world: its cameras, how busy they are, its troubles, and the other Ponds it's paired with.
    public struct Scenario: Codable, Equatable, Sendable {
        public var name: String
        public var title: String
        /// What it's for, as Settings › General lists it.
        public var about: String
        /// The Mac's name in it (as paired devices see it).
        public var pondName: String
        public var cameras: [Camera]
        /// Cameras on its network not set up yet: found by Add Camera (and offered in the toolbar), and added like
        /// real ones.
        public var found: [Camera]
        /// How many visits an hour a camera has, on average.
        public var busyness: Double
        /// Its storage nearly full (the drive's free space as the checks see it, in GB).
        public var freeGB: Double?
        /// Other Ponds paired with it (each a scenario of its own, run beside it).
        public var ponds: [Scenario]
        /// How the remote Ponds are reached.
        public var link: Link
        /// The signaling service its Ponds use (the demo's own, on this Mac), if it has other Ponds or is one.
        public var signaling: String?

        public init(name: String, title: String, about: String, pondName: String, cameras: [Camera], found: [Camera] = [],
                    busyness: Double = 6, freeGB: Double? = nil, ponds: [Scenario] = [], link: Link = .direct, signaling: String? = nil) {
            self.name = name
            self.title = title
            self.about = about
            self.pondName = pondName
            self.cameras = cameras
            self.found = found
            self.busyness = busyness
            self.freeGB = freeGB
            self.ponds = ponds
            self.link = link
            self.signaling = signaling
        }
    }

    /// How a scenario's remote Ponds are reached.
    public enum Link: String, Codable, Sendable {
        /// Directly, as on a good connection.
        case direct
        /// A slow, lossy link: 300 kB/s, 120 ms there and back, 2% lost.
        case slow
        /// Not at all: the other Pond isn't running.
        case unreachable
    }

    /// What a demo camera shows.
    public enum Scene: String, Codable, Sendable, CaseIterable {
        case frontDoor, driveway, backyard, garage, livingRoom, sideGate, street, dock, porch, shed
    }

    /// What goes wrong with a demo camera.
    public enum Trouble: String, Codable, Sendable {
        /// Its stream drops every few minutes.
        case drops
        /// A keyframe only every 12 s.
        case slowKeyframes
        /// Its clock runs ahead (the timestamp it draws, and its reports).
        case clockDrift
    }

    public struct Camera: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var scene: Scene
        public var doorbell: Bool
        public var ptz: Bool
        public var manufacturer: String
        public var model: String
        public var startsPrivate: Bool
        public var trouble: Trouble?

        public init(_ id: String, _ name: String, scene: Scene, doorbell: Bool = false, ptz: Bool = false,
                    manufacturer: String = "Demo", model: String = "Camera", startsPrivate: Bool = false, trouble: Trouble? = nil) {
            self.id = id
            self.name = name
            self.scene = scene
            self.doorbell = doorbell
            self.ptz = ptz
            self.manufacturer = manufacturer
            self.model = model
            self.startsPrivate = startsPrivate
            self.trouble = trouble
        }

        /// Its streams' host: the camera and its scenario.
        public func host(in scenario: String) -> String { "\(id).\(scenario)" }

        public func config(in scenario: String) -> Config.Camera {
            let base = "\(Demo.scheme)://\(host(in: scenario))"
            var camera = Config.Camera(id: id, name: name, main: base + "/main", sub: base + "/sub", username: "demo",
                                       kind: doorbell ? .doorbell : .camera)
            camera.device = Config.Device(manufacturer: manufacturer, model: model, serial: "DEMO-\(id.uppercased())",
                                          firmware: "1.0", isDoorbell: doorbell, provider: Demo.scheme)
            return camera
        }

        /// Its main stream's size: a doorbell's is 4:3 and upright-ish, as real ones are.
        public var mainSize: (width: Int, height: Int) { doorbell ? (1600, 1200) : (1920, 1080) }
        public var subSize: (width: Int, height: Int) { doorbell ? (640, 480) : (640, 360) }
    }

    /// A camera's id and scenario, from its stream's address (`demo://<camera>.<scenario>/main`), and which stream.
    public static func parse(_ url: String) -> (camera: String, scenario: String, main: Bool)? {
        guard let parts = URLComponents(string: url), parts.scheme == scheme, let host = parts.host,
              let dot = host.firstIndex(of: ".") else { return nil }
        return (String(host[..<dot]), String(host[host.index(after: dot)...]), parts.path != "/sub")
    }
}

extension Demo.Scenario {
    static let signaling = "ws://127.0.0.1:\(Demo.signalingPort)"

    static let lakeHouse = Demo.Scenario(
        name: "lake-house", title: "Lake House", about: "A second home, reached from the first.", pondName: "Lake House",
        cameras: [
            .init("dock", "Dock", scene: .dock, manufacturer: "Reolink", model: "RLC-811A"),
            .init("porch", "Porch", scene: .porch, doorbell: true, manufacturer: "Reolink", model: "Video Doorbell WiFi"),
            .init("lane", "Lane", scene: .street, manufacturer: "Amcrest", model: "IP8M-2496E"),
            .init("shed", "Shed", scene: .shed, ptz: true, manufacturer: "Reolink", model: "E1 Outdoor"),
        ], busyness: 3, signaling: signaling)

    public static let home = Demo.Scenario(
        name: "home", title: "Home", about: "Six cameras, a busy day, and a second home to reach.", pondName: "Home",
        cameras: [
            .init("front-door", "Front Door", scene: .frontDoor, doorbell: true, manufacturer: "Reolink", model: "Video Doorbell PoE"),
            .init("driveway", "Driveway", scene: .driveway, manufacturer: "Reolink", model: "RLC-810A"),
            .init("backyard", "Backyard", scene: .backyard, ptz: true, manufacturer: "Reolink", model: "RLC-823A"),
            .init("garage", "Garage", scene: .garage, manufacturer: "Hikvision", model: "DS-2CD2387G2"),
            .init("living-room", "Living Room", scene: .livingRoom, manufacturer: "Reolink", model: "E1 Zoom", startsPrivate: true),
            .init("side-gate", "Side Gate", scene: .sideGate, manufacturer: "Amcrest", model: "IP5M-T1179E"),
        ], ponds: [lakeHouse], signaling: signaling)

    public static let many = Demo.Scenario(
        name: "many", title: "Many Cameras", about: "Sixteen cameras, for the layout and the Mac's video work.", pondName: "Demo Mac",
        cameras: (0 ..< 16).map { i in
            let scene = Demo.Scene.allCases[i % Demo.Scene.allCases.count]
            return .init("camera-\(i + 1)", "Camera \(i + 1)", scene: scene, doorbell: scene == .frontDoor, ptz: i == 2)
        }, busyness: 4)

    public static let trouble = Demo.Scenario(
        name: "trouble", title: "Trouble", about: "A camera that keeps dropping, keyframes far apart, a clock adrift, a full drive.",
        pondName: "Demo Mac",
        cameras: [
            .init("driveway", "Driveway", scene: .driveway, trouble: .drops),
            .init("garage", "Garage", scene: .garage, trouble: .slowKeyframes),
            .init("street", "Street", scene: .street, trouble: .clockDrift),
            .init("backyard", "Backyard", scene: .backyard),
        ], freeGB: 3)

    public static let firstRun = Demo.Scenario(
        name: "first-run", title: "First Run", about: "No cameras yet: setting up, and adding the ones found.", pondName: "Demo Mac",
        cameras: [], found: home.cameras)

    static func reaching(_ name: String, _ title: String, _ about: String, link: Demo.Link) -> Demo.Scenario {
        var scenario = home
        scenario.name = name
        scenario.title = title
        scenario.about = about
        scenario.cameras = Array(home.cameras.prefix(2))
        scenario.link = link
        return scenario
    }

    public static let remoteSlow = reaching("remote-slow", "Slow Second Home", "The Lake House over a slow, lossy link.", link: .slow)
    public static let remoteUnreachable = reaching("remote-unreachable", "Unreachable Second Home",
                                                   "The Lake House gone quiet.", link: .unreachable)
}
