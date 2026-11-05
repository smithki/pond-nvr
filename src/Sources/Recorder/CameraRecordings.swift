// A camera's recorded files: its continuous recording and its event clips, each in a folder of its own
// under the storage folders. Removing a camera can delete them at once rather than leave them to retention.
import Foundation
import PondCore

public enum CameraRecordings {
    /// The camera's folders: continuous recording, then event clips (when kept elsewhere, both).
    public static func folders(of camera: String, config: Config) -> [String] {
        let roots = [config.storage.recordingsPath, config.storage.eventsPath]
        var out: [String] = []
        for root in roots {
            for kind in ["continuous", "events"] {
                let folder = "\(root)/\(kind)/\(camera)"
                if !out.contains(folder) { out.append(folder) }
            }
        }
        return out
    }

    /// Their total size in bytes, for saying what will be deleted.
    public static func size(of camera: String, config: Config) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for folder in folders(of: camera, config: config) {
            guard let walker = fm.enumerator(atPath: folder) else { continue }
            for case let name as String in walker {
                guard let attributes = try? fm.attributesOfItem(atPath: "\(folder)/\(name)"),
                      attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    /// Deletes them. Returns the folders that could not be deleted.
    @discardableResult
    public static func delete(of camera: String, config: Config) -> [String] {
        let fm = FileManager.default
        return folders(of: camera, config: config).filter { folder in
            guard fm.fileExists(atPath: folder) else { return false }
            return (try? fm.removeItem(atPath: folder)) == nil
        }
    }
}

extension CameraRecordings {
    /// Bytes per second the camera recorded over its last day of continuous recording; nil with less than
    /// ten minutes of it to go on.
    public static func recordedRate(of camera: String, config: Config, now: Date = Date()) -> Double? {
        let spans = RecordingIndex.spans(base: config.storage.recordingsPath, camera: camera,
                                         from: now.addingTimeInterval(-86400), to: now)
        var bytes: Int64 = 0
        var seconds = 0.0
        for span in spans {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: span.path))?[.size] as? NSNumber else { continue }
            bytes += size.int64Value
            seconds += span.seconds
        }
        return seconds >= 600 ? Double(bytes) / seconds : nil
    }

    /// Bytes pond keeps in its storage folders now, all cameras.
    public static func total(config: Config) -> Int64 {
        config.cameras.reduce(0) { $0 + size(of: $1.id, config: config) }
    }
}
