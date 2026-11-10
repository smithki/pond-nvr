// Search's picture model as the app shows it (Settings › General, Descriptions and search): what the service says it's
// doing (SearchModelStatus, the file it writes beside the settings), and Check for Updates (asked of it over its
// socket). In a demo, a made-up state instead, never pond.camera: POND_DEMO_SEARCH_MODEL picks which, for pictures
// of each (ready, the default; downloading, installing, indexing, none, offline).
import Foundation
import PondCore

extension AppModel {
    var searchModelStatusPath: String { SearchModelStatus.path(nextTo: store.path) }

    /// The status file, if the service that wrote it is still running (a demo's, made up).
    func readSearchModelStatus() -> SearchModelStatus? {
        if let demo = demoSearchModelStatus { return demo }
        guard let status = SearchModelStatus.read(searchModelStatusPath), kill(status.pid, 0) == 0 else { return nil }
        return status
    }

    /// Asks the service to check pond.camera now (and download what it finds); false if it couldn't be asked.
    func checkSearchModel() async -> Bool {
        if demoSearchModelStatus != nil { return true }
        let reply = await controlClient.ask(.init(camera: "", action: "search-model.check"), timeout: 5)
        return reply.error == nil
    }

    var demoSearchModelStatus: SearchModelStatus? { DemoSearchModel.status }
}

/// A demo's search model, made up.
@MainActor
enum DemoSearchModel: String {
    case ready, downloading, installing, indexing, none, offline

    static var state: DemoSearchModel? {
        guard DemoSession.scenario != nil else { return nil }
        return ProcessInfo.processInfo.environment["POND_DEMO_SEARCH_MODEL"].flatMap(DemoSearchModel.init(rawValue:)) ?? .ready
    }

    static var status: SearchModelStatus? {
        guard let state else { return nil }
        let now = Date()
        let v1 = SearchModelStatus.Version(id: "siglip2-v1", name: "SigLIP 2 base")
        let v2 = SearchModelStatus.Version(id: "siglip2-v2", name: "SigLIP 2 base v2")
        let checked = now.addingTimeInterval(-3 * 3600)
        switch state {
        case .ready:
            return .init(current: v1, lastCheck: checked, lastCheckAnswered: true, lastUpdate: now.addingTimeInterval(-9 * 86400))
        case .downloading:
            return .init(current: nil, activity: .downloading(id: v1.id, name: v1.name, received: 128_400_000, total: 350_310_687),
                         lastCheck: now, lastCheckAnswered: true)
        case .installing:
            return .init(current: v1, activity: .installing(id: v2.id, name: v2.name), lastCheck: now, lastCheckAnswered: true,
                         lastUpdate: now.addingTimeInterval(-40 * 86400))
        case .indexing:
            return .init(current: v2, lastCheck: now.addingTimeInterval(-600), lastCheckAnswered: true,
                         lastUpdate: now.addingTimeInterval(-540))
        case .none:
            return .init()
        case .offline:
            return .init(current: nil, lastCheck: checked, lastCheckAnswered: false, problem: .offline)
        }
    }
}
