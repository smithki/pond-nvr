// The Events view's search: asked of the service (its SearchService, over the control socket), which reads the
// question and finds the events that answer it, keeping what that takes ready. The app loads no model of its own.
import Devices
import Foundation
import Understanding

enum EventSearcher {
    /// Why a question went unanswered.
    enum Problem: Error, Equatable {
        /// The service isn't running (search is done there).
        case serviceDown
        case failed(String)

        var words: String {
            switch self {
            case .serviceDown: "Search is done by Pond\u{2019}s background service, which isn\u{2019}t running."
            case let .failed(why): "The search didn\u{2019}t go through (\(why))."
            }
        }
    }

    /// A question answered by the service. `reading`: how it was read already (a part taken off it), not read again.
    static func search(_ question: String, reading: (EventQuery, Bool)? = nil, client: ControlClient) async -> Result<SearchResult, Problem> {
        var request = ControlSocket.Request(camera: "", action: "search")
        request.question = question
        request.reading = reading?.0
        request.byModel = reading?.1
        // (The first question after the service starts is read cold: a few seconds. A minute, at most.)
        let reply = await client.ask(request, timeout: 60)
        if let search = reply.search { return .success(search) }
        switch reply.error {
        case .unreachable?, nil: return .failure(.serviceDown)
        case let error?: return .failure(.failed(error.description))
        }
    }
}
