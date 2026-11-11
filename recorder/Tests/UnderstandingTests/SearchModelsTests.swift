import Foundation
import Testing
@testable import Understanding

/// The repository's root, from this file.
private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized

/// siglip2-v1 as pond.camera lists it, signed by CI with the model signing key.
private let v1 = SearchModels.Entry(
    id: "siglip2-v1", name: "SigLIP 2 base", format: 1, minimumApp: "0.2.0", size: 350_310_687,
    sha256: "eaae1d98dc24c66e725aa662b8909506ace61df1df83204fbf312cf62e1347b9",
    urls: [URL(string: "https://github.com/smithki/pond-models/releases/download/siglip2-v1/siglip2-v1.aar")!],
    published: "2026-11-10",
    signature: "YHmUoG1BajI8J62JZzO+KCcVqJtNaAJXXQRn1EOxRBlC5VUqwi31Tp9pkb5yZoOSVt3DPvW7Ygpk0eUNgc8QCw==")

@Suite struct SearchModelsTests {
    @Test func itsPublicKeyIsTheRepositorysOwn() throws {
        let file = try String(contentsOf: root.appendingPathComponent("models/search-signing.pub"), encoding: .utf8)
        #expect(file.trimmingCharacters(in: .whitespacesAndNewlines) == SearchModels.publicKey)
    }

    @Test func aPublishedEntryVerifies() {
        #expect(v1.verifies())
    }

    @Test func anEntryChangedInAnySignedFieldDoesnt() {
        var changed = v1
        changed.sha256 = String(repeating: "0", count: 64)
        #expect(!changed.verifies())
        changed = v1
        changed.minimumApp = "0.1.0"
        #expect(!changed.verifies())
        changed = v1
        changed.name = "SigLIP 2 base v2"
        #expect(!changed.verifies())
    }

    @Test func whereItsDownloadedFromIsntSigned() {
        var moved = v1
        moved.urls = [URL(string: "https://example.com/elsewhere.aar")!]
        #expect(moved.verifies())
    }

    @Test func anotherKeysSignatureIsRefused() {
        let other = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        #expect(!v1.verifies(publicKey: other))
        #expect(SearchModels.choose(.init(models: [v1]), appVersion: "1.0.0", publicKey: other) == nil)
    }

    @Test func theNewestItMayUseIsChosen() {
        var newer = v1
        newer.id = "siglip2-v2"
        newer.minimumApp = "0.3.0"   // (its signature no longer verifies, either)
        var unsigned = v1
        unsigned.id = "siglip2-v9"
        unsigned.signature = "bm90IGEgc2lnbmF0dXJl"
        var otherFormat = v1
        otherFormat.format = 2
        let manifest = SearchModels.Manifest(models: [unsigned, otherFormat, newer, v1])
        #expect(SearchModels.choose(manifest, appVersion: "0.2.0")?.id == "siglip2-v1")
        #expect(SearchModels.choose(manifest, appVersion: "0.1.0") == nil)
        // A development build of 0.2.0 takes what 0.2.0 does; one of 0.1.1 doesn't.
        #expect(SearchModels.choose(manifest, appVersion: "0.2.0-dev")?.id == "siglip2-v1")
        #expect(SearchModels.choose(manifest, appVersion: "0.1.1-dev") == nil)
    }

    @Test func versionsCompareByTheirNumbers() {
        #expect(SearchModels.isNewer("0.10.0", than: "0.9.1"))
        #expect(!SearchModels.isNewer("0.2.0", than: "0.2.0"))
        #expect(SearchModels.isNewer("0.2.1", than: "0.2"))
        #expect(SearchModels.isNewer("0.2.0", than: "0.2.0-dev"))
        #expect(!SearchModels.isNewer("0.2.0-dev", than: "0.2.0"))
        #expect(!SearchModels.isNewer("0.2.0", than: "0.10.0"))
    }

    @Test func pondCamerasManifestReadsAndOffersV1() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("site/data/search-models.json"))
        let manifest = try JSONDecoder().decode(SearchModels.Manifest.self, from: data)
        #expect(manifest.models.allSatisfy { $0.verifies() })
        #expect(SearchModels.choose(manifest, appVersion: "0.2.0")?.id == "siglip2-v1")
    }

    @Test func onlyWholeDownloadsAreFoundNewestFirst() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("search-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let base = SearchModels.folder(in: support)
        func put(_ id: String, name: String, whole: Bool, at date: Date) throws {
            let dir = base.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest = #"{"name": "\#(name)", "imageSize": 224, "tokens": 64, "dimensions": 768, "padID": 0, "lowercase": true, "logitScale": 1, "logitBias": 0}"#
            try Data(manifest.utf8).write(to: dir.appendingPathComponent("siglip2.json"))
            if whole {
                let mark = dir.appendingPathComponent(SearchModels.installedMark)
                try Data("x\n".utf8).write(to: mark)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: mark.path)
            }
        }
        try put("siglip2-v1", name: "SigLIP 2 base", whole: true, at: Date(timeIntervalSince1970: 1000))
        try put("siglip2-v2", name: "SigLIP 2 base v2", whole: true, at: Date(timeIntervalSince1970: 2000))
        try put("siglip2-v3", name: "SigLIP 2 base v3", whole: false, at: Date())
        #expect(SearchModels.downloaded(in: support).map(\.id) == ["siglip2-v2", "siglip2-v1"])
        #expect(SearchModels.available(support: support, environment: [:], bundle: nil).map(\.name) == ["SigLIP 2 base v2", "SigLIP 2 base"])
    }
}
