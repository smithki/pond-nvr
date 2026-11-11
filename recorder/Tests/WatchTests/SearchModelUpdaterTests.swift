import CryptoKit
import Foundation
import PondCore
import Testing
import Understanding
@testable import Watch

/// The updater against files here (file:// for pond.camera and the archive's host), with a key of the test's own.
@Suite struct SearchModelUpdaterTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("search-model-updater-\(UUID().uuidString)")
    let key = Curve25519.Signing.PrivateKey()
    var support: URL { base.appendingPathComponent("Support") }
    var statusPath: String { base.appendingPathComponent("search-model-status.json").path }
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    /// An archive of a folder as Pond loads it (its models stand-ins), and its signed entry.
    func publish(_ id: String, name: String, minimumApp: String = "0.2.0", signedBy signer: Curve25519.Signing.PrivateKey? = nil,
                 tamper: Bool = false) throws -> SearchModels.Entry {
        let fm = FileManager.default
        let folder = base.appendingPathComponent("made/\(id)")
        try fm.createDirectory(at: folder.appendingPathComponent("siglip2-image.mlmodelc"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("siglip2-text.mlmodelc"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("siglip2-tokenizer.json"))
        let manifest = #"{"name": "\#(name)", "imageSize": 224, "tokens": 64, "dimensions": 768, "padID": 0, "lowercase": true, "logitScale": 1, "logitBias": 0}"#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("siglip2.json"))
        let archive = base.appendingPathComponent("\(id).aar")
        let aa = Process()
        aa.executableURL = URL(fileURLWithPath: "/usr/bin/aa")
        aa.arguments = ["archive", "-d", folder.path, "-o", archive.path]
        try aa.run()
        aa.waitUntilExit()
        let data = try Data(contentsOf: archive)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if tamper { try (data + Data("x".utf8)).write(to: archive) }
        var entry = SearchModels.Entry(id: id, name: name, format: 1, minimumApp: minimumApp, size: data.count, sha256: sha,
                                       urls: [archive], signature: "")
        entry.signature = try (signer ?? key).signature(for: entry.signed).base64EncodedString()
        return entry
    }

    func updater(_ entries: [SearchModels.Entry], manifest: URL? = nil) throws -> SearchModelUpdater {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = manifest ?? base.appendingPathComponent("manifest.json")
        if manifest == nil { try JSONEncoder().encode(SearchModels.Manifest(models: entries)).write(to: url) }
        return SearchModelUpdater(support: support, statusPath: statusPath, appVersion: "0.2.0", manifestURL: url,
                                  publicKey: publicKey, automatic: { true }, log: { _ in })
    }

    @Test func aSignedVersionIsDownloadedCheckedAndPutInPlace() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let v1 = try publish("siglip2-v1", name: "SigLIP 2 base")
        let updater = try updater([v1])
        let told = Told()
        updater.installed = { told.add($0.id) }
        let status = await updater.check()
        #expect(status.problem == nil)
        #expect(status.current == .init(id: "siglip2-v1", name: "SigLIP 2 base"))
        #expect(status.lastCheckAnswered == true && status.lastUpdate != nil && status.activity == nil)
        #expect(SearchModels.downloaded(in: support).map(\.id) == ["siglip2-v1"])
        #expect(told.ids == ["siglip2-v1"])
        // And the app reads the same from the file.
        #expect(SearchModelStatus.read(statusPath)?.current?.id == "siglip2-v1")
        // Asked again, there's nothing to download.
        _ = await updater.check()
        #expect(told.ids == ["siglip2-v1"])
    }

    @Test func aNewerVersionIsAddedBesideTheOld() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let v1 = try publish("siglip2-v1", name: "SigLIP 2 base")
        _ = await (try updater([v1])).check()
        let v2 = try publish("siglip2-v2", name: "SigLIP 2 base v2")
        let status = await (try updater([v2, v1])).check()
        #expect(status.current?.id == "siglip2-v2")
        #expect(Set(SearchModels.downloaded(in: support).map(\.id)) == ["siglip2-v1", "siglip2-v2"])
    }

    @Test func aFileThatIsntTheOneSignedForIsThrownAway() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let v1 = try publish("siglip2-v1", name: "SigLIP 2 base", tamper: true)
        let status = await (try updater([v1])).check()
        #expect(status.problem == .wrongFile)
        #expect(status.current == nil)
        #expect(SearchModels.downloaded(in: support).isEmpty)
    }

    @Test func aVersionSignedByAnotherKeyIsntDownloaded() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let v1 = try publish("siglip2-v1", name: "SigLIP 2 base", signedBy: Curve25519.Signing.PrivateKey())
        let status = await (try updater([v1])).check()
        #expect(status.problem == .unsigned)
        #expect(SearchModels.downloaded(in: support).isEmpty)
    }

    @Test func aVersionForANewerPondIsLeftAlone() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let v1 = try publish("siglip2-v1", name: "SigLIP 2 base", minimumApp: "0.3.0")
        let status = await (try updater([v1])).check()
        #expect(status.problem == nil && status.current == nil)
        #expect(SearchModels.downloaded(in: support).isEmpty)
    }

    @Test func noAnswerIsSaidAsOffline() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let status = await (try updater([], manifest: base.appendingPathComponent("nowhere.json"))).check()
        #expect(status.problem == .offline)
        #expect(status.lastCheckAnswered == false && status.lastCheck != nil)
    }

    @Test func aDownloadCarriesOnFromWhereItGotTo() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let v1 = try publish("siglip2-v1", name: "SigLIP 2 base")
        let updater = try updater([v1])
        // Half of it there already, as a stopped download leaves it; the rest asked for (a file:// URL sends it all,
        // as a server that ignores the range would: it's started again, and still comes out whole).
        try FileManager.default.createDirectory(at: updater.partials, withIntermediateDirectories: true)
        let whole = try Data(contentsOf: v1.urls[0])
        try whole.prefix(whole.count / 2).write(to: updater.partials.appendingPathComponent("siglip2-v1.aar"))
        let status = await updater.check()
        #expect(status.problem == nil && status.current?.id == "siglip2-v1")
    }

    @Test func itsDueWeeklyAndSoonerWithNothingYet() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let updater = try updater([])
        #expect(updater.due)
        SearchModelStatus(lastCheck: Date().addingTimeInterval(-86400), lastCheckAnswered: true).write(statusPath)
        #expect(!(try self.updater([])).due)
        SearchModelStatus(lastCheck: Date().addingTimeInterval(-8 * 86400), lastCheckAnswered: true).write(statusPath)
        #expect((try self.updater([])).due)
        SearchModelStatus(lastCheck: Date().addingTimeInterval(-7200), lastCheckAnswered: false).write(statusPath)
        #expect((try self.updater([])).due)
    }
}

/// What the updater told of, from its tasks.
final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ id: String) { lock.withLock { all.append(id) } }
    var ids: [String] { lock.withLock { all } }
}

/// The real thing, when asked for (POND_NETWORK_TESTS=1): pond.camera's manifest, Pond's own key, the published
/// archive downloaded (about 350 MB, into a temporary folder), and what's put in place loaded by SigLIP.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["POND_NETWORK_TESTS"] == "1"))
struct SearchModelUpdaterNetworkTests {
    @Test func pondCamerasPublishedVersionIsDownloadedAndLoads() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("search-model-network-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let updater = SearchModelUpdater(support: base, statusPath: base.appendingPathComponent("status.json").path,
                                         appVersion: "0.2.0", automatic: { true }, log: { print($0) })
        let status = await updater.check()
        #expect(status.problem == nil)
        let installed = try #require(SearchModels.downloaded(in: base).first)
        #expect(installed.id == "siglip2-v1")
        let siglip = try SigLIP(folder: installed.folder, pictures: false)
        #expect(siglip.manifest.name == "SigLIP 2 base")
        #expect(try siglip.embed("a person").count == siglip.manifest.dimensions)
    }
}
