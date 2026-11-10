// Search's picture model, downloaded and kept up to date by the service (docs/search.md, Published versions): weekly,
// or when the app asks (Check for Updates), it asks pond.camera which versions there are; if the one this Pond should
// use (SearchModels.choose: signed with Pond's key, in a format it reads, for its version) isn't on this Mac, it
// downloads it, checks its size and SHA-256 against the signed entry, unpacks it and puts it in place
// (Search/<id>/ in Pond's support folder). What it's doing is written to a status file for the app
// (SearchModelStatus).
//
// A download that stops (asleep, offline, the service restarted) carries on from where it got to next time. Nothing
// is put in place unless it's whole and is exactly the file signed for. Off (searchModelUpdates false), it does
// nothing by itself: only when asked.
import CryptoKit
import Foundation
import PondCore
import Understanding

public final class SearchModelUpdater: NSObject, @unchecked Sendable {
    let support: URL
    let statusPath: String
    let appVersion: String
    let manifestURL: URL
    let publicKey: String
    /// Whether it checks and downloads by itself.
    let automatic: @Sendable () -> Bool
    let log: @Sendable (String) -> Void
    /// Told of each version put in place, to start using it.
    public var installed: (@Sendable (SearchModels.Installed) -> Void)?

    /// How often it asks pond.camera, by itself.
    public static let interval: TimeInterval = 7 * 86400
    /// How often it looks whether that's due (so a Mac asleep at the time asks soon after it wakes).
    static let wake: Duration = .seconds(3600)

    private let lock = NSLock()
    private var status: SearchModelStatus
    private var busy = false
    private var task: Task<Void, Never>?
    /// The download under way: where it's written, how far, and how it ends.
    private var download: Download?
    private lazy var session = URLSession(configuration: Self.configuration, delegate: self, delegateQueue: Self.queue)

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    /// No cookies, no cache, nothing kept: one file asked for, and nothing about who asked.
    private static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        c.httpAdditionalHeaders = ["User-Agent": "Pond"]
        return c
    }

    public init(support: URL, statusPath: String, appVersion: String, manifestURL: URL = SearchModels.manifestURL,
                publicKey: String = SearchModels.publicKey, automatic: @escaping @Sendable () -> Bool,
                log: @escaping @Sendable (String) -> Void) {
        self.support = support
        self.statusPath = statusPath
        self.appVersion = appVersion
        self.manifestURL = manifestURL
        self.publicKey = publicKey
        self.automatic = automatic
        self.log = log
        // When it last asked, and what's in use, carried over from the last run.
        var status = SearchModelStatus.read(statusPath) ?? SearchModelStatus()
        status.pid = ProcessInfo.processInfo.processIdentifier
        status.activity = nil
        status.current = SearchModels.available(support: support).first.map { .init(id: $0.id, name: $0.name) }
        self.status = status
        super.init()
        write()
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                if automatic(), due { await check() }
                try? await Task.sleep(for: Self.wake)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// What's being done, and was.
    public var current: SearchModelStatus { lock.withLock { status } }

    /// Whether it's time to ask: never asked, or not for a week (or there's no model, and the last ask didn't answer).
    var due: Bool {
        lock.withLock {
            guard let last = status.lastCheck else { return true }
            if status.current == nil, status.lastCheckAnswered == false { return Date().timeIntervalSince(last) > 3600 }
            return Date().timeIntervalSince(last) >= Self.interval
        }
    }

    /// Asks pond.camera now, and downloads the version this Pond should use if it isn't here. One at a time: asked
    /// again while it's at it, it carries on with what it's doing.
    @discardableResult
    public func check() async -> SearchModelStatus {
        let start = lock.withLock { () -> Bool in
            guard !busy else { return false }
            busy = true
            status.activity = .checking
            return true
        }
        guard start else { return current }
        write()
        await run()
        lock.withLock {
            busy = false
            status.activity = nil
        }
        write()
        return current
    }

    /// The check itself: asked, and what it says done.
    private func run() async {
        let manifest: SearchModels.Manifest
        do {
            manifest = try await fetchManifest()
        } catch let problem as SearchModelStatus.Problem {
            update { $0.lastCheck = Date(); $0.lastCheckAnswered = problem != .offline; $0.problem = problem }
            log("search model: \(manifestURL.host ?? "pond.camera") \(problem == .offline ? "couldn't be reached" : "didn't send a manifest")")
            return
        } catch {
            update { $0.lastCheck = Date(); $0.lastCheckAnswered = false; $0.problem = .offline }
            return
        }
        update { $0.lastCheck = Date(); $0.lastCheckAnswered = true }

        guard let entry = SearchModels.choose(manifest, appVersion: appVersion, publicKey: publicKey) else {
            // None signed (or none for this Pond): nothing to do, and said so if none at all verifies.
            let signed = manifest.models.contains { $0.verifies(publicKey: publicKey) }
            update { $0.problem = signed ? nil : .unsigned }
            if !signed { log("! search model: pond.camera's manifest has no version signed with Pond's key") }
            return
        }
        if SearchModels.downloaded(in: support).contains(where: { $0.id == entry.id }) {
            update { $0.problem = nil }
            return
        }
        do {
            let installed = try await fetch(entry)
            update {
                $0.current = .init(id: installed.id, name: installed.name)
                $0.lastUpdate = Date()
                $0.problem = nil
            }
            log("search model: \(entry.name) (\(entry.id)) downloaded and in place")
            self.installed?(installed)
        } catch let problem as SearchModelStatus.Problem {
            update { $0.problem = problem }
            log("! search model: \(entry.id) not put in place (\(problem.rawValue))")
        } catch {
            update { $0.problem = .offline }
            log("search model: \(entry.id)'s download stopped (\(error.localizedDescription)); it carries on next time")
        }
    }

    // MARK: Asking and downloading

    func fetchManifest() async throws -> SearchModels.Manifest {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession(configuration: Self.configuration).data(from: manifestURL)
        } catch {
            throw SearchModelStatus.Problem.offline
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw SearchModelStatus.Problem.badManifest }
        guard let manifest = try? JSONDecoder().decode(SearchModels.Manifest.self, from: data) else {
            throw SearchModelStatus.Problem.badManifest
        }
        return manifest
    }

    /// The partial downloads' folder: hidden in Search, never taken for a version.
    var partials: URL { SearchModels.folder(in: support).appendingPathComponent(".partial") }

    /// Downloads, checks and puts in place one version.
    func fetch(_ entry: SearchModels.Entry) async throws -> SearchModels.Installed {
        let fm = FileManager.default
        try fm.createDirectory(at: partials, withIntermediateDirectories: true)
        let file = partials.appendingPathComponent("\(entry.id).aar")
        let have = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        // Room for the archive and what it unpacks to, with some to spare.
        let room = (try? partials.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard room > Int64(entry.size) * 2 - have + 200_000_000 else { throw SearchModelStatus.Problem.noRoom }

        if have < Int64(entry.size) {
            var lastError: Error?
            for url in entry.urls {
                do {
                    try await receive(url, into: file, entry: entry)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                }
            }
            if let lastError { throw lastError }
        }

        update { $0.activity = .installing(id: entry.id, name: entry.name) }
        write()
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        guard size == Int64(entry.size), try Self.sha256(file) == entry.sha256 else {
            try? fm.removeItem(at: file)
            throw SearchModelStatus.Problem.wrongFile
        }
        let unpacked = partials.appendingPathComponent(entry.id)
        try? fm.removeItem(at: unpacked)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard Self.unpack(file, into: unpacked), let name = SearchModels.manifestName(unpacked),
              fm.fileExists(atPath: unpacked.appendingPathComponent("siglip2-image.mlmodelc").path),
              fm.fileExists(atPath: unpacked.appendingPathComponent("siglip2-text.mlmodelc").path),
              fm.fileExists(atPath: unpacked.appendingPathComponent("siglip2-tokenizer.json").path) else {
            try? fm.removeItem(at: unpacked)
            try? fm.removeItem(at: file)
            throw SearchModelStatus.Problem.unpacking
        }
        let place = SearchModels.folder(in: support).appendingPathComponent(entry.id)
        try? fm.removeItem(at: place)
        try fm.moveItem(at: unpacked, to: place)
        try Data("\(entry.sha256)\n".utf8).write(to: place.appendingPathComponent(SearchModels.installedMark))
        try? fm.removeItem(at: file)
        return SearchModels.Installed(id: entry.id, name: name, folder: place, downloaded: true, installed: Date())
    }

    /// One URL's bytes appended to `file`, from where it got to (a range asked for; a server that sends it all
    /// instead starts it again), with the status kept up to date.
    func receive(_ url: URL, into file: URL, entry: SearchModels.Entry) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        let have = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        update { $0.activity = .downloading(id: entry.id, name: entry.name, received: have, total: Int64(entry.size)) }
        write()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = session.dataTask(with: request)
            lock.withLock {
                download = Download(task: task, handle: handle, received: have, entry: entry, continuation: continuation)
            }
            task.resume()
        }
    }

    static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// An Apple Archive unpacked (by macOS's own aa).
    static func unpack(_ archive: URL, into folder: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/aa")
        process.arguments = ["extract", "-i", archive.path, "-d", folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: Status

    private func update(_ change: (inout SearchModelStatus) -> Void) {
        lock.withLock { change(&status) }
        write()
    }

    private func write() {
        var status = lock.withLock { self.status }
        status.updated = Date()
        status.write(statusPath)
    }

    struct Download {
        let task: URLSessionDataTask
        let handle: FileHandle
        var received: Int64
        let entry: SearchModels.Entry
        let continuation: CheckedContinuation<Void, Error>
        var written = Date.distantPast
    }
}

extension SearchModelUpdater: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async
        -> URLSession.ResponseDisposition {
        // (A response that isn't HTTP's is a file://, in tests: all of it, as a 200.)
        switch (response as? HTTPURLResponse)?.statusCode ?? 200 {
        case 206:
            return .allow
        case 200:
            // The whole file, not the rest of it: started again.
            lock.withLock {
                try? download?.handle.truncate(atOffset: 0)
                download?.received = 0
            }
            return .allow
        default:
            return .cancel
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tell = lock.withLock { () -> Bool in
            guard var d = download else { return false }
            try? d.handle.write(contentsOf: data)
            d.received += Int64(data.count)
            status.activity = .downloading(id: d.entry.id, name: d.entry.name, received: d.received, total: Int64(d.entry.size))
            let now = Date()
            let due = now.timeIntervalSince(d.written) >= 0.5
            if due { d.written = now }
            download = d
            return due
        }
        if tell { write() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let d = lock.withLock({ () -> Download? in
            let d = download
            download = nil
            return d
        }) else { return }
        try? d.handle.close()
        if let error {
            d.continuation.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse, ![200, 206].contains(http.statusCode) {
            d.continuation.resume(throwing: URLError(.badServerResponse))
        } else {
            d.continuation.resume()
        }
    }
}
