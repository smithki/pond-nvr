// What the service's HomeKit is doing, camera by camera, for the app to show: written by the service to a
// file next to the settings whenever it changes, read by the app. Problems are kinds, not log lines: the
// app turns each into plain words and an action, and an unknown failure into "see the log", never a guess.
import Foundation

public struct HomeKitStatus: Codable, Equatable, Sendable {
    public var updated: Date
    /// The service's process, to tell a live file from one left by a service that stopped.
    public var pid: Int32
    public var cameras: [String: Camera]

    public init(updated: Date = Date(), pid: Int32 = ProcessInfo.processInfo.processIdentifier, cameras: [String: Camera] = [:]) {
        self.updated = updated
        self.pid = pid
        self.cameras = cameras
    }

    public struct Camera: Codable, Equatable, Sendable {
        /// Accepting connections from the Home app.
        public var running: Bool
        /// Added to a home (paired with at least one controller).
        public var paired: Bool
        /// Viewers watching it live in the Home app now.
        public var viewers: Int
        /// The latest problem, until whatever failed works again.
        public var problem: Problem?
        /// For doorbells: whether presses of the button can be seen.
        public var doorbell: DoorbellState?
        /// HomeKit Secure Video, for a camera Pond offers to it.
        public var recording: Recording?
        /// The setup code and the Home app's QR payload, only while not yet added to a home: the app shows
        /// them without reading the Keychain item the service keeps them in (two programs sharing one item
        /// made macOS ask again and again).
        public var setup: Setup?

        public struct Setup: Codable, Equatable, Sendable {
            public var code: String
            public var uri: String
            public init(code: String, uri: String) {
                self.code = code
                self.uri = uri
            }
        }

        public init(running: Bool = false, paired: Bool = false, viewers: Int = 0, problem: Problem? = nil,
                    doorbell: DoorbellState? = nil, setup: Setup? = nil) {
            self.setup = setup
            self.running = running
            self.paired = paired
            self.viewers = viewers
            self.problem = problem
            self.doorbell = doorbell
        }
    }

    /// HomeKit Secure Video for one camera: what the Home app has it set to, and how its recordings go.
    public struct Recording: Codable, Equatable, Sendable {
        /// Recording turned on in the Home app (its Recording Options), and its sound.
        public var on = false
        public var sound = false
        /// The home hub has chosen how to record (until it has, it records nothing).
        public var chosen = false
        /// The camera can tell Pond about motion, which is what starts a recording.
        public var motion = true
        /// A recording being sent now.
        public var recording = false
        public var lastClip: Clip?
        public var problem: RecordingProblem?

        public init() {}

        public struct Clip: Codable, Equatable, Sendable {
            public var at: Date
            public var seconds: Double
            public var bytes: Int
            public init(at: Date, seconds: Double, bytes: Int) {
                self.at = at
                self.seconds = seconds
                self.bytes = bytes
            }
        }
    }

    public struct RecordingProblem: Codable, Equatable, Sendable {
        public var kind: Kind
        public var at: Date
        public init(_ kind: Kind, at: Date = Date()) {
            self.kind = kind
            self.at = at
        }

        public enum Kind: String, Codable, Sendable {
            /// The hub asked to record while recording was off, or the camera off, in the Home app.
            case notAllowed
            /// The hub hadn't chosen how to record.
            case notChosen
            /// The camera's stream couldn't be read for it.
            case noVideo
            /// The hub ended a recording with an error.
            case cutShort
            /// Anything else: details in the log.
            case other
        }
    }

    public struct Problem: Codable, Equatable, Sendable {
        public var kind: Kind
        /// What was being done: the Home app's live view, a snapshot, starting.
        public var during: Activity
        public var at: Date

        public init(_ kind: Kind, during: Activity, at: Date = Date()) {
            self.kind = kind
            self.during = during
            self.at = at
        }

        public enum Kind: String, Codable, Sendable {
            /// The camera did not answer at its address.
            case cameraUnreachable
            /// The camera turned the saved login down.
            case loginRefused
            /// It took the connection but did not answer the request for video.
            case noAnswer
            /// Connected, but no video came.
            case noVideo
            /// There is no password for the camera in the Keychain.
            case noPassword
            /// The accessory could not start listening for the Home app.
            case couldNotStart
            /// Anything else: details are in the log.
            case other
        }

        public enum Activity: String, Codable, Sendable {
            case starting
            case liveView
            case snapshot
        }
    }

    public enum DoorbellState: String, Codable, Sendable {
        case watching
        /// The camera does not report presses in a way pond can read.
        case notSupported
        case cameraUnreachable
        case loginRefused
        /// The camera never said what it is, so there is no way known to watch its button.
        case unknownModel
        /// Set to video only: its button is not watched, by choice.
        case videoOnly
    }

    /// Next to the settings file.
    public static func path(nextTo configPath: String) -> String {
        (NSString(string: configPath).deletingLastPathComponent as NSString).appendingPathComponent("homekit-status.json")
    }

    public static func read(_ path: String) -> HomeKitStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HomeKitStatus.self, from: data)
    }

    public func write(_ path: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        // It can hold a setup code: for its owner only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
