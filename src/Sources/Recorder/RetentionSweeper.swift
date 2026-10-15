// Applies the retention rules to what is on disk: lists the recorded files, asks Retention.plan what to
// delete, deletes it, and removes folders left empty. Files still being written (.partial) are never
// listed. Event clips (from phase 5) live under <events>/events/<camera>/<YYYY-MM-DD>/ and are listed the
// same way.
import Foundation
import NVRCore

public struct SweepReport: Equatable, Sendable {
    public var deletedFiles = 0
    public var freedBytes: Int64 = 0
    public var warnings: [String] = []
    public var failures: [String] = []
}

public struct RetentionSweeper {
    let config: Config
    let log: EventLog

    public init(config: Config, log: EventLog) {
        self.config = config
        self.log = log
    }

    static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd/HH-mm-ss"
        return f
    }()

    /// Recorded files under `<base>/<kind folder>/<camera>/<day>/<time>[-n].mp4`.
    public static func list(base: String, folder: String, kind: RecordedFile.Kind) -> [RecordedFile] {
        let top = "\(base)/\(folder)"
        let fm = FileManager.default
        var out: [RecordedFile] = []
        for camera in (try? fm.contentsOfDirectory(atPath: top)) ?? [] {
            for day in (try? fm.contentsOfDirectory(atPath: "\(top)/\(camera)")) ?? [] {
                for name in (try? fm.contentsOfDirectory(atPath: "\(top)/\(camera)/\(day)")) ?? [] where name.hasSuffix(".mp4") {
                    let stem = String(name.dropLast(4).prefix(8))   // HH-MM-SS, without any -n suffix
                    guard let start = nameFormatter.date(from: "\(day)/\(stem)") else { continue }
                    let path = "\(top)/\(camera)/\(day)/\(name)"
                    let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
                    out.append(RecordedFile(path: path, camera: camera, kind: kind, start: start, bytes: size))
                }
            }
        }
        return out
    }

    /// One pass. The recordings folder and a separate events folder are each planned against their own
    /// volume's free space.
    public func sweep(now: Date = Date()) -> SweepReport {
        var report = SweepReport()
        let recordings = config.storage.recordingsPath
        let events = config.storage.eventsPath
        var groups: [(base: String, files: [RecordedFile])] = []
        if events == recordings {
            groups.append((recordings, Self.list(base: recordings, folder: "continuous", kind: .continuous)
                + Self.list(base: recordings, folder: "events", kind: .event)))
        } else {
            groups.append((recordings, Self.list(base: recordings, folder: "continuous", kind: .continuous)))
            groups.append((events, Self.list(base: events, folder: "events", kind: .event)))
        }
        for (base, files) in groups {
            guard StorageLocation.status(of: base).isReady else { continue }   // the recorder already says so
            let plan = Retention.plan(files: files, policy: config.retention, now: now,
                                      space: StorageLocation.space(of: base))
            for file in plan.deletions {
                do {
                    try FileManager.default.removeItem(atPath: file.path)
                    report.deletedFiles += 1
                    report.freedBytes += file.bytes
                    removeEmptyFolders(from: (file.path as NSString).deletingLastPathComponent, stopAt: base)
                } catch {
                    report.failures.append("\(file.path) could not be deleted: \(error.localizedDescription)")
                }
            }
            report.warnings += plan.warnings
        }
        if report.deletedFiles > 0 {
            log.log("retention", String(format: "deleted %d file%@, %.1f GB", report.deletedFiles,
                                        report.deletedFiles == 1 ? "" : "s", Double(report.freedBytes) / 1e9))
        }
        for line in report.warnings + report.failures { log.log("retention", line) }
        return report
    }

    /// Removes `folder` and its parents while they are empty, never `stopAt` or above it.
    private func removeEmptyFolders(from folder: String, stopAt: String) {
        var current = folder
        while current.hasPrefix(stopAt + "/"), current != stopAt,
              (try? FileManager.default.contentsOfDirectory(atPath: current))?.isEmpty == true {
            try? FileManager.default.removeItem(atPath: current)
            current = (current as NSString).deletingLastPathComponent
            if current == "\(stopAt)/continuous" || current == "\(stopAt)/events" { break }
        }
    }
}
