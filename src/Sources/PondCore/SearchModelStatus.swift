// What the service is doing about search's picture model, for the app to show (Settings › Search): written by the
// service to a file next to the settings whenever it changes, read by the app, as HomeKit's status is. Which version
// is in use, what's being downloaded and how far, when pond.camera was last asked and what it said. Problems are
// kinds, not log lines: the app says each in plain words.
import Foundation

public struct SearchModelStatus: Codable, Equatable, Sendable {
    public var updated: Date
    /// The service's process, to tell a live file from one left by a service that stopped.
    public var pid: Int32
    /// The version search uses now, if any: its id ("siglip2-v1", or "built-in") and name.
    public var current: Version?
    /// What's under way, if anything.
    public var activity: Activity?
    /// When pond.camera was last asked which versions there are, and whether it answered.
    public var lastCheck: Date?
    public var lastCheckAnswered: Bool?
    /// When a version was last downloaded and put in place.
    public var lastUpdate: Date?
    /// The last thing that went wrong, until a check or download works again.
    public var problem: Problem?

    public init(updated: Date = Date(), pid: Int32 = ProcessInfo.processInfo.processIdentifier, current: Version? = nil,
                activity: Activity? = nil, lastCheck: Date? = nil, lastCheckAnswered: Bool? = nil, lastUpdate: Date? = nil,
                problem: Problem? = nil) {
        self.updated = updated
        self.pid = pid
        self.current = current
        self.activity = activity
        self.lastCheck = lastCheck
        self.lastCheckAnswered = lastCheckAnswered
        self.lastUpdate = lastUpdate
        self.problem = problem
    }

    public struct Version: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public enum Activity: Codable, Equatable, Sendable {
        /// Asking pond.camera.
        case checking
        /// Downloading a version: bytes so far, of all.
        case downloading(id: String, name: String, received: Int64, total: Int64)
        /// Checking its hash and unpacking it.
        case installing(id: String, name: String)
    }

    public enum Problem: String, Codable, Equatable, Sendable, Error {
        /// pond.camera or the file's host couldn't be reached.
        case offline
        /// pond.camera answered with something that isn't a manifest.
        case badManifest
        /// No version in the manifest is signed with Pond's key (or none this Pond can use is).
        case unsigned
        /// The downloaded file isn't the one signed for (its size or SHA-256 differs): thrown away.
        case wrongFile
        /// Not enough room in Pond's support folder for it.
        case noRoom
        /// The archive couldn't be unpacked, or wasn't what Pond loads.
        case unpacking
    }

    /// Next to the settings file.
    public static func path(nextTo configPath: String) -> String {
        (NSString(string: configPath).deletingLastPathComponent as NSString).appendingPathComponent("search-model-status.json")
    }

    public static func read(_ path: String) -> SearchModelStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SearchModelStatus.self, from: data)
    }

    public func write(_ path: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
