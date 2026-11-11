// The settings: storage, retention and cameras. Kept as one JSON file that the app reads and writes
// (ConfigStore) and that can also be edited by hand; see docs/configuration.md. Passwords are not in it.
import Foundation

public struct Config: Codable, Equatable, Sendable {
    /// The file format's version. A file from a newer pond is refused rather than half understood.
    public static let currentVersion = 1

    public var version: Int
    /// This Pond's name, as the app shows it beside others ("Home", "Lake House") and devices pairing with it see it;
    /// left out, this Mac's name.
    public var name: String?
    public var storage: Storage
    public var retention: Retention
    public var cameras: [Camera]
    /// Reaching this Mac from outside (remote access); left out, it's off.
    public var remote: Remote?
    /// Whether the service downloads search's picture model, and new versions of it, by itself (checking pond.camera
    /// weekly): left out, it does. Off, it downloads one only when asked (Settings › Search, Check for Updates).
    public var searchModelUpdates: Bool?
    /// Beta and test features (Settings › Advanced): what's being tried before everyone has it, and what
    /// checking a new version needs (test scenes kept from this Pond's events). Left out, off.
    public var testFeatures: Bool?
    /// Which of them are on, each turned on of its own (only while `testFeatures` is): left out, none.
    public var testFeaturesOn: [String]?

    /// A beta or test feature, turned on in Settings › Advanced.
    public enum TestFeature: String, CaseIterable, Sendable {
        /// Test scenes kept from this Pond's events, for checking a new version (`pond advanced scenes`).
        case testScenes
    }

    /// Whether a beta or test feature is on: beta and test features on, and it too.
    public func has(_ feature: TestFeature) -> Bool { testFeatures == true && testFeaturesOn?.contains(feature.rawValue) == true }

    /// Whether the service has anything to do: cameras to record, or remote access to keep (a Mac that only watches
    /// another Pond's cameras has none of its own).
    public var givesTheServiceWork: Bool { !cameras.isEmpty || remote?.enabled == true }

    public init(storage: Storage, retention: Retention = Retention(), cameras: [Camera] = [], remote: Remote? = nil) {
        version = Self.currentVersion
        self.storage = storage
        self.retention = retention
        self.cameras = cameras
        self.remote = remote
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        name = try c.decodeIfPresent(String.self, forKey: .name)
        storage = try c.decode(Storage.self, forKey: .storage)
        retention = try c.decodeIfPresent(Retention.self, forKey: .retention) ?? Retention()
        cameras = try c.decodeIfPresent([Camera].self, forKey: .cameras) ?? []
        remote = try c.decodeIfPresent(Remote.self, forKey: .remote)
        searchModelUpdates = try c.decodeIfPresent(Bool.self, forKey: .searchModelUpdates)
        testFeatures = try c.decodeIfPresent(Bool.self, forKey: .testFeatures)
        testFeaturesOn = try c.decodeIfPresent([String].self, forKey: .testFeaturesOn)
    }

    /// Remote access: whether this Mac can be reached from outside, and the signaling service its devices find it
    /// through (a WebSocket address: wss://…; see deploy/).
    public struct Remote: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var signaling: String?
        /// Where this Mac asks for the address the world sees it at ("host:port"): left out, the signaling host's
        /// port 3478 (pond-signal answers there).
        public var stun: String?
        /// A fixed UDP port for connections (one to forward on the router, when no other path works); left out, any.
        public var port: UInt16?
        /// Whether this Mac's own addresses are offered (they find a device on the same network, or one an IPv6
        /// path reaches); off, only the public address the router shows.
        public var shareLocalAddresses: Bool
        /// Connections over a mesh only (Tailscale, Headscale): its tunnel's addresses, no public address, no relay.
        public var mesh: Bool
        /// The mesh's ranges, if not Tailscale's (100.64.0.0/10, fd7a:115c:a1e0::/48).
        public var meshSubnets: [String]?
        /// A relay of one's own (coturn), "host:port" (port 3480 if left out), for when no direct path works. Its
        /// shared secret is in the Keychain (`pond remote relay-secret`).
        public var relay: String?

        public init(enabled: Bool = false, signaling: String? = nil, stun: String? = nil, port: UInt16? = nil,
                    shareLocalAddresses: Bool = true, mesh: Bool = false, meshSubnets: [String]? = nil, relay: String? = nil) {
            self.enabled = enabled
            self.signaling = signaling
            self.stun = stun
            self.port = port
            self.shareLocalAddresses = shareLocalAddresses
            self.mesh = mesh
            self.meshSubnets = meshSubnets
            self.relay = relay
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            signaling = try c.decodeIfPresent(String.self, forKey: .signaling)
            stun = try c.decodeIfPresent(String.self, forKey: .stun)
            port = try c.decodeIfPresent(UInt16.self, forKey: .port)
            shareLocalAddresses = try c.decodeIfPresent(Bool.self, forKey: .shareLocalAddresses) ?? true
            mesh = try c.decodeIfPresent(Bool.self, forKey: .mesh) ?? false
            meshSubnets = try c.decodeIfPresent([String].self, forKey: .meshSubnets)
            relay = try c.decodeIfPresent(String.self, forKey: .relay)
        }
    }

    public struct Storage: Codable, Equatable, Sendable {
        /// Folder for continuous recording: an external drive now, a NAS share later. Must hold the marker file
        /// that `StorageLocation.prepare` writes, so an unplugged drive is noticed instead of filling the boot disk.
        public var recordings: String
        /// Folder for event clips and snapshots. Nil means inside `recordings`.
        public var events: String?
        /// The SQLite index. Keep it on the internal disk.
        public var database: String

        public init(recordings: String, events: String? = nil, database: String) {
            self.recordings = recordings
            self.events = events
            self.database = database
        }

        /// Where event clips go, with `~` expanded.
        public var eventsPath: String { Config.expand(events ?? recordings) }
        public var recordingsPath: String { Config.expand(recordings) }
        public var databasePath: String { Config.expand(database) }
    }

    public struct Retention: Codable, Equatable, Sendable {
        public var continuous: Continuous
        public var events: Events
        /// Space always left free on each storage volume. Below it the oldest continuous recording is deleted.
        public var minFreeGB: Double

        public init(continuous: Continuous = Continuous(), events: Events = Events(), minFreeGB: Double = 25) {
            self.continuous = continuous
            self.events = events
            self.minFreeGB = minFreeGB
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            continuous = try c.decodeIfPresent(Continuous.self, forKey: .continuous) ?? Continuous()
            events = try c.decodeIfPresent(Events.self, forKey: .events) ?? Events()
            minFreeGB = try c.decodeIfPresent(Double.self, forKey: .minFreeGB) ?? 25
        }

        /// Continuous recording: kept `days`, and at most `maxSizeGB` if set. The oldest goes first.
        public struct Continuous: Codable, Equatable, Sendable {
            public var days: Int
            public var maxSizeGB: Double?

            public init(days: Int = 7, maxSizeGB: Double? = nil) {
                self.days = days
                self.maxSizeGB = maxSizeGB
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 7
                maxSizeGB = try c.decodeIfPresent(Double.self, forKey: .maxSizeGB)
            }
        }

        /// Event clips and snapshots: kept `days`, whatever happens to continuous recording.
        public struct Events: Codable, Equatable, Sendable {
            public var days: Int

            public init(days: Int = 30) { self.days = days }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 30
            }
        }
    }

    public struct Camera: Codable, Equatable, Sendable, Identifiable {
        /// Short and stable: used in file paths, the database, the Keychain and the HomeKit accessory identity.
        public var id: String
        public var name: String
        /// The main stream (recorded, sent to HomeKit) and the sub-stream (decoded for detection).
        public var main: String
        public var sub: String
        /// The camera login. The password is in the Keychain (see CredentialStore), never in this file.
        public var username: String
        public var zones: [Zone]
        /// A camera or a doorbell (which HomeKit shows with a button that rings).
        public var kind: Kind
        /// Served to HomeKit (by the login service); off until chosen.
        public var homekit: Bool
        /// What the camera says it is, read from it when added or checked; nil if it would not say.
        public var device: Device?
        /// How many can watch it in the Home app at once (iPhone and Mac, say); nil for the default. Each
        /// is a stream management service of the accessory; all share the one camera connection, and the
        /// app's own views don't count.
        public var homekitViewers: Int?
        /// Keep the sub-stream open in the service, so live views (the Home app's, the app's) and snapshots
        /// start from its latest keyframe at once; nil for the default: on for a camera in HomeKit.
        public var instantLive: Bool?
        /// The picture the Home app gets: the camera's own stream (nil, the default), or re-encoded by Pond.
        public var homekitVideo: HomeKitVideo?
        public var reencodesForHomeKit: Bool { homekitVideo == .reencoded }
        /// Offered to HomeKit Secure Video (the home hub records its events to iCloud); off until chosen.
        public var homekitRecording: Bool?
        /// Watched for people, vehicles, animals and packages (its sub-stream, by the detection model), making
        /// events; nil for the default: on.
        public var detection: Bool?
        public var watches: Bool { detection ?? true }
        /// Recorded from its sub-stream rather than its main stream (for a camera whose main stream takes more room
        /// than it's worth); nil for the default: the main stream. Live view and HomeKit use both as ever.
        public var recordsSub: Bool?
        /// The stream recorded.
        public var recordedStream: String { recordsSub == true && !sub.isEmpty ? sub : main }
        /// What sets its motion sensor in the Home app (which HomeKit Secure Video records on, and notifies about):
        /// Pond's detection (nil, the default, while the camera is watched: a person, vehicle, bike or animal in
        /// its zones), or the camera's own motion.
        public var homekitMotion: HomeKitMotion?
        public var homeKitMotionFromDetection: Bool { watches && homekitMotion != .camera }

        public enum HomeKitMotion: String, Codable, Sendable, CaseIterable {
            case detection
            case camera
        }

        public enum HomeKitVideo: String, Codable, Sendable, CaseIterable {
            /// The camera's sub-stream (or main, for a viewer with the bandwidth), as it is: no work for the Mac.
            case camera
            /// The main stream, re-encoded on the Mac to the size and bitrate each viewer asks for.
            case reencoded
        }
        /// Whether the service keeps the sub-stream open: the setting, else on for a camera in HomeKit.
        public var keepsLiveReady: Bool { instantLive ?? homekit }

        public static let defaultHomeKitViewers = 2
        public static let homeKitViewerRange = 1 ... 4
        /// The viewers HomeKit offers: the setting, kept within the range.
        public var homeKitViewerSlots: Int {
            min(max(homekitViewers ?? Self.defaultHomeKitViewers, Self.homeKitViewerRange.lowerBound),
                Self.homeKitViewerRange.upperBound)
        }

        public enum Kind: String, Codable, Sendable, CaseIterable {
            case camera
            case doorbell
        }

        public init(id: String, name: String, main: String, sub: String, username: String, zones: [Zone] = [],
                    kind: Kind = .camera, homekit: Bool = false, device: Device? = nil, homekitViewers: Int? = nil,
                    instantLive: Bool? = nil, homekitVideo: HomeKitVideo? = nil, homekitRecording: Bool? = nil, detection: Bool? = nil, homekitMotion: HomeKitMotion? = nil) {
            self.id = id
            self.name = name
            self.main = main
            self.sub = sub
            self.username = username
            self.zones = zones
            self.kind = kind
            self.homekit = homekit
            self.device = device
            self.homekitViewers = homekitViewers
            self.instantLive = instantLive
            self.homekitVideo = homekitVideo
            self.homekitRecording = homekitRecording
            self.detection = detection
            self.homekitMotion = homekitMotion
        }

        /// The host in the main stream's address.
        public var host: String { URLComponents(string: main)?.host ?? main }

        /// Set to be talked to only for its video: its motion and button are not watched.
        public var isVideoOnly: Bool { device?.isVideoOnly == true }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            main = try c.decode(String.self, forKey: .main)
            sub = try c.decode(String.self, forKey: .sub)
            username = try c.decode(String.self, forKey: .username)
            zones = try c.decodeIfPresent([Zone].self, forKey: .zones) ?? []
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .camera
            homekit = try c.decodeIfPresent(Bool.self, forKey: .homekit) ?? false
            device = try c.decodeIfPresent(Device.self, forKey: .device)
            homekitViewers = try c.decodeIfPresent(Int.self, forKey: .homekitViewers)
            instantLive = try c.decodeIfPresent(Bool.self, forKey: .instantLive)
            homekitVideo = try c.decodeIfPresent(HomeKitVideo.self, forKey: .homekitVideo)
            homekitRecording = try c.decodeIfPresent(Bool.self, forKey: .homekitRecording)
            detection = try c.decodeIfPresent(Bool.self, forKey: .detection)
            recordsSub = try c.decodeIfPresent(Bool.self, forKey: .recordsSub)
            homekitMotion = try c.decodeIfPresent(HomeKitMotion.self, forKey: .homekitMotion)
        }

        /// Reolink's stream addresses for a camera at this host.
        public static func reolink(id: String, name: String, host: String, username: String) -> Camera {
            Camera(id: id, name: name, main: "rtsp://\(host):554/h264Preview_01_main",
                   sub: "rtsp://\(host):554/h264Preview_01_sub", username: username)
        }
    }

    /// A camera's own description of itself (Reolink's GetDevInfo, or ONVIF's GetDeviceInformation).
    public struct Device: Codable, Equatable, Sendable {
        public var manufacturer: String
        public var model: String
        public var serial: String?
        public var firmware: String?
        /// The camera says it is a doorbell.
        public var isDoorbell: Bool
        /// Which provider recognised it ("reolink", "onvif"): the one asked for its other features. Or
        /// `videoOnly`: chosen to be talked to only for its video (no logins for details or events).
        public var provider: String?

        /// The provider set to mean: the camera's video only.
        public static let videoOnly = "video"
        public var isVideoOnly: Bool { provider == Self.videoOnly }
        /// What can be controlled on it (PTZ, talking back, night mode), and through which provider each: worked
        /// out when it is identified, so the app shows only the controls that work. Nil until then.
        public var controls: Controls?

        public init(manufacturer: String, model: String, serial: String? = nil, firmware: String? = nil,
                    isDoorbell: Bool = false, provider: String? = nil) {
            self.provider = provider
            self.manufacturer = manufacturer
            self.model = model
            self.serial = serial
            self.firmware = firmware
            self.isDoorbell = isDoorbell
        }
    }

    /// A camera's controls, each with the provider that serves it (a camera's own make's, else ONVIF's): its
    /// PTZ and talking back (drawn by controls of their own), and the rest as items, each a switch, a choice, a
    /// slider or an action, in one of four groups, which the app draws as they're described.
    public struct Controls: Codable, Equatable, Sendable {
        public var ptz: PTZ?
        public var talk: Talk?
        public var items: [Item]

        public init(ptz: PTZ? = nil, talk: Talk? = nil, items: [Item] = []) {
            self.ptz = ptz
            self.talk = talk
            self.items = items
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ptz = try c.decodeIfPresent(PTZ.self, forKey: .ptz)
            talk = try c.decodeIfPresent(Talk.self, forKey: .talk)
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        }

        public var isEmpty: Bool { ptz == nil && talk == nil && items.isEmpty }

        /// Moving the picture: pan and tilt, zoom, and positions kept by the camera.
        public struct PTZ: Codable, Equatable, Sendable {
            public var provider: String
            public var panTilt: Bool
            public var zoom: Bool
            /// How many positions it can keep; 0 if none.
            public var presets: Int

            public init(provider: String, panTilt: Bool, zoom: Bool, presets: Int) {
                self.provider = provider
                self.panTilt = panTilt
                self.zoom = zoom
                self.presets = presets
            }
        }

        /// Sound to the camera's speaker.
        public struct Talk: Codable, Equatable, Sendable {
            public var provider: String

            public init(provider: String) { self.provider = provider }
        }

        /// One control, as the app draws it: what it is, where it goes, what kind it is.
        public struct Item: Codable, Equatable, Sendable, Identifiable {
            /// Where it goes: the same place for every camera ("dayNight" first under Picture), whichever
            /// provider serves it.
            public enum Group: String, Codable, Sendable, CaseIterable {
                case move, picture, light, sound, device

                public var title: String {
                    switch self {
                    case .move: "Move"
                    case .picture: "Picture"
                    case .light: "Light"
                    case .sound: "Sound"
                    case .device: "Device"
                    }
                }

                public var symbol: String {
                    switch self {
                    case .move: "move.3d"
                    case .picture: "camera.aperture"
                    case .light: "lightbulb"
                    case .sound: "speaker.wave.2"
                    case .device: "gearshape"
                    }
                }
            }

            public enum Kind: Codable, Equatable, Sendable {
                /// On or off.
                case toggle
                /// One of a few.
                case choice([Choice])
                /// A number in a range.
                case slider(min: Double, max: Double, step: Double)
                /// Done when pressed; `confirm` asks first, in those words (a siren, a door).
                case action(confirm: String?)
            }

            public struct Choice: Codable, Equatable, Sendable, Hashable {
                public var value: String
                public var title: String
                public var symbol: String

                public init(value: String, title: String, symbol: String) {
                    self.value = value
                    self.title = title
                    self.symbol = symbol
                }
            }

            /// Stable across providers: "dayNight", "brightness", "speakerVolume", "home.go", "relay.<token>".
            public var id: String
            public var title: String
            public var symbol: String
            public var group: Group
            /// Its place in its group.
            public var order: Int
            public var kind: Kind
            public var provider: String

            public init(id: String, title: String, symbol: String, group: Group, order: Int, kind: Kind, provider: String) {
                self.id = id
                self.title = title
                self.symbol = symbol
                self.group = group
                self.order = order
                self.kind = kind
                self.provider = provider
            }
        }

        /// An item's value: a switch's, a choice's, a slider's.
        public enum Value: Codable, Equatable, Sendable {
            case on(Bool)
            case choice(String)
            case number(Double)
        }
    }

    /// An area of the picture, as a polygon in fractions of the frame: (0, 0) is top left, (1, 1) bottom right.
    /// A part of a camera's picture, a polygon in fractions of it. A watched zone (the default): once a camera has
    /// any, events are made only from what's in one, by where it stands (the bottom middle of its box), and only
    /// of the kinds the zone takes. An ignored zone: nothing there counts, and nothing moving there (a tree in the
    /// wind, a busy road) starts the model.
    public struct Zone: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var points: [[Double]]
        /// Watched (nil) or ignored.
        public var kind: Kind?
        /// What a watched zone takes ("person", "vehicle", "animal", "package"); nil for all of them.
        public var categories: [String]?

        public enum Kind: String, Codable, Sendable, CaseIterable {
            case watch
            case ignore
        }

        public static let allCategories = ["person", "vehicle", "animal", "package", "item"]

        public init(id: String, name: String, points: [[Double]], kind: Kind? = nil, categories: [String]? = nil) {
            self.id = id
            self.name = name
            self.points = points
            self.kind = kind
            self.categories = categories
        }

        public var isIgnored: Bool { kind == .ignore }

        /// Whether a watched zone takes this kind of thing.
        public func takes(_ category: String) -> Bool { categories?.contains(category) ?? true }

        /// Whether a point (fractions of the picture) is inside (even–odd, so any polygon will do).
        public func contains(x: Double, y: Double) -> Bool {
            let p = points.filter { $0.count == 2 }
            guard p.count >= 3 else { return false }
            var inside = false
            var j = p.count - 1
            for i in p.indices {
                let (xi, yi, xj, yj) = (p[i][0], p[i][1], p[j][0], p[j][1])
                if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
            return inside
        }
    }
}

extension Config {
    /// Moves a camera to `position` (0 is first) in the order cameras are shown: their priority in the app's
    /// grid and timeline. Positions past either end are clamped. Returns false if there is no such camera.
    @discardableResult
    public mutating func moveCamera(_ id: String, to position: Int) -> Bool {
        guard let from = cameras.firstIndex(where: { $0.id == id }) else { return false }
        let camera = cameras.remove(at: from)
        cameras.insert(camera, at: max(0, min(position, cameras.count)))
        return true
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    /// Everything wrong with these settings, as sentences. Empty means the settings are usable.
    /// The app shows these next to the fields and refuses to save while there are any.
    public func problems() -> [String] {
        var out: [String] = []
        if version > Self.currentVersion {
            out.append("The settings were written by a newer pond (format \(version)); this one reads format \(Self.currentVersion).")
        }
        for (field, path) in [("storage.recordings", storage.recordings), ("storage.events", storage.events),
                              ("storage.database", storage.database)] {
            guard let path else { continue }
            if path.isEmpty {
                out.append("\(field) is empty.")
            } else if !Self.expand(path).hasPrefix("/") {
                out.append("\(field) must be a full path (starting with / or ~).")
            }
        }
        if retention.continuous.days < 1 { out.append("retention.continuous.days must be at least 1.") }
        if let max = retention.continuous.maxSizeGB, max <= 0 {
            out.append("retention.continuous.maxSizeGB must be more than 0, or left out for no limit.")
        }
        if retention.events.days < 1 { out.append("retention.events.days must be at least 1.") }
        if retention.minFreeGB < 0 { out.append("retention.minFreeGB must not be negative.") }
        if let signaling = remote?.signaling, !signaling.isEmpty,
           URL(string: signaling).map({ ["ws", "wss"].contains($0.scheme) && $0.host() != nil }) != true {
            out.append("remote.signaling must be a wss:// address (ws:// only for testing).")
        }
        for subnet in remote?.meshSubnets ?? [] where !Self.isSubnet(subnet) {
            out.append("remote.meshSubnets: \(subnet) isn\u{2019}t a range of addresses (100.64.0.0/10, fd7a:115c:a1e0::/48).")
        }

        var seen = Set<String>()
        for camera in cameras {
            let label = "Camera \(camera.id.isEmpty ? "(no id)" : camera.id)"
            if !Self.isSlug(camera.id) {
                out.append("\(label): the ID must be lowercase letters, digits and dashes, starting with a letter.")
            } else if !seen.insert(camera.id).inserted {
                out.append("\(label): the ID is used by more than one camera.")
            }
            if camera.name.isEmpty { out.append("\(label): the name is empty.") }
            if camera.username.isEmpty { out.append("\(label): the username is empty.") }
            for (field, url) in [("main", camera.main), ("sub", camera.sub)] {
                if let problem = Self.streamProblem(url) { out.append("\(label): \(field) \(problem)") }
            }
            var zoneIDs = Set<String>()
            for zone in camera.zones {
                let zlabel = "\(label), zone \(zone.id.isEmpty ? "(no id)" : zone.id)"
                if !Self.isSlug(zone.id) {
                    out.append("\(zlabel): the ID must be lowercase letters, digits and dashes, starting with a letter.")
                } else if !zoneIDs.insert(zone.id).inserted {
                    out.append("\(zlabel): the ID is used by more than one zone of this camera.")
                }
                if zone.points.count < 3 { out.append("\(zlabel): a zone needs at least 3 points.") }
                if zone.points.contains(where: { $0.count != 2 }) {
                    out.append("\(zlabel): each point must be [x, y].")
                } else if zone.points.flatMap({ $0 }).contains(where: { !(0 ... 1).contains($0) }) {
                    out.append("\(zlabel): points must be between 0 and 1 (fractions of the frame).")
                }
                if let categories = zone.categories {
                    if let unknown = categories.first(where: { !Zone.allCategories.contains($0) }) {
                        out.append("\(zlabel): \u{201C}\(unknown)\u{201D} isn\u{2019}t a kind of thing it can take (person, vehicle, animal, package, item).")
                    } else if categories.isEmpty, !zone.isIgnored {
                        out.append("\(zlabel): a watched zone needs at least one kind of thing to take.")
                    }
                }
            }
        }
        return out
    }

    public static func isSlug(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, ("a" ... "z").contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "-" }
    }

    /// "100.64.0.0/10", "fd7a:115c:a1e0::/48": an address and how many of its bits are the range's.
    static func isSubnet(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]), bits >= 0 else { return false }
        let address = parts[0]
        if address.contains(":") {
            let groups = address.split(separator: ":", omittingEmptySubsequences: false)
            guard bits <= 128, groups.count >= 3, groups.count <= 8, address.components(separatedBy: "::").count <= 2 else { return false }
            return groups.allSatisfy { $0.count <= 4 && $0.allSatisfy(\.isHexDigit) }
        }
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        return bits <= 32 && octets.count == 4 && octets.allSatisfy { Int($0).map { (0 ... 255).contains($0) } == true && !$0.isEmpty }
    }

    /// Why this stream address is unusable, or nil if it is fine.
    static func streamProblem(_ address: String) -> String? {
        // (A demo camera's, in demo mode: demo://.)
        guard let url = URLComponents(string: address), ["rtsp", Demo.scheme].contains(url.scheme?.lowercased()), let host = url.host,
              !host.isEmpty
        else { return "must be an rtsp:// address with a host." }
        if url.password != nil || url.user != nil {
            return "must not contain a login; the username goes in username and the password in the Keychain."
        }
        return nil
    }
}
