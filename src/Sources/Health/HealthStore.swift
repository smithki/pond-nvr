// Camera health, kept in Pond's database (pond.sqlite, on the internal disk; storage.database in the settings):
// incidents and five-minute samples per camera, a week of them. The service writes (it's HealthLog's sink); the
// app reads, for the doctor. SQLite in WAL mode, so the app reads while the service writes.
import Foundation
import NVRCore
import SQLite3

public final class HealthStore: HealthSink, @unchecked Sendable {
    /// How long they're kept.
    public static let keep: TimeInterval = 7 * 86400

    private var db: OpaquePointer?
    /// Every use of the connection, one at a time (writes in order, off the caller's thread).
    private let queue = DispatchQueue(label: "pond.health")

    /// Opened (made, with its tables, unless `readOnly`); nil if it can't be.
    public init?(path: String, readOnly: Bool = false) {
        if !readOnly {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
        if !readOnly {
            let made = Self.exec(db, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS incidents (camera TEXT NOT NULL, time REAL NOT NULL, kind TEXT NOT NULL, detail TEXT);
            CREATE INDEX IF NOT EXISTS incidents_by_time ON incidents (time);
            CREATE INDEX IF NOT EXISTS incidents_by_kind ON incidents (kind, time);
            CREATE TABLE IF NOT EXISTS samples (
                camera TEXT NOT NULL, start REAL NOT NULL, flowing REAL NOT NULL DEFAULT 0, frames INTEGER NOT NULL DEFAULT 0,
                keyframes INTEGER NOT NULL DEFAULT 0, received INTEGER NOT NULL DEFAULT 0, lost INTEGER NOT NULL DEFAULT 0,
                bytes INTEGER NOT NULL DEFAULT 0, controls_ok INTEGER NOT NULL DEFAULT 0, controls_failed INTEGER NOT NULL DEFAULT 0,
                clock_offset REAL, PRIMARY KEY (camera, start));
            """)
            guard made else { return nil }
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: Writing (the service)

    public func record(_ incident: HealthIncident) {
        queue.async { [self] in
            run("INSERT INTO incidents (camera, time, kind, detail) VALUES (?, ?, ?, ?)",
                [incident.camera, incident.time.timeIntervalSince1970, incident.kind.rawValue, incident.detail])
        }
    }

    /// Added into its five minutes (several parts make one).
    public func add(_ sample: HealthSample) {
        queue.async { [self] in
            run("""
            INSERT INTO samples (camera, start, flowing, frames, keyframes, received, lost, bytes, controls_ok, controls_failed, clock_offset)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (camera, start) DO UPDATE SET
                flowing = flowing + excluded.flowing, frames = frames + excluded.frames, keyframes = keyframes + excluded.keyframes,
                received = received + excluded.received, lost = lost + excluded.lost, bytes = bytes + excluded.bytes,
                controls_ok = controls_ok + excluded.controls_ok, controls_failed = controls_failed + excluded.controls_failed,
                clock_offset = COALESCE(excluded.clock_offset, clock_offset)
            """, [sample.camera, sample.start.timeIntervalSince1970, sample.flowing, sample.frames, sample.keyframes,
                  sample.received, sample.lost, sample.bytes, sample.controlsOK, sample.controlsFailed, sample.clockOffset])
        }
    }

    /// When a camera was made private and public again: kept a year (few, and the timeline shows them as far
    /// back as recordings go).
    public static let keepPrivacy: TimeInterval = 366 * 86400

    /// What's older than a week let go (privacy's changes, older than a year).
    public func prune(now: Date = Date()) {
        let before = now.addingTimeInterval(-Self.keep).timeIntervalSince1970
        let privacyBefore = now.addingTimeInterval(-Self.keepPrivacy).timeIntervalSince1970
        queue.async { [self] in
            run("DELETE FROM incidents WHERE time < ? AND kind NOT IN ('madePrivate', 'madePublic')", [before])
            run("DELETE FROM incidents WHERE time < ?", [privacyBefore])
            run("DELETE FROM samples WHERE start < ?", [before])
        }
    }

    /// Waits for what's been written so far (tests).
    public func flush() { queue.sync {} }

    // MARK: Reading (the app)

    public func incidents(since: Date) -> [HealthIncident] {
        queue.sync {
            rows("SELECT camera, time, kind, detail FROM incidents WHERE time >= ? ORDER BY time", [since.timeIntervalSince1970]) { row in
                guard let kind = HealthIncident.Kind(rawValue: row.text(2) ?? "") else { return nil }
                return HealthIncident(camera: row.text(0) ?? "", time: Date(timeIntervalSince1970: row.double(1)), kind: kind,
                                      detail: row.text(3))
            }
        }
    }

    /// When each camera was private, within `from`…`to`: from each time it was made private to when it was made
    /// public again (or `to`, if it still is). Reads only what it needs, however long the history: each camera's
    /// last change before `from` (whether it was private then), and the changes within.
    public func privateSpans(from: Date, to: Date) -> [String: [ClosedRange<Date>]] {
        let changes = queue.sync { () -> [(String, Date, Bool)] in
            func change(_ row: Row) -> (String, Date, Bool)? {
                guard let camera = row.text(0) else { return nil }
                return (camera, Date(timeIntervalSince1970: row.double(1)), row.text(2) == "madePrivate")
            }
            // (With MAX in a GROUP BY, SQLite gives the other columns of the row with the latest time.)
            let before = rows("SELECT camera, MAX(time), kind FROM incidents WHERE kind IN ('madePrivate', 'madePublic') "
                + "AND time < ? GROUP BY camera", [from.timeIntervalSince1970], change)
            let within = rows("SELECT camera, time, kind FROM incidents WHERE kind IN ('madePrivate', 'madePublic') "
                + "AND time >= ? AND time < ? ORDER BY time", [from.timeIntervalSince1970, to.timeIntervalSince1970], change)
            return before.sorted { $0.1 < $1.1 } + within
        }
        return Self.spans(changes, from: from, to: to)
    }

    /// Private stretches from changes in time order (camera, when, made private), clipped to `from`…`to`.
    static func spans(_ changes: [(String, Date, Bool)], from: Date, to: Date) -> [String: [ClosedRange<Date>]] {
        var since: [String: Date] = [:]
        var out: [String: [ClosedRange<Date>]] = [:]
        func close(_ camera: String, at end: Date) {
            guard let start = since.removeValue(forKey: camera) else { return }
            let lo = max(start, from), hi = min(end, to)
            if lo < hi { out[camera, default: []].append(lo ... hi) }
        }
        for (camera, time, made) in changes {
            if made {
                if since[camera] == nil { since[camera] = time }
            } else {
                close(camera, at: time)
            }
        }
        for camera in Array(since.keys) { close(camera, at: to) }
        return out
    }

    public func samples(since: Date, camera: String? = nil) -> [HealthSample] {
        queue.sync {
            let filter = camera == nil ? "" : " AND camera = ?"
            return rows("""
            SELECT camera, start, flowing, frames, keyframes, received, lost, bytes, controls_ok, controls_failed, clock_offset
            FROM samples WHERE start >= ?\(filter) ORDER BY start
            """, [since.timeIntervalSince1970] + (camera.map { [$0] } ?? [])) { row in
                var sample = HealthSample(camera: row.text(0) ?? "", start: Date(timeIntervalSince1970: row.double(1)))
                sample.flowing = row.double(2)
                sample.frames = row.int(3)
                sample.keyframes = row.int(4)
                sample.received = row.int(5)
                sample.lost = row.int(6)
                sample.bytes = row.int(7)
                sample.controlsOK = row.int(8)
                sample.controlsFailed = row.int(9)
                sample.clockOffset = row.isNull(10) ? nil : row.double(10)
                return sample
            }
        }
    }

    // MARK: SQLite

    struct Row {
        let statement: OpaquePointer?
        func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ values: [Any?]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, i, text, -1, Self.transient)
            case let number as Double: sqlite3_bind_double(statement, i, number)
            case let number as Int: sqlite3_bind_int64(statement, i, Int64(number))
            default: sqlite3_bind_null(statement, i)
            }
        }
        return statement
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Any?]) -> Bool {
        guard let statement = prepare(sql, values) else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func rows<T>(_ sql: String, _ values: [Any?], _ make: (Row) -> T?) -> [T] {
        guard let statement = prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let item = make(Row(statement: statement)) { out.append(item) }
        }
        return out
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
