import Detection
import Foundation
import Testing
import Understanding
@testable import Watch

/// A new version of search's picture model taken up: while events are embedded again by it, each is compared by the
/// version it's embedded by; what's said of events is compared like with like; and once every event is embedded by
/// the new one, the feedback's brought over and the old download deleted.
struct SearchModelSwitchTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("search-model-switch-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ id: String, minutes: Double = 0) -> CameraEvent {
        let at = start.addingTimeInterval(minutes * 60)
        return CameraEvent(id: id, camera: "drive", start: at, end: at.addingTimeInterval(10), category: .person,
                           labels: ["person": 1], confidence: 0.8, snapshot: "\(id).jpg")
    }

    @Test func eachEventIsComparedByItsOwnVersion() {
        // Two versions whose embeddings aren't comparable: "v1"'s phrase points one way, "v2"'s another.
        let a = event("a"), b = event("b", minutes: 1)
        let understood: [String: EventStore.Understood] = [
            "a": .init(scene: [1, 0, 0], embedder: "v1"),
            "b": .init(scene: [0, 1, 0], embedder: "v2"),
        ]
        let sure: (Double) -> Double = { $0 > 0.9 ? 0.9 : 0 }
        let query = EventQuery(kinds: ["person"], appearance: "a red jacket")
        let both = EventSearch.answer(query, events: [a, b], understood: understood, cameraIDs: [], zoneIDs: [], words: nil,
                                      probability: nil, byModel: ["v1": .init(embedding: [1, 0, 0], probability: sure),
                                                                  "v2": .init(embedding: [0, 1, 0], probability: sure)])
        #expect(Set(both.hits.map(\.id)) == ["a", "b"])
        // With v2's phrase alone (v1 gone), a can't be matched by its picture: b only.
        let one = EventSearch.answer(query, events: [a, b], understood: understood, cameraIDs: [], zoneIDs: [], words: nil,
                                     probability: nil, byModel: ["v2": .init(embedding: [0, 1, 0], probability: sure)])
        #expect(one.hits.map(\.id) == ["b"])
    }

    @Test func whatsSaidIsComparedOnlyWithTheSameVersion() {
        let box = Detection.Box(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        var dismissed = EventFeedback(id: "d", camera: "drive", category: .person, start: start, box: box, verdict: .nothing,
                                      embedding: [1, 0, 0])
        dismissed.embedder = "v1"
        let judge = EventJudge(feedback: [dismissed])
        func judged(by embedder: String?) -> Quieted? {
            judge.judge(id: "n", camera: "drive", category: .person, start: start.addingTimeInterval(600), box: box,
                        embedding: [1, 0, 0], embedder: embedder)
        }
        #expect(judged(by: "v1") != nil)
        #expect(judged(by: "v2") == nil)
    }

    @Test func onceAllAreEmbeddedByTheNewOneTheOldIsRetired() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = try #require(EventStore(path: base.appendingPathComponent("pond.sqlite").path))
        // Kept: one event, now embedded by v2, said to be nothing while it was v1's; and one said of an event gone.
        store.save(event("kept"), ongoing: false)
        store.understood("kept", .init(scene: [0, 1, 0], embedder: "SigLIP 2 base v2"))
        var said = EventFeedback(id: "kept", camera: "drive", category: .person, start: start, box: nil, verdict: .nothing,
                                 embedding: [1, 0, 0])
        said.embedder = "SigLIP 2 base"
        store.record(said)
        var gone = said
        gone.id = "gone"
        store.record(gone)
        // Two downloaded versions on the Mac.
        func version(_ id: String, _ name: String) throws -> SearchModels.Installed {
            let folder = base.appendingPathComponent("Search/\(id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return SearchModels.Installed(id: id, name: name, folder: folder, downloaded: true)
        }
        let v2 = try version("siglip2-v2", "SigLIP 2 base v2"), v1 = try version("siglip2-v1", "SigLIP 2 base")
        let understander = Understander(store: store, eventsFolder: base.path, models: { [v2, v1] }, log: { _ in })
        understander.retire(keeping: v2)

        let feedback = Dictionary(uniqueKeysWithValues: store.feedback().map { ($0.id, $0) })
        #expect(feedback["kept"]?.embedder == "SigLIP 2 base v2" && feedback["kept"]?.embedding == [0, 1, 0])
        #expect(feedback["gone"]?.embedder == nil && feedback["gone"]?.embedding == nil)
        #expect(feedback["gone"]?.verdict == .nothing)   // (still said: its rule needs no embedding)
        #expect(!store.embeds(by: "SigLIP 2 base"))
        #expect(!FileManager.default.fileExists(atPath: v1.folder.path))
        #expect(FileManager.default.fileExists(atPath: v2.folder.path))
    }

    @Test func aVersionStillUsedIsKept() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = try #require(EventStore(path: base.appendingPathComponent("pond.sqlite").path))
        store.save(event("old"), ongoing: false)
        store.understood("old", .init(scene: [1, 0, 0], embedder: "SigLIP 2 base"))
        let folder = base.appendingPathComponent("Search/siglip2-v1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let v1 = SearchModels.Installed(id: "siglip2-v1", name: "SigLIP 2 base", folder: folder, downloaded: true)
        let v2 = SearchModels.Installed(id: "siglip2-v2", name: "SigLIP 2 base v2", folder: base, downloaded: true)
        Understander(store: store, eventsFolder: base.path, models: { [v2, v1] }, log: { _ in }).retire(keeping: v2)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }
}
