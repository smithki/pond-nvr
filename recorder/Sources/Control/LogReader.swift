// Reading the service's log a piece at a time: its last lines, then what is added, and earlier lines when
// asked for (on into the previous file, <name>.1, once this one's start is reached). The log can be 10 MB,
// and twice that with the previous file, so nothing reads the whole of it.
import Foundation

/// One line of the log: `2026-10-15 15:28:01 homekit: ✓ message`.
public struct LogLine: Sendable, Equatable, Identifiable {
    /// What the message's mark says it is.
    public enum Kind: Sendable, Equatable {
        /// `✗`: something failed.
        case error
        /// `!`: something is wrong, or may be.
        case warning
        /// `✓`: something worked.
        case done
        /// `…`: a detail, for following what happened step by step.
        case detail
        /// No mark: something that happened.
        case event
    }

    /// In order: later lines have higher ones (earlier lines loaded later count down).
    public let id: Int
    /// As written, local time (`yyyy-MM-dd HH:mm:ss`); empty if the line has none.
    public let time: String
    /// What it is about: `pond`, `homekit`, or a camera's ID.
    public let source: String
    /// The message, without its mark.
    public let message: String
    public let kind: Kind

    public init(id: Int, text: String) {
        self.id = id
        var rest = Substring(text)
        // The time: 19 characters, then a space.
        if rest.count > 20, rest.dropFirst(19).first == " ", rest.prefix(4).allSatisfy(\.isNumber) {
            time = String(rest.prefix(19))
            rest = rest.dropFirst(20)
        } else {
            time = ""
        }
        // The source: up to the first ": " (no spaces in it).
        if let colon = rest.range(of: ": "), !rest[..<colon.lowerBound].contains(" ") {
            source = String(rest[..<colon.lowerBound])
            rest = rest[colon.upperBound...]
        } else {
            source = ""
        }
        let marks: [(String, Kind)] = [("✗ ", .error), ("! ", .warning), ("✓ ", .done), ("… ", .detail)]
        if let (mark, kind) = marks.first(where: { rest.hasPrefix($0.0) }) {
            self.kind = kind
            message = String(rest.dropFirst(mark.count))
        } else {
            kind = .event
            message = String(rest)
        }
    }

    /// The day part of `time`.
    public var day: Substring { time.prefix(10) }
    /// The time of day part of `time`.
    public var clock: Substring { time.dropFirst(11) }
}

public final class LogReader {
    public let path: String
    var previousPath: String { path + ".1" }

    /// The file read (its inode), and how far: lines before `end` have been given.
    private var file: UInt64?
    private var end: UInt64 = 0
    /// Where the earliest line given starts: in this file, or the previous one. Nil: there is nothing earlier.
    private var earliest: (inPrevious: Bool, offset: UInt64)?
    private var nextID = 0, earlierID = -1

    public init(path: String) {
        self.path = path
    }

    /// Whether there are lines before the earliest given.
    public var hasEarlier: Bool {
        guard let earliest else { return false }
        return earliest.offset > 0 || (!earliest.inPrevious && FileManager.default.fileExists(atPath: previousPath))
    }

    /// The last lines, about `bytes` of them; starts over.
    public func latest(bytes: Int = 256 * 1024) -> [LogLine] {
        file = Self.inode(path)
        let size = Self.size(path)
        end = size
        earliest = (false, size)
        return earlier(bytes: bytes)
    }

    /// Lines written since the last read. After the log started a new file, the rest of the old one first.
    public func newer() -> [LogLine] {
        guard let current = Self.inode(path) else { return [] }
        var lines: [LogLine] = []
        if current != file || Self.size(path) < end {
            // Started again: the file read is the previous one now.
            if let file, Self.inode(previousPath) == file {
                lines = take(Self.read(previousPath, from: end, to: Self.size(previousPath)).complete.text)
            }
            // Earlier lines are in the previous file now; if they were already there, they are gone.
            earliest = earliest.flatMap { $0.inPrevious ? nil : (true, $0.offset) }
            file = current
            end = 0
        }
        let (text, used) = Self.read(path, from: end, to: Self.size(path)).complete
        end += used
        return lines + take(text)
    }

    /// About `bytes` of lines before the earliest given (fewer at a file's start).
    public func earlier(bytes: Int = 256 * 1024) -> [LogLine] {
        guard var at = earliest else { return [] }
        if at.offset == 0 {
            guard !at.inPrevious, FileManager.default.fileExists(atPath: previousPath) else { return [] }
            at = (true, Self.size(previousPath))
        }
        let source = at.inPrevious ? previousPath : path
        var from = at.offset > UInt64(bytes) ? at.offset - UInt64(bytes) : 0
        var data = Self.read(source, from: from, to: at.offset)
        // From the start of a line: what comes before the first line break belongs to an earlier one.
        if from > 0, let newline = data.firstIndex(of: 0x0A) {
            let skip = data.distance(from: data.startIndex, to: newline) + 1
            data = data.dropFirst(skip)
            from += UInt64(skip)
        }
        earliest = (at.inPrevious, from)
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.split(separator: "\n", omittingEmptySubsequences: true)
        var lines: [LogLine] = []
        lines.reserveCapacity(parts.count)
        var id = earlierID - parts.count + 1
        for part in parts {
            lines.append(LogLine(id: id, text: String(part)))
            id += 1
        }
        earlierID -= parts.count
        return lines
    }

    /// Lines that come after those given.
    private func take(_ text: String) -> [LogLine] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { part in
            defer { nextID += 1 }
            return LogLine(id: nextID, text: String(part))
        }
    }

    static func inode(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? UInt64
    }

    static func size(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0
    }

    static func read(_ path: String, from: UInt64, to: UInt64) -> Data {
        guard to > from, let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: from)) != nil else { return Data() }
        return (try? handle.read(upToCount: Int(to - from))) ?? Data()
    }
}

extension Data {
    /// The whole lines in it (up to its last line break) as text, and how many bytes they take.
    var complete: (text: String, used: UInt64) {
        guard let last = lastIndex(of: 0x0A) else { return ("", 0) }
        let used = distance(from: startIndex, to: last) + 1
        return (String(decoding: prefix(used), as: UTF8.self), UInt64(used))
    }
}
