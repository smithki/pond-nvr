// The log as a file, for the login service: lines as PrintLog writes them, and when the file passes
// `maxBytes` it becomes <name>.1 (replacing the previous one) and a new file starts.
import Foundation

public final class FileLog: EventLog, @unchecked Sendable {
    let path: String
    let maxBytes: Int
    private let lock = NSLock()
    private let formatter: DateFormatter
    private var handle: FileHandle?
    private var size = 0

    public init(path: String, maxBytes: Int = 10_000_000) throws {
        self.path = path
        self.maxBytes = maxBytes
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try open()
    }

    private func open() throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        size = Int(try h.seekToEnd())
        handle = h
    }

    public func log(_ source: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = Data("\(formatter.string(from: Date())) \(source): \(message)\n".utf8)
        if size + line.count > maxBytes {
            try? handle?.close()
            let old = path + ".1"
            try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.moveItem(atPath: path, toPath: old)
            try? open()
        }
        try? handle?.write(contentsOf: line)
        size += line.count
    }
}
