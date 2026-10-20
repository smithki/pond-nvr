// `pond search QUESTION [--plain] [--top N]`: events that answer a question in plain words ("cats in the living room
// last night", "a man in a red jacket", "packages this week"), best first, as the Events view finds them: how the
// question was read (by the Mac's own model; --plain, by the plain rules), then the events, each with its sentence.
// Asked of the service, which does the searching (it has to be running).
#if canImport(NVRMac)
import Devices
import Foundation
import NVRCore
import Understanding
import Watch

enum SearchCommand {
    static func run(_ args: [String], configPath: String) -> Int32 {
        var args = args
        let plain = args.contains("--plain")
        args.removeAll { $0 == "--plain" }
        var top = 10
        if let i = args.firstIndex(of: "--top"), i + 1 < args.count, let n = Int(args[i + 1]) {
            top = n
            args.removeSubrange(i ... i + 1)
        }
        let question = args.joined(separator: " ")
        guard !question.isEmpty else { return fail("pond search QUESTION [--plain] [--top N]") }
        guard let config = try? ConfigStore(path: configPath).load() else { return fail("The settings can't be read (\(configPath)).") }
        guard let store = EventStore(path: config.storage.databasePath, readOnly: true) else { return fail("No events yet.") }

        // Asked of the service (search is done there, where what it takes is kept ready).
        var request = ControlSocket.Request(camera: "", action: "search")
        request.question = question
        request.plain = plain
        let client = ControlClient(path: ControlSocket.path(nextTo: configPath))
        let start = Date()
        let asked = request
        let reply = blocking { await client.ask(asked, timeout: 60) }
        guard let result = reply.search else {
            return fail(reply.error == .unreachable || reply.error == nil
                ? "Search is done by Pond's service, which isn't running (pond service start)."
                : "The search didn't go through: \(reply.error!.description)")
        }
        let query = result.query, byModel = result.byModel
        let readIn = Date().timeIntervalSince(start)
        print("Answered in \(String(format: "%.1f", readIn)) s, read \(byModel ? "by the Mac's own model" : "by the plain rules"):")
        if !query.kinds.isEmpty { print("  kinds: \(query.kinds.sorted().joined(separator: ", "))") }
        if !query.things.isEmpty { print("  things: \(query.things.sorted().joined(separator: ", "))") }
        if !query.cameras.isEmpty { print("  cameras: \(query.cameras.sorted().joined(separator: ", "))") }
        if !query.zones.isEmpty { print("  zones: \(query.zones.sorted().joined(separator: ", "))") }
        let format = DateFormatter()
        format.dateFormat = "EEE MMM d HH:mm"
        if let range = query.time.range { print("  from \(format.string(from: range.lowerBound)) to \(format.string(from: range.upperBound))") }
        if let hours = query.time.hours { print("  between \(hours.from):00 and \(hours.to):00") }
        if let appearance = query.appearance { print("  looking like: \(appearance)") }

        // (The events themselves, and their sentences, read here: to show them.)
        let since = Date().addingTimeInterval(-Double(config.retention.events.days) * 86400)
        let events = store.events(since: since).map(\.event)
        let understood = store.understanding(since: since)
        if result.appearanceIgnored { print("  (how they looked isn't used: no picture model, and no sentences yet)") }
        print("\n\(result.ids.count) event\(result.ids.count == 1 ? "" : "s"):")
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let names = Dictionary(config.cameras.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for id in result.ids.prefix(top) {
            guard let e = byID[id] else { continue }
            print("  \(format.string(from: e.start))  \(names[e.camera] ?? e.camera)  "
                + (understood[e.id]?.description.flatMap { $0.isEmpty ? nil : $0 } ?? CameraEvent.words(e.labels)))
        }
        return 0
    }

    static func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("✗ \(why)\n".utf8))
        return 1
    }

    /// Async work waited for (the command runs on a plain thread).
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task.detached {
            result = await work()
            done.signal()
        }
        done.wait()
        return result!
    }
}
#endif
