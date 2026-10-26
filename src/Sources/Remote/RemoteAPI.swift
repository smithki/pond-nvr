// The remote API: what a paired device (or another Pond) asks a Pond over a session's control channel, and how it's
// answered (RemoteAPI.Server, the service's sessions' `requests`). A request is an action and a JSON body; a reply,
// a body or why not:
//
//   cameras           → [Camera]: each camera's id, name and kind, whether it's private (or waking), its model
//   events            EventsRequest (begun since a time, or by their ids; one camera's or all; at most `limit`, the
//                     newest) → [Event], oldest first: what was seen, its sentence, its picture and clip
//   picture, clip     Piece (an event's, from `offset`, at most `length`, up to 1 MB) → the file's bytes as they are;
//                     a piece shorter than asked for is its end
//   control           a ControlSocket.Request → its Reply: the cameras' controls, privacy and search, as the app asks
//                     for them on the Mac itself (not pairing, the settings or talking back)
//   live.start, stop  a camera's live video (RemoteVideo)
//   ping              answered by PathSessions
//
// Files are read only from the events folder, and only as an event's own picture or clip: never a path a device
// names.
import Detection
import Devices
import Foundation
import Ingest
import NVRCore
import Understanding
import Watch

public enum RemoteAPI {
    /// A camera, as a device is shown it.
    public struct Camera: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var doorbell: Bool
        /// Made private in Pond (no video, nothing watched); starting its video again after its own privacy mode.
        public var isPrivate: Bool
        public var waking: Bool
        /// It has a sub-stream (smaller: for live video over a weak link).
        public var subStream: Bool
        public var model: String?
    }

    public struct EventsRequest: Codable, Sendable {
        /// Begun since then; or these (still kept).
        public var since: Date?
        public var ids: [String]?
        /// One camera's (its id or name), or all.
        public var camera: String?
        /// At most this many, the newest (200 unless asked; never more than 1,000).
        public var limit: Int?

        public init(since: Date? = nil, ids: [String]? = nil, camera: String? = nil, limit: Int? = nil) {
            self.since = since
            self.ids = ids
            self.camera = camera
            self.limit = limit
        }
    }

    public struct Event: Codable, Sendable, Equatable {
        public var id: String
        /// Its camera's id.
        public var camera: String
        public var start: Date
        public var end: Date
        public var ongoing: Bool
        /// Its most important kind ("person", "vehicle", …), and everything seen, the most of each in one picture.
        public var category: String
        public var labels: [String: Int]
        /// What was seen, in words: "2 people and a dog".
        public var seen: String
        /// A sentence about it (the Mac's own model's), once there is one.
        public var sentence: String?
        /// The watched zones it was in (their ids).
        public var zones: [String]
        public var picture: Bool
        /// Its clip's size, once there's one, and the moment it begins.
        public var clipBytes: Int?
        public var clipStart: Date?
    }

    /// A piece of an event's picture or clip.
    public struct Piece: Codable, Sendable {
        public var event: String
        public var offset: Int
        public var length: Int

        public init(event: String, offset: Int, length: Int) {
            self.event = event
            self.offset = offset
            self.length = length
        }
    }

    static let pieceLength = 256 * 1024, longestPiece = 1 << 20
    static let eventsLimit = 200, mostEvents = 1000

    /// What a device may ask of the cameras' controls: what the app does with them, but talking back (which needs
    /// a connection of its own), pairing and the settings.
    static let controlActions: Set<String> = ["controls", "ptz.move", "ptz.stop", "ptz.presets", "ptz.goto", "ptz.save",
                                              "ptz.remove", "items.values", "item.get", "item.set", "item.do",
                                              "privacy.list", "privacy.set", "search"]

    /// The Pond being reached: each request answered.
    public final class Server: @unchecked Sendable {
        let cameras: @Sendable () -> [Config.Camera]
        let password: @Sendable (String) -> String?
        let events: EventStore?
        let eventsFolder: @Sendable () -> String
        let control: (@Sendable (ControlSocket.Request) async -> ControlSocket.Reply)?
        let privacy: PrivacyState
        public let live: LiveSender

        /// Over the cameras now (and their passwords), the events and their folder, and the cameras' controls (the
        /// service's ControlServer's `answer`).
        public init(cameras: @escaping @Sendable () -> [Config.Camera], password: @escaping @Sendable (String) -> String?,
                    events: EventStore?, eventsFolder: @escaping @Sendable () -> String,
                    control: (@Sendable (ControlSocket.Request) async -> ControlSocket.Reply)?, privacy: PrivacyState = .shared,
                    live: LiveSender) {
            self.cameras = cameras
            self.password = password
            self.events = events
            self.eventsFolder = eventsFolder
            self.control = control
            self.privacy = privacy
            self.live = live
        }

        public func serve(_ session: PathSessions.Session, action: String, body: Data?) async -> (Data?, String?) {
            switch action {
            case "cameras":
                return Self.encoded(cameras().map { camera in
                    Camera(id: camera.id, name: camera.name, doorbell: camera.kind == .doorbell, isPrivate: privacy.isPrivate(camera.id),
                           waking: privacy.isWaking(camera.id), subStream: !camera.sub.isEmpty, model: camera.device?.model)
                })
            case "events":
                guard let events else { return (nil, "events aren't kept") }
                guard let body, let ask = try? JSONDecoder().decode(EventsRequest.self, from: body), ask.since != nil || ask.ids != nil else {
                    return (nil, "which events?")
                }
                // (The camera by its id or name.)
                let camera = ask.camera.map { c in cameras().first { $0.id == c || $0.name == c }?.id ?? c }
                var kept = ask.ids.map { events.events(ids: Array($0.prefix(RemoteAPI.mostEvents))) }
                    ?? events.events(since: ask.since ?? Date(), camera: camera)
                if let camera { kept = kept.filter { $0.event.camera == camera } }
                return Self.encoded(described(kept.suffix(min(RemoteAPI.mostEvents, ask.limit ?? RemoteAPI.eventsLimit)), in: events))
            case "picture", "clip":
                return piece(action, body)
            case "control":
                guard let body, let request = try? JSONDecoder().decode(ControlSocket.Request.self, from: body) else { return (nil, "what to do?") }
                guard RemoteAPI.controlActions.contains(request.action) else { return (nil, "not supported remotely: \(request.action)") }
                guard let control else { return (nil, "the cameras' controls aren't ready") }
                return Self.encoded(await control(request))
            case "live.start":
                guard let body, let ask = try? JSONDecoder().decode(LiveRequest.self, from: body) else { return (nil, "what to watch?") }
                guard let camera = cameras().first(where: { $0.id == ask.camera || $0.name == ask.camera }) else {
                    return (nil, "no camera \(ask.camera)")
                }
                guard !privacy.isPrivate(camera.id) else { return (nil, "\(camera.name) is private") }
                guard let password = password(camera.id) else { return (nil, "\(camera.name) has no password") }
                let url = ask.main || camera.sub.isEmpty ? camera.main : camera.sub
                guard let answer = live.start(session, source: (url, camera.username, password), reencode: ask.reencode) else {
                    return (nil, "the session has no keys")
                }
                return Self.encoded(answer)
            case "live.stop":
                live.stop(session)
                return (nil, nil)
            default:
                return (nil, "not supported: \(action)")
            }
        }

        /// A session's ended: its stream, if it has one, stopped.
        public func ended(_ session: PathSessions.Session) { live.stop(session) }

        func described(_ kept: some Collection<EventStore.Kept>, in events: EventStore) -> [Event] {
            let understood = events.understanding(since: kept.map(\.event.start).min() ?? Date())
            return kept.map { k in
                let e = k.event
                let sentence = understood[e.id]?.description.flatMap { $0.isEmpty ? nil : $0 } ?? e.summary
                let clipBytes = k.clip.flatMap(file).flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }
                return Event(id: e.id, camera: e.camera, start: e.start, end: e.end, ongoing: k.ongoing, category: e.category.rawValue,
                             labels: e.labels, seen: CameraEvent.words(e.labels), sentence: sentence, zones: e.zones,
                             picture: e.snapshot != nil, clipBytes: clipBytes, clipStart: clipBytes == nil ? nil : k.clipStart)
            }
        }

        func piece(_ action: String, _ body: Data?) -> (Data?, String?) {
            guard let body, let ask = try? JSONDecoder().decode(Piece.self, from: body), ask.offset >= 0, ask.length > 0 else {
                return (nil, "which event's \(action)?")
            }
            guard let kept = events?.events(ids: [ask.event]).first else { return (nil, "no event \(ask.event)") }
            guard let name = action == "picture" ? kept.event.snapshot : kept.clip, let url = file(name) else {
                return (nil, action == "picture" ? "it has no picture" : "it has no clip (yet)")
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, "its \(action) is gone") }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(ask.offset))
                return (try handle.read(upToCount: min(ask.length, RemoteAPI.longestPiece)) ?? Data(), nil)
            } catch {
                return (nil, "its \(action) couldn't be read")
            }
        }

        /// A file the events folder names (an event's picture or clip): nil if it would be outside it.
        func file(_ name: String) -> URL? {
            let folder = URL(fileURLWithPath: eventsFolder()).standardizedFileURL
            let url = folder.appendingPathComponent(name).standardizedFileURL
            return url.path.hasPrefix(folder.path + "/") ? url : nil
        }

        static func encoded(_ value: some Encodable) -> (Data?, String?) {
            guard let data = try? JSONEncoder().encode(value) else { return (nil, "the answer couldn't be written") }
            return (data, nil)
        }
    }
}

/// A paired Pond's API, over a session with it.
public struct RemoteClient: Sendable {
    public let session: PathSessions.Session

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noDevice(String)
        /// No path to it (why, in words).
        case unreachable(String)
        case noAnswer
        /// It said no (why).
        case refused(String)
        case unreadable

        public var description: String {
            switch self {
            case let .noDevice(device): "no device \(device) (pond remote devices)"
            case let .unreachable(why): why
            case .noAnswer: "it didn't answer"
            case let .refused(why): why
            case .unreadable: "its answer couldn't be read"
            }
        }
    }

    public init(session: PathSessions.Session) { self.session = session }

    public func cameras() async throws(Failure) -> [RemoteAPI.Camera] {
        try decoded(await call("cameras"))
    }

    public func events(_ request: RemoteAPI.EventsRequest) async throws(Failure) -> [RemoteAPI.Event] {
        try decoded(await call("events", encoded(request)))
    }

    /// One of the cameras' controls, as the app asks for them (ControlSocket's).
    public func control(_ request: ControlSocket.Request) async throws(Failure) -> ControlSocket.Reply {
        try decoded(await call("control", encoded(request), timeout: 30))
    }

    /// A question answered: how it was read, and the events, best first.
    public func search(_ question: String) async throws(Failure) -> (result: SearchResult, events: [RemoteAPI.Event]) {
        var request = ControlSocket.Request(camera: "", action: "search")
        request.question = question
        let reply = try await control(request)
        if let error = reply.error { throw .refused(error.description) }
        guard let result = reply.search else { throw .unreadable }
        let found = try await events(.init(ids: result.ids, limit: RemoteAPI.mostEvents))
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (result, result.ids.compactMap { byID[$0] })
    }

    /// An event's picture (a JPEG).
    public func picture(_ event: String) async throws(Failure) -> Data {
        var all = Data()
        try await pieces("picture", event) { all.append($0) }
        return all
    }

    /// An event's clip (an MP4) kept at `file`: its size.
    public func clip(_ event: String, to file: URL) async throws(Failure) -> Int {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else {
            throw .refused("\(file.path) can't be written")
        }
        defer { try? handle.close() }
        var size = 0
        try await pieces("clip", event) { piece in
            try? handle.write(contentsOf: piece)
            size += piece.count
        }
        return size
    }

    /// A file asked for a piece at a time, each handed on, until one's shorter than asked for.
    func pieces(_ action: String, _ event: String, _ each: (Data) -> Void) async throws(Failure) {
        var offset = 0
        while true {
            let piece = try await call(action, encoded(RemoteAPI.Piece(event: event, offset: offset, length: RemoteAPI.pieceLength)), timeout: 30)
            each(piece)
            offset += piece.count
            if piece.count < RemoteAPI.pieceLength { return }
        }
    }

    func call(_ action: String, _ body: Data? = nil, timeout: Double = 15) async throws(Failure) -> Data {
        guard let reply = await session.ask(action, body, timeout: timeout) else { throw .noAnswer }
        if let error = reply.error { throw .refused(error) }
        return reply.body ?? Data()
    }

    func encoded(_ value: some Encodable) throws(Failure) -> Data {
        do { return try JSONEncoder().encode(value) } catch { throw .unreadable }
    }

    func decoded<T: Decodable>(_ data: Data) throws(Failure) -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw .unreadable }
    }
}

extension RemoteHost {
    /// Something asked of a paired Pond (by its id or name), over a session made for it and closed after.
    public func asking<T: Sendable>(_ device: String, _ work: (RemoteClient) async throws(RemoteClient.Failure) -> T)
        async throws(RemoteClient.Failure) -> T {
        guard let peer = devices().first(where: { $0.id == device || $0.name == device }) else { throw .noDevice(device) }
        let (outcome, opened) = await paths.open(to: peer)
        guard let session = opened else { throw .unreachable(outcome.summary) }
        defer { paths.close(session) }
        return try await work(RemoteClient(session: session))
    }
}
