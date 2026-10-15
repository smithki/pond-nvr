// A storage folder (external SSD now, a NAS share later) is used only while it holds the marker file written
// when it was chosen. If the drive is unplugged or the share is not mounted, the folder under /Volumes is
// gone, and without this check recording would quietly create it again on the boot disk and fill that.
import Foundation

public enum StorageLocation {
    public static let markerName = Brand.storageMarker

    public enum Status: Equatable, Sendable {
        /// Marked and writable.
        case ready(id: String)
        /// The folder does not exist: the drive is unplugged or the share is not mounted.
        case missing
        /// The folder exists but was never prepared for pond.
        case notPrepared
        /// Marked, but nothing can be written there (full, read-only, or no permission).
        case notWritable(reason: String)

        public var isReady: Bool { if case .ready = self { true } else { false } }

        public var description: String {
            switch self {
            case .ready: "ready"
            case .missing: "not found: plug in the drive or mount the share"
            case .notPrepared: "not prepared for pond: choose it in the app's storage settings"
            case let .notWritable(reason): "not writable: \(reason)"
            }
        }
    }

    public static func status(of path: String) -> Status {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return .missing }
        let marker = (path as NSString).appendingPathComponent(markerName)
        // A folder prepared under the old name keeps its marker, copied to the new one when it can be.
        let legacy = (path as NSString).appendingPathComponent(Brand.Legacy.storageMarker)
        if !fm.fileExists(atPath: marker), let old = fm.contents(atPath: legacy) {
            fm.createFile(atPath: marker, contents: old)
        }
        guard let data = fm.contents(atPath: marker) ?? fm.contents(atPath: legacy),
              let id = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return .notPrepared }
        let probe = (path as NSString).appendingPathComponent(".pond-write-check-\(UUID().uuidString)")
        guard fm.createFile(atPath: probe, contents: Data()) else {
            return .notWritable(reason: "a test file could not be created")
        }
        try? fm.removeItem(atPath: probe)
        return .ready(id: id)
    }

    public enum PrepareError: Error, Equatable, CustomStringConvertible {
        case notFullPath
        case parentMissing(String)
        case directlyInVolumes
        case failed(String)

        public var description: String {
            switch self {
            case .notFullPath: "The folder must be a full path."
            case let .parentMissing(parent): "\(parent) does not exist. Is the drive plugged in or the share mounted?"
            case .directlyInVolumes: "Choose a folder on the drive, not a new folder in /Volumes, which would be on the boot disk."
            case let .failed(reason): "The folder could not be prepared: \(reason)."
            }
        }
    }

    /// Marks a folder for pond, creating it if its parent exists. Keeps the id of a folder that is already
    /// marked, so choosing the same drive again is harmless. Returns the id.
    @discardableResult
    public static func prepare(_ path: String) throws(PrepareError) -> String {
        let path = (path as NSString).standardizingPath
        guard path.hasPrefix("/") else { throw .notFullPath }
        let parent = (path as NSString).deletingLastPathComponent
        // A missing /Volumes/X is an unmounted drive; creating it would put the recordings on the boot disk.
        if parent == "/Volumes" { throw .directlyInVolumes }
        let fm = FileManager.default
        guard fm.fileExists(atPath: parent) else { throw .parentMissing(parent) }
        if case let .ready(id) = status(of: path) { return id }
        let id = UUID().uuidString
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: nil)
        } catch where fm.fileExists(atPath: path) {
            // Already there; fine.
        } catch {
            throw .failed(error.localizedDescription)
        }
        guard fm.createFile(atPath: (path as NSString).appendingPathComponent(markerName), contents: Data((id + "\n").utf8))
        else { throw .failed("the marker file could not be written") }
        return id
    }

    /// Total and free bytes of the volume holding this folder.
    public static func space(of path: String) -> VolumeSpace? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let total = (attrs[.systemSize] as? NSNumber)?.int64Value,
              let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
        else { return nil }
        return VolumeSpace(total: total, free: free)
    }
}

public struct VolumeSpace: Equatable, Sendable {
    public var total: Int64
    public var free: Int64

    public init(total: Int64, free: Int64) {
        self.total = total
        self.free = free
    }
}
