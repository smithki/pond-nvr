// The remote API: what a paired device (or another Pond) asks a Pond over a session's control channel, and how it's
// answered (RemoteAPI.Server, the service's sessions' `requests`). A request is an action and a JSON body; a reply,
// a body or why not:
//
//   health            → Health: how many cameras are recording, and what's wrong (for its devices to be told)
//   cameras           → [Camera]: each camera's id, name and kind, whether it's private (or waking), its model
//   events            EventsRequest (begun since a time, and before another if asked, or by their ids; one camera's
//                     or all; at most `limit`, the newest) → [Event], oldest first: what was seen, its sentence, its picture and clip
//   picture.info,     Piece (an event's; `offset` and `length` unused) → FileInfo: its size and SHA-256
//   clip.info
//   picture, clip     Piece (an event's, from `offset`, at most `length`, up to 1 MB) → the file's bytes as they are
//
// A file comes a few pieces at a time (as many in flight as fill a fast link), kept in order as they come, so a
// download that's cut off carries on from where it got to; checked against its SHA-256 at the end.
//   coverage          CoverageRequest (from, to) → Coverage: each camera's recorded stretches then ([start, end],
//                     seconds), when its recordings begin, and when it was private
//   still             StillRequest (a camera) → Still: its latest recorded picture (JPEG), and when
//   control           a ControlSocket.Request → its Reply: the cameras' controls, privacy and search, as the app asks
//                     for them on the Mac itself (not pairing, the settings or talking back)
//   live.start, stop  a camera's live video (RemoteVideo)
//   ping              answered by PathSessions
//
// Files are read only from the events folder, and only as an event's own picture or clip: never a path a device
// names.
import CryptoKit
import Detection
import Devices
import Foundation
import Ingest
import NVRCore
import Recorder
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
        /// Its controls, as the app's dock draws them (asked for through `control`).
        public var controls: Config.Controls?
    }

    /// How a Pond's recording is going, for the devices paired with it to be told when it stops: how many cameras
    /// are being recorded, and what's wrong ("its drive isn't there", "Porch: offline"). Private cameras are neither.
    public struct Health: Codable, Sendable, Equatable {
        public var recording: Int
        public var problems: [String]

        public init(recording: Int, problems: [String]) {
            self.recording = recording
            self.problems = problems
        }
    }

    public struct EventsRequest: Codable, Sendable {
        /// Begun since then; or these (still kept).
        public var since: Date?
        public var ids: [String]?
        /// One camera's (its id or name), or all.
        public var camera: String?
        /// At most this many, the newest (200 unless asked; never more than 1,000).
        public var limit: Int?
        /// Begun before then (with `since`: a stretch of time, as the Timeline shows one).
        public var until: Date?

        public init(since: Date? = nil, ids: [String]? = nil, camera: String? = nil, limit: Int? = nil, until: Date? = nil) {
            self.since = since
            self.ids = ids
            self.camera = camera
            self.limit = limit
            self.until = until
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
        /// Where its subject was in its picture (fractions), and how sure the model was of it, at best.
        public var box: Detection.Box?
        public var confidence: Double?
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

    /// A file's size and SHA-256 (hex), to check it by once it's all come.
    public struct FileInfo: Codable, Sendable {
        public var bytes: Int
        public var sha256: String
    }

    /// The stretch of time a camera's recordings are asked about.
    public struct CoverageRequest: Codable, Sendable {
        public var from: Date
        public var to: Date
        public init(from: Date, to: Date) {
            self.from = from
            self.to = to
        }
    }

    /// Each camera's recorded stretches (start and end, seconds since 1970), and when its recordings begin.
    public struct Coverage: Codable, Sendable {
        public var spans: [String: [[Double]]]
        public var earliest: [String: Double]
        /// When each was private then (start and end, as `spans`).
        public var `private`: [String: [[Double]]]?
    }

    /// A camera's latest recorded picture: asked for by its id.
    public struct StillRequest: Codable, Sendable {
        public var camera: String
        public init(camera: String) { self.camera = camera }
    }

    public struct Still: Codable, Sendable {
        public var time: Date
        public var jpeg: Data
    }

    /// Pieces of a file asked for (1 MB, at most), and how many at once.
    static let pieceLength = 1 << 20, longestPiece = 1 << 20, piecesInFlight = 4
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
        /// The recordings folder (for cameras' latest pictures).
        let recordings: @Sendable () -> String
        /// When each camera was private, between two times (the service's camera health).
        let privateSpans: @Sendable (Date, Date) -> [String: [ClosedRange<Date>]]
        let control: (@Sendable (ControlSocket.Request) async -> ControlSocket.Reply)?
        let privacy: PrivacyState
        public let live: LiveSender

        /// Over the cameras now (and their passwords), the events and their folder, and the cameras' controls (the
        /// service's ControlServer's `answer`).
        public init(cameras: @escaping @Sendable () -> [Config.Camera], password: @escaping @Sendable (String) -> String?,
                    events: EventStore?, eventsFolder: @escaping @Sendable () -> String,
                    recordings: @escaping @Sendable () -> String = { "" },
                    privateSpans: @escaping @Sendable (Date, Date) -> [String: [ClosedRange<Date>]] = { _, _ in [:] },
                    control: (@Sendable (ControlSocket.Request) async -> ControlSocket.Reply)?, privacy: PrivacyState = .shared,
                    live: LiveSender) {
            self.cameras = cameras
            self.password = password
            self.events = events
            self.eventsFolder = eventsFolder
            self.recordings = recordings
            self.privateSpans = privateSpans
            self.control = control
            self.privacy = privacy
            self.live = live
        }

        /// How its recording's going (set by the service).
        public var health: (@Sendable () -> Health)?

        public func serve(_ session: PathSessions.Session, action: String, body: Data?) async -> (Data?, String?) {
            switch action {
            case "health":
                guard let health else { return (nil, "not known") }
                return Self.encoded(health())
            case "cameras":
                return Self.encoded(cameras().map { camera in
                    Camera(id: camera.id, name: camera.name, doorbell: camera.kind == .doorbell, isPrivate: privacy.isPrivate(camera.id),
                           waking: privacy.isWaking(camera.id), subStream: !camera.sub.isEmpty, model: camera.device?.model,
                           controls: camera.device?.controls)
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
                if let until = ask.until { kept = kept.filter { $0.event.start < until } }
                return Self.encoded(described(kept.suffix(min(RemoteAPI.mostEvents, ask.limit ?? RemoteAPI.eventsLimit)), in: events))
            case "picture.info", "clip.info":
                return info(String(action.dropLast(5)), body)
            case "still":
                // A camera's latest recorded picture (not a private one's).
                guard let body, let ask = try? JSONDecoder().decode(StillRequest.self, from: body),
                      let camera = cameras().first(where: { $0.id == ask.camera }) else { return (nil, "which camera?") }
                guard !privacy.isPrivate(camera.id) else { return (nil, "\(camera.name) is private") }
                guard let still = await LatestStill.of(camera: camera.id, recordings: recordings()),
                      let jpeg = LatestStill.jpeg(still.image) else { return (nil, "nothing recorded lately") }
                return Self.encoded(Still(time: still.time, jpeg: jpeg))
            case "coverage":
                // Each camera's recorded stretches between two times (not a private one's: nothing's recorded then).
                guard let body, let ask = try? JSONDecoder().decode(CoverageRequest.self, from: body), ask.to > ask.from else {
                    return (nil, "when?")
                }
                let base = recordings()
                var out = Coverage(spans: [:], earliest: [:], private: [:])
                let kept = privateSpans(ask.from, ask.to)
                for camera in cameras() {
                    let spans = RecordingIndex.spans(base: base, camera: camera.id, from: ask.from, to: ask.to, writing: true)
                    out.spans[camera.id] = RecordingIndex.coverage(spans).map { [$0.lowerBound.timeIntervalSince1970, $0.upperBound.timeIntervalSince1970] }
                    out.earliest[camera.id] = RecordingIndex.earliest(base: base, camera: camera.id)?.timeIntervalSince1970
                    out.private?[camera.id] = (kept[camera.id] ?? []).map { [$0.lowerBound.timeIntervalSince1970, $0.upperBound.timeIntervalSince1970] }
                }
                return Self.encoded(out)
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
                // One stream (its SSRC, as answered), or all of the session's.
                let ssrc = body.flatMap { try? JSONDecoder().decode(LiveAnswer.self, from: $0) }?.ssrc
                live.stop(session, ssrc: ssrc)
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
                             picture: e.snapshot != nil, clipBytes: clipBytes, clipStart: clipBytes == nil ? nil : k.clipStart,
                             box: e.box, confidence: e.category == .ring ? nil : e.confidence)
            }
        }

        /// An event's picture or clip, as a request names it: where it is, and what of it's asked for; or why not.
        func located(_ kind: String, _ body: Data?) -> Result<(url: URL, piece: Piece), Refusal> {
            guard let body, let ask = try? JSONDecoder().decode(Piece.self, from: body), ask.offset >= 0, ask.length >= 0 else {
                return .failure(Refusal("which event's \(kind)?"))
            }
            guard let kept = events?.events(ids: [ask.event]).first else { return .failure(Refusal("no event \(ask.event)")) }
            guard let name = kind == "picture" ? kept.event.snapshot : kept.clip, let url = file(name) else {
                return .failure(Refusal(kind == "picture" ? "it has no picture" : "it has no clip (yet)"))
            }
            return .success((url, ask))
        }

        struct Refusal: Error {
            var why: String
            init(_ why: String) { self.why = why }
        }

        func info(_ kind: String, _ body: Data?) -> (Data?, String?) {
            let url: URL
            switch located(kind, body) {
            case let .success(found): url = found.url
            case let .failure(refusal): return (nil, refusal.why)
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, "its \(kind) is gone") }
            defer { try? handle.close() }
            var hash = SHA256()
            var bytes = 0
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hash.update(data: chunk)
                bytes += chunk.count
            }
            return Self.encoded(FileInfo(bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()))
        }

        func piece(_ kind: String, _ body: Data?) -> (Data?, String?) {
            let found: (url: URL, piece: Piece)
            switch located(kind, body) {
            case let .success(located): found = located
            case let .failure(refusal): return (nil, refusal.why)
            }
            guard found.piece.length > 0 else { return (nil, "which part of its \(kind)?") }
            guard let handle = try? FileHandle(forReadingFrom: found.url) else { return (nil, "its \(kind) is gone") }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(found.piece.offset))
                return (try handle.read(upToCount: min(found.piece.length, RemoteAPI.longestPiece)) ?? Data(), nil)
            } catch {
                return (nil, "its \(kind) couldn't be read")
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
        /// What came didn't match the file's hash.
        case damaged

        public var description: String {
            switch self {
            case let .noDevice(device): "no device \(device) (pond remote devices)"
            case let .unreachable(why): why
            case .noAnswer: "it didn't answer"
            case let .refused(why): why
            case .unreadable: "its answer couldn't be read"
            case .damaged: "it didn't arrive intact (try again)"
            }
        }
    }

    public init(session: PathSessions.Session) { self.session = session }

    public func health() async throws(Failure) -> RemoteAPI.Health {
        try decoded(await call("health"))
    }

    public func cameras() async throws(Failure) -> [RemoteAPI.Camera] {
        try decoded(await call("cameras"))
    }

    /// Each camera's recorded stretches between two times.
    public func coverage(from: Date, to: Date) async throws(Failure) -> RemoteAPI.Coverage {
        try decoded(await call("coverage", encoded(RemoteAPI.CoverageRequest(from: from, to: to)), timeout: 30))
    }

    public func still(_ camera: String) async throws(Failure) -> RemoteAPI.Still {
        try decoded(await call("still", encoded(RemoteAPI.StillRequest(camera: camera)), timeout: 20))
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
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pond-picture-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await download("picture", event, to: file)
        guard let picture = try? Data(contentsOf: file) else { throw .unreadable }
        return picture
    }

    /// An event's picture kept at `file`.
    public func picture(_ event: String, to file: URL, progress: Progress? = nil) async throws(Failure) -> Download {
        try await download("picture", event, to: file, progress: progress)
    }

    /// An event's clip (an MP4) kept at `file`.
    public func clip(_ event: String, to file: URL, progress: Progress? = nil) async throws(Failure) -> Download {
        try await download("clip", event, to: file, progress: progress)
    }

    /// Told as a download goes: the file it's kept in until it's whole (in order from the start, so what's there can be
    /// read as it grows), its size, and how much of it is there.
    public typealias Progress = @Sendable (_ partial: URL, _ bytes: Int, _ kept: Int) -> Void

    /// How a download went: its size, how long it took, and how much of it had come before (resumed).
    public struct Download: Sendable, Equatable {
        public var bytes: Int
        public var seconds: Double
        public var resumed: Int
    }

    /// An event's picture or clip (`kind`) kept at `file`: a few pieces at a time, kept in order beside it as they
    /// come (so a download that's cut off carries on where it got to, when asked again), checked against the
    /// file's SHA-256, then moved into place.
    func download(_ kind: String, _ event: String, to file: URL, progress: Progress? = nil) async throws(Failure) -> Download {
        let started = Date()
        let info: RemoteAPI.FileInfo = try decoded(await call("\(kind).info", encoded(RemoteAPI.Piece(event: event, offset: 0, length: 0)),
                                                              timeout: 60))
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".\(file.lastPathComponent).\(info.sha256.prefix(16)).partial")
        // What came before (of this same file: its hash is in the name).
        var hash = SHA256()
        var kept = 0
        if let before = try? Data(contentsOf: partial), before.count <= info.bytes {
            hash.update(data: before)
            kept = before.count
        } else {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw .refused("\(folder.path) can't be written to") }
        }
        let resumed = kept
        progress?(partial, info.bytes, kept)
        guard let handle = try? FileHandle(forWritingTo: partial) else { throw .refused("\(folder.path) can't be written to") }
        _ = try? handle.seekToEnd()
        let failure: Failure? = await withTaskGroup(of: (Int, Result<Data, Failure>).self) { group in
            var next = kept
            var arrived: [Int: Data] = [:]
            for _ in 0 ..< RemoteAPI.piecesInFlight where next < info.bytes {
                let at = next
                group.addTask { (at, await self.piece(kind, event, at)) }
                next += RemoteAPI.pieceLength
            }
            for await (at, result) in group {
                switch result {
                case let .failure(failure):
                    group.cancelAll()
                    return failure
                case let .success(piece):
                    arrived[at] = piece
                    // Kept in order: what's come after a piece still on its way waits for it.
                    while let piece = arrived.removeValue(forKey: kept) {
                        guard !piece.isEmpty, (try? handle.write(contentsOf: piece)) != nil else {
                            group.cancelAll()
                            return piece.isEmpty ? .damaged : .refused("\(folder.path) can't be written to")
                        }
                        hash.update(data: piece)
                        kept += piece.count
                        progress?(partial, info.bytes, kept)
                    }
                    if next < info.bytes {
                        let at = next
                        group.addTask { (at, await self.piece(kind, event, at)) }
                        next += RemoteAPI.pieceLength
                    }
                }
            }
            return nil
        }
        try? handle.close()
        if let failure { throw failure }
        guard kept == info.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == info.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            // (What was there before wasn't good: from the start again, once.)
            if resumed > 0 { return try await download(kind, event, to: file, progress: progress) }
            throw .damaged
        }
        try? FileManager.default.removeItem(at: file)
        do { try FileManager.default.moveItem(at: partial, to: file) } catch { throw .refused("\(file.path) can't be written") }
        return Download(bytes: info.bytes, seconds: Date().timeIntervalSince(started), resumed: resumed)
    }

    /// A piece of a file, asked for again if no answer comes (the channel resends what's lost; a session whose path
    /// is being found again takes a while).
    func piece(_ kind: String, _ event: String, _ offset: Int) async -> Result<Data, Failure> {
        var tries = 0
        while true {
            do throws(Failure) {
                return .success(try await call(kind, encoded(RemoteAPI.Piece(event: event, offset: offset, length: RemoteAPI.pieceLength)),
                                               timeout: 60))
            } catch .noAnswer where tries < 2 {
                tries += 1
            } catch {
                return .failure(error)
            }
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
