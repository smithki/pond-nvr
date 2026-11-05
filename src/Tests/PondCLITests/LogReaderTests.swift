import Control
import Foundation
import Testing

@Suite struct LogReaderTests {
    let dir = NSTemporaryDirectory() + "logreader-" + UUID().uuidString
    var path: String { dir + "/pond.log" }

    func write(_ path: String, _ lines: [String], append: Bool = false, partial: String = "") throws {
        let text = lines.map { $0 + "\n" }.joined() + partial
        if append, let h = FileHandle(forWritingAtPath: path) {
            try h.seekToEnd()
            try h.write(contentsOf: Data(text.utf8))
            try h.close()
        } else {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    static func line(_ n: Int) -> String { String(format: "2026-10-15 12:00:%02d pond: line %d", n % 60, n) }

    @Test func aLineIsReadForItsParts() {
        let error = LogLine(id: 0, text: "2026-10-15 15:28:01 porch: ✗ no video")
        #expect(error.time == "2026-10-15 15:28:01" && error.source == "porch" && error.message == "no video")
        #expect(error.kind == .error && error.day == "2026-10-15" && error.clock == "15:28:01")
        #expect(LogLine(id: 0, text: "2026-10-15 15:28:01 homekit: … pair verify").kind == .detail)
        #expect(LogLine(id: 0, text: "2026-10-15 15:28:01 homekit: ! slow").kind == .warning)
        #expect(LogLine(id: 0, text: "2026-10-15 15:28:01 pond: ✓ started").kind == .done)
        let plain = LogLine(id: 0, text: "2026-10-15 15:28:01 pond: starting: 1 camera")
        #expect(plain.kind == .event && plain.message == "starting: 1 camera")
        let odd = LogLine(id: 0, text: "something else entirely")
        #expect(odd.time.isEmpty && odd.source.isEmpty && odd.message == "something else entirely")
    }

    @Test func theEndThenWhatComesThenEarlierIntoThePreviousFile() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(path + ".1", (0 ..< 50).map(Self.line))
        try write(path, (50 ..< 100).map(Self.line))
        let reader = LogReader(path: path)

        // About 400 bytes: the last whole lines only.
        let last = reader.latest(bytes: 400)
        #expect(!last.isEmpty && last.last?.message == "line 99")
        let firstShown = try #require(last.first.flatMap { Int($0.message.dropFirst(5)) })
        #expect(last.map(\.message) == (firstShown ..< 100).map { "line \($0)" })
        #expect(reader.hasEarlier)

        // A line is given once it is whole.
        try write(path, [Self.line(100)], append: true, partial: "2026-10-15 12:00:00 pond: half a li")
        #expect(reader.newer().map(\.message) == ["line 100"])
        try write(path, ["ne"], append: true)
        #expect(reader.newer().map(\.message) == ["half a line"])

        // Back to the start of this file, then on into the previous one.
        var earlier: [LogLine] = []
        while reader.hasEarlier { earlier = reader.earlier(bytes: 400) + earlier }
        #expect(earlier.map(\.message) == (0 ..< firstShown).map { "line \($0)" })
        let ids = (earlier + last).map(\.id)
        #expect(ids == ids.sorted() && Set(ids).count == ids.count)
    }

    @Test func aNewFileFollowsTheOldOne() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(path, (0 ..< 5).map(Self.line))
        let reader = LogReader(path: path)
        _ = reader.latest()
        try write(path, [Self.line(5)], append: true)
        // As FileLog does it: the file becomes the previous one, and a new one starts.
        try? FileManager.default.removeItem(atPath: path + ".1")
        try FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        try write(path, [Self.line(6)])
        #expect(reader.newer().map(\.message) == ["line 5", "line 6"])
        #expect(reader.newer().isEmpty)
    }
}
