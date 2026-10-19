// Writes one camera's segments to disk:
//
//   <recordings>/continuous/<camera>/<YYYY-MM-DD>/<HH-MM-SS>.mp4      (UTC, the segment's first frame)
//
// A segment is written as `….mp4.partial` and renamed when complete, so retention never deletes a file
// being written. After a crash, the leftover .partial file is still playable up to its last fragment and
// is renamed at the next start. Nothing is written unless the recordings folder is prepared and present:
// an unplugged drive or unmounted share means segments are dropped (and said so), not written to the boot
// disk.
import Foundation
import NVRCore

public final class SegmentFiles {
    public enum State: Equatable, Sendable {
        case idle
        case writing(path: String)
        /// Segments are being dropped because the folder cannot be used.
        case unavailable(String)
    }

    let root: String
    let camera: String
    let log: EventLog
    public private(set) var state: State = .idle
    private var file: FileHandle?
    private var partialPath: String?
    private var finalPath: String?
    private let formatter: DateFormatter
    /// Completed segments, for reporting.
    public private(set) var completed = 0

    public init(root: String, camera: String, log: EventLog) {
        self.root = root
        self.camera = camera
        self.log = log
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        // To the millisecond: the recording is placed on the timeline by its name, so a picture's place is its time
        // (and a box over it, found at that time, lands on it). Names to the second, from before, are read too.
        formatter.dateFormat = "yyyy-MM-dd/HH-mm-ss.SSS"
    }

    public static func cameraFolder(root: String, camera: String) -> String {
        "\(root)/continuous/\(camera)"
    }

    /// The path a segment starting at `wallTime` gets (before any clash suffix).
    public func path(for wallTime: Double) -> String {
        "\(Self.cameraFolder(root: root, camera: camera))/\(formatter.string(from: Date(timeIntervalSince1970: wallTime))).mp4"
    }

    public func handle(_ outputs: [StreamRecorder.Output]) {
        for output in outputs {
            switch output {
            case let .start(initSegment, wallTime): open(initSegment, wallTime: wallTime)
            case let .fragment(bytes): write(bytes)
            case .end: close()
            }
        }
    }

    private func open(_ initSegment: [UInt8], wallTime: Double) {
        close()
        let status = StorageLocation.status(of: root)
        guard status.isReady else {
            setUnavailable("the recordings folder \(root) is \(status.description)")
            return
        }
        var target = path(for: wallTime)
        var n = 1
        while FileManager.default.fileExists(atPath: target) || FileManager.default.fileExists(atPath: target + ".partial") {
            target = path(for: wallTime).replacingOccurrences(of: ".mp4", with: "-\(n).mp4")
            n += 1
        }
        let partial = target + ".partial"
        do {
            try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: partial, contents: Data(initSegment)),
                  let handle = FileHandle(forWritingAtPath: partial) else {
                setUnavailable("\(partial) could not be created")
                return
            }
            try handle.seekToEnd()
            file = handle
            partialPath = partial
            finalPath = target
            if state != .writing(path: target), case .unavailable = state {
                log.log(camera, "recording to \(root) again")
            }
            state = .writing(path: target)
        } catch {
            setUnavailable("\(partial) could not be created: \(error.localizedDescription)")
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let file else { return }
        do {
            try file.write(contentsOf: Data(bytes))
        } catch {
            try? file.close()
            self.file = nil
            setUnavailable("writing \(partialPath ?? "") failed: \(error.localizedDescription)")
            finishPartial()
        }
    }

    private func close() {
        guard let file else { return }
        try? file.close()
        self.file = nil
        finishPartial()
        completed += 1
        state = .idle
    }

    /// Renames the partial file to its final name, if it is still there.
    private func finishPartial() {
        guard let partial = partialPath, let target = finalPath else { return }
        partialPath = nil
        finalPath = nil
        try? FileManager.default.moveItem(atPath: partial, toPath: target)
    }

    private func setUnavailable(_ reason: String) {
        if state != .unavailable(reason) { log.log(camera, "not recording: \(reason)") }
        state = .unavailable(reason)
    }

    /// Renames .partial files left by a crash (empty ones are deleted). Returns how many were recovered.
    @discardableResult
    public static func recoverPartials(root: String, camera: String) -> Int {
        let folder = cameraFolder(root: root, camera: camera)
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return 0 }
        var recovered = 0
        for case let relative as String in walker where relative.hasSuffix(".mp4.partial") {
            let path = "\(folder)/\(relative)"
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            if size == 0 {
                try? FileManager.default.removeItem(atPath: path)
            } else if (try? FileManager.default.moveItem(atPath: path, toPath: String(path.dropLast(8)))) != nil {
                recovered += 1
            }
        }
        return recovered
    }
}
