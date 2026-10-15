// Reads and writes the settings file. The app saves through here: settings with problems are refused, the
// write is atomic (a crash leaves the old file or the new one, never half of each), and the file is
// readable only by its owner.
import Foundation

public struct ConfigStore: Sendable {
    public let path: String

    public init(path: String = ConfigStore.defaultPath) {
        self.path = path
    }

    /// Where the settings file is unless POND_CONFIG or --config says otherwise.
    public static var defaultPath: String {
        Config.expand(Brand.supportFolder + "/config.json")
    }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case unreadable(path: String, reason: String)
        case invalidJSON(path: String, reason: String)
        case invalidSettings([String])
        case unwritable(path: String, reason: String)

        public var description: String {
            switch self {
            case let .unreadable(path, reason): "Cannot read \(path): \(reason)."
            case let .invalidJSON(path, reason): "\(path) is not a valid settings file: \(reason)."
            case let .invalidSettings(problems): "The settings were not saved: \(problems.joined(separator: " "))"
            case let .unwritable(path, reason): "Cannot write \(path): \(reason)."
            }
        }
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    public func load() throws(Error) -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw .unreadable(path: path, reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw .invalidJSON(path: path, reason: "\(Self.where_(context.codingPath + [key])) is missing")
        } catch let DecodingError.typeMismatch(_, context) {
            throw .invalidJSON(path: path, reason: "\(Self.where_(context.codingPath)) has the wrong type")
        } catch let DecodingError.valueNotFound(_, context) {
            throw .invalidJSON(path: path, reason: "\(Self.where_(context.codingPath)) is null")
        } catch {
            throw .invalidJSON(path: path, reason: "the JSON does not parse")
        }
    }

    /// Saves settings that have no problems. The folder is created if needed.
    public func save(_ config: Config) throws(Error) {
        let problems = config.problems()
        guard problems.isEmpty else { throw .invalidSettings(problems) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(config) + Data("\n".utf8)
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            throw .unwritable(path: path, reason: error.localizedDescription)
        }
    }

    /// A readable path such as `cameras[1].main` for a decoding error.
    private static func where_(_ path: [any CodingKey]) -> String {
        var out = ""
        for key in path {
            if let n = key.intValue {
                out += "[\(n)]"
            } else {
                out += out.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return out.isEmpty ? "the file" : out
    }
}
