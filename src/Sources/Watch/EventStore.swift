// The cameras' events, kept in Pond's database (pond.sqlite, beside the camera health): one row each, written
// as it begins and again as it goes on and ends. The service writes; the app and `pond events` read. Their
// pictures are files in the events folder, the row naming each; both are kept as long as event retention says.
import Detection
import Foundation
import SQLite3

public final class EventStore: @unchecked Sendable {
    private var db: OpaquePointer?
    /// Every use of the connection, one at a time (writes in order, off the caller's thread).
    private let queue = DispatchQueue(label: "pond.events")

    /// Opened (made, with its table, unless `readOnly`); nil if it can't be.
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
            let made = sqlite3_exec(db, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY, camera TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL, category TEXT NOT NULL,
                labels TEXT NOT NULL DEFAULT '{}', confidence REAL NOT NULL DEFAULT 0, snapshot TEXT, box TEXT, summary TEXT,
                ongoing INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS events_by_start ON events (start);
            """, nil, nil, nil) == SQLITE_OK
            guard made else { return nil }
            // Added since the table was first made (fails, harmlessly, when it's there).
            sqlite3_exec(db, "ALTER TABLE events ADD COLUMN zones TEXT", nil, nil, nil)
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: Writing (the service)

    /// Kept (or kept again, as it goes on); `ongoing` until it ends.
    public func save(_ event: CameraEvent, ongoing: Bool) {
        let labels = (try? JSONEncoder().encode(event.labels)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let zones = (try? JSONEncoder().encode(event.zones)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let box = event.box.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        queue.async { [self] in
            run("""
            INSERT INTO events (id, camera, start, end, category, labels, confidence, snapshot, box, summary, ongoing, zones)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET end = excluded.end, category = excluded.category, labels = excluded.labels,
                confidence = excluded.confidence, snapshot = excluded.snapshot, box = excluded.box,
                summary = excluded.summary, ongoing = excluded.ongoing, zones = excluded.zones
            """, [event.id, event.camera, event.start.timeIntervalSince1970, event.end.timeIntervalSince1970,
                  event.category.rawValue, labels, event.confidence, event.snapshot, box, event.summary, ongoing ? 1 : 0, zones])
        }
    }

    /// Events left ongoing by a service that stopped short: ended where they were last seen.
    public func endOngoing() {
        queue.async { [self] in run("UPDATE events SET ongoing = 0 WHERE ongoing = 1", []) }
    }

    /// Events older than `days` let go (their pictures are swept with the events folder).
    public func prune(days: Int, now: Date = Date()) {
        let before = now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        queue.async { [self] in run("DELETE FROM events WHERE start < ?", [before]) }
    }

    /// Waits for the writes so far.
    public func flush() { queue.sync {} }

    // MARK: Reading

    public struct Kept: Sendable, Equatable {
        public var event: CameraEvent
        public var ongoing: Bool
    }

    /// Events begun since `since`, oldest first (one camera's, or all).
    public func events(since: Date, camera: String? = nil) -> [Kept] {
        queue.sync {
            rows("""
            SELECT id, camera, start, end, category, labels, confidence, snapshot, box, summary, ongoing, zones FROM events
            WHERE start >= ? AND (? IS NULL OR camera = ?) ORDER BY start
            """, [since.timeIntervalSince1970, camera, camera]) { row in
                guard let id = row.text(0), let camera = row.text(1), let category = row.text(4).flatMap(DetectedCategory.init) else { return nil }
                let labels = row.text(5).flatMap { try? JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) } ?? [:]
                let box = row.text(8).flatMap { try? JSONDecoder().decode(Detection.Box.self, from: Data($0.utf8)) }
                let event = CameraEvent(id: id, camera: camera, start: Date(timeIntervalSince1970: row.double(2)),
                                        end: Date(timeIntervalSince1970: row.double(3)), category: category, labels: labels,
                                        confidence: row.double(6), snapshot: row.text(7), box: box, summary: row.text(9),
                                        zones: row.text(11).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
                return Kept(event: event, ongoing: row.int(10) != 0)
            }
        }
    }

    // MARK: SQLite

    struct Row {
        let statement: OpaquePointer?
        func text(_ i: Int32) -> String? { sqlite3_column_text(statement, i).map { String(cString: $0) } }
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
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
}
