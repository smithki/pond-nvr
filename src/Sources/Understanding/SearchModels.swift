// Which versions of search's picture model Pond may use, and where they are on this Mac (docs/search.md, Published
// versions). pond.camera's manifest lists the published versions, newest first; Pond takes an entry only if its
// signature verifies with the model signing key's public half, carried here, so neither pond.camera nor the file's
// host can hand it a model that key didn't sign; then a file only if its SHA-256 is the entry's.
//
// Downloaded versions live in Search/<id>/ in Pond's support folder (not in Models, which is for detection models
// people add), each the archive's folder (what SigLIP
// loads) with a note of the archive it came from. A copy of Pond built with a model in it (Contents/Resources/Search)
// uses that until one is downloaded; POND_SEARCH_MODELS names a folder instead, for development.
import CryptoKit
import Foundation

public enum SearchModels {
    /// Where pond.camera says which versions there are.
    public static let manifestURL = URL(string: "https://pond.camera/api/search-model")!
    /// The model signing key's public half (models/search-signing.pub), Ed25519.
    public static let publicKey = "YElDtEdmCu8Lu4WWaU4RHAxrtd86pvwdd/p/BDSPuUk="
    /// The folder layouts this Pond reads: 1, Core ML's compiled models, siglip2.json and the tokenizer.
    public static let formats: Set<Int> = [1]

    public struct Manifest: Codable, Sendable, Equatable {
        public var models: [Entry]

        public init(models: [Entry]) { self.models = models }
    }

    /// A published version, as pond.camera lists it.
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var format: Int
        public var minimumApp: String
        public var size: Int
        public var sha256: String
        public var urls: [URL]
        public var published: String?
        public var signature: String

        public init(id: String, name: String, format: Int, minimumApp: String, size: Int, sha256: String, urls: [URL],
                    published: String? = nil, signature: String) {
            self.id = id
            self.name = name
            self.format = format
            self.minimumApp = minimumApp
            self.size = size
            self.sha256 = sha256
            self.urls = urls
            self.published = published
            self.signature = signature
        }

        /// What's signed: the fields, one per line in this order (scripts/search-model-sign.swift signs the same), so
        /// no JSON formatting can change it. The URLs aren't in it: where a file is doesn't matter, only its hash.
        public var signed: Data {
            Data(["pond search model", "id: \(id)", "name: \(name)", "format: \(format)", "minimumApp: \(minimumApp)",
                  "size: \(size)", "sha256: \(sha256)"].joined(separator: "\n").utf8)
        }

        /// Whether the entry was signed with the model signing key.
        public func verifies(publicKey: String = SearchModels.publicKey) -> Bool {
            guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
                  let signature = Data(base64Encoded: signature) else { return false }
            return key.isValidSignature(signature, for: signed)
        }
    }

    /// The version this Pond should use: the newest (first) entry signed with the key, in a format it reads, for a
    /// version of Pond no newer than this one. (A development build, "0.2.0-dev", has 0.2.0's code: it takes what
    /// 0.2.0 does.)
    public static func choose(_ manifest: Manifest, appVersion: String, publicKey: String = SearchModels.publicKey) -> Entry? {
        let app = String(appVersion.split(separator: "-", maxSplits: 1).first ?? "")
        return manifest.models.first { entry in
            entry.verifies(publicKey: publicKey) && formats.contains(entry.format) && !isNewer(entry.minimumApp, than: app)
        }
    }

    /// Whether version `a` comes after `b`: numbers compared part by part ("0.10.0" after "0.9.1"); a part after a
    /// hyphen ("0.2.0-dev") comes before the version without it.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> (numbers: [Int], pre: Bool) {
            let split = v.split(separator: "-", maxSplits: 1)
            return (split.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [], split.count > 1)
        }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.numbers.count, y.numbers.count) {
            let (p, q) = (i < x.numbers.count ? x.numbers[i] : 0, i < y.numbers.count ? y.numbers[i] : 0)
            if p != q { return p > q }
        }
        return y.pre && !x.pre
    }

    // MARK: On this Mac

    /// A version on this Mac: its folder, and the name its embeddings are kept under (its siglip2.json's).
    public struct Installed: Sendable, Equatable {
        public var id: String
        public var name: String
        public var folder: URL
        /// Downloaded (in the support folder's Search), rather than built into the app or named for development.
        public var downloaded: Bool
        /// When it was put there.
        public var installed: Date?

        public init(id: String, name: String, folder: URL, downloaded: Bool, installed: Date? = nil) {
            self.id = id
            self.name = name
            self.folder = folder
            self.downloaded = downloaded
            self.installed = installed
        }
    }

    /// Pond's support folder, where the settings are (POND_CONFIG's folder, in development).
    public static var support: URL {
        if let config = ProcessInfo.processInfo.environment["POND_CONFIG"] {
            return URL(fileURLWithPath: config).deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pond")
    }

    /// The folder downloaded versions are kept in, inside Pond's support folder.
    public static func folder(in support: URL) -> URL {
        support.appendingPathComponent("Search")
    }

    /// The name of the note each downloaded version's folder holds: the archive's SHA-256, written once it's whole.
    public static let installedMark = ".installed"

    /// The versions downloaded into `support`'s Search folder, whole ones only (with their note), newest first.
    public static func downloaded(in support: URL) -> [Installed] {
        let base = folder(in: support)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return ids.compactMap { id -> Installed? in
            let dir = base.appendingPathComponent(id)
            let mark = dir.appendingPathComponent(installedMark)
            guard FileManager.default.fileExists(atPath: mark.path), let name = manifestName(dir) else { return nil }
            let date = (try? FileManager.default.attributesOfItem(atPath: mark.path))?[.modificationDate] as? Date
            return Installed(id: id, name: name, folder: dir, downloaded: true, installed: date)
        }.sorted { ($0.installed ?? .distantPast) > ($1.installed ?? .distantPast) }
    }

    /// Every version this Pond could embed with, the one to embed with first: one named for development, else the
    /// downloaded ones (newest first), then the app's own.
    public static func available(support: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                                 bundle: URL? = Bundle.main.resourceURL) -> [Installed] {
        if let dev = environment["POND_SEARCH_MODELS"], let name = manifestName(URL(fileURLWithPath: dev)) {
            return [Installed(id: "development", name: name, folder: URL(fileURLWithPath: dev), downloaded: false)]
        }
        var all = downloaded(in: support)
        if let builtIn = bundle?.appendingPathComponent("Search"), let name = manifestName(builtIn), !all.contains(where: { $0.name == name }) {
            all.append(Installed(id: "built-in", name: name, folder: builtIn, downloaded: false))
        }
        return all
    }

    public static func manifestName(_ folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("siglip2.json")),
              let manifest = try? JSONDecoder().decode(SigLIP.Manifest.self, from: data) else { return nil }
        return manifest.name
    }
}
