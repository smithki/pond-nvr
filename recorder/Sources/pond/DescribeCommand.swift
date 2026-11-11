// `pond describe [EVENT-ID | PICTURE …] [--last N]`: the sentence the Mac's own language model writes for an event
// (or any picture), and how long it took: for trying what search will know of events. With no arguments, the last
// three events; --last N, the last N. An event's picture is given with a close-up of what began it, and what the
// detector found, as the service gives them.
#if canImport(PondMac)
import CoreGraphics
import Foundation
import ImageIO
import PondCore
import Understanding
import Watch

enum DescribeCommand {
    static func run(_ args: [String], configPath: String) -> Int32 {
        var args = args
        var last = 3
        if let i = args.firstIndex(of: "--last"), i + 1 < args.count, let n = Int(args[i + 1]) {
            last = n
            args.removeSubrange(i ... i + 1)
        }
        switch Describer.availability {
        case .available: break
        case .turnedOff: return fail("Apple Intelligence is off (System Settings › Apple Intelligence & Siri).")
        case .notReady: return fail("Apple Intelligence's model isn't ready yet (still downloading?).")
        case .notEligible: return fail("This Mac can't run Apple Intelligence.")
        case let .unavailable(why): return fail("The language model isn't available (\(why)).")
        }
        let config = try? ConfigStore(path: configPath).load()
        let store = config.flatMap { EventStore(path: $0.storage.databasePath, readOnly: true) }
        let events = store?.events(since: Date().addingTimeInterval(-90 * 86400)).map(\.event) ?? []

        // What to describe: events by id, pictures by path; or the last ones.
        var jobs: [(name: String, picture: URL, box: CGRect?, found: [String: Int])] = []
        let eventsFolder = config?.storage.eventsPath ?? ""
        func job(_ event: CameraEvent) -> (String, URL, CGRect?, [String: Int])? {
            guard let snapshot = event.snapshot else { return nil }
            let box = event.box.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            return ("\(event.camera) \(event.start.formatted(date: .abbreviated, time: .standard))",
                    URL(fileURLWithPath: (eventsFolder as NSString).appendingPathComponent(snapshot)), box, event.labels)
        }
        if args.isEmpty {
            jobs = events.filter { $0.snapshot != nil }.suffix(last).reversed().compactMap(job)
        }
        for arg in args {
            if let event = events.first(where: { $0.id == arg }), let j = job(event) {
                jobs.append(j)
            } else if FileManager.default.fileExists(atPath: arg) {
                jobs.append((arg, URL(fileURLWithPath: arg), nil, [:]))
            } else {
                return fail("No event or picture \(arg).")
            }
        }
        guard !jobs.isEmpty else { return fail("No events with pictures.") }

        let describer = Describer()
        var failed = false
        for job in jobs {
            guard let source = CGImageSourceCreateWithURL(job.picture as CFURL, nil),
                  let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("\(job.name): ✗ can't read \(job.picture.path)")
                failed = true
                continue
            }
            let closeUp = job.box.flatMap { CloseUp.crop(picture, box: $0) }
            let start = Date()
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: Result<String, any Error> = .success("")
            Task.detached {
                do { result = .success(try await describer.describe(picture: picture, closeUp: closeUp, found: job.found)) } catch { result = .failure(error) }
                done.signal()
            }
            done.wait()
            let seconds = Date().timeIntervalSince(start)
            switch result {
            case let .success(sentence): print("\(job.name)  (\(String(format: "%.1f", seconds)) s\(closeUp == nil ? "" : ", with a close-up"))\n  \(sentence)")
            case let .failure(error):
                print("\(job.name): ✗ \(error)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    static func fail(_ why: String) -> Int32 {
        FileHandle.standardError.write(Data("✗ \(why)\n".utf8))
        return 1
    }
}
#endif
