// The recorder's log: one line per event, with the time and what it is about.
import Foundation

public protocol EventLog: AnyObject, Sendable {
    func log(_ source: String, _ message: String)
}

/// Writes lines to standard output, local time.
public final class PrintLog: EventLog, @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: DateFormatter

    public init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    public func log(_ source: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        print("\(formatter.string(from: Date())) \(source): \(message)")
        fflush(stdout)
    }
}

/// Keeps lines in memory, for tests.
public final class MemoryLog: EventLog, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    public init() {}

    public func log(_ source: String, _ message: String) {
        lock.lock()
        stored.append("\(source): \(message)")
        lock.unlock()
    }

    public var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
