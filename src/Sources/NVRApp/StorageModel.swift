// The storage folder as the Storage tab shows it: how long it lasts (from what the cameras really record),
// and a checklist of what makes a good place for recordings, with a fix where there is one.
import Foundation
import NVRCore
import Recorder

/// What the drive under a folder is.
struct DriveFacts: Equatable, Sendable {
    /// Where the drive is mounted, e.g. /Volumes/Pond (or / for the startup disk).
    var volume: String
    var name: String
    var isInternal: Bool
    var isStartupDisk: Bool
    /// "APFS", "Mac OS Extended (Journaled)", "ExFAT".
    var format: String
    var total: Int64
    var free: Int64
    /// Whether Spotlight indexes the drive; nil if it could not be told.
    var spotlightIndexing: Bool?

    static func read(_ path: String) -> DriveFacts? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey,
                                         .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys), let volume = v.volume else { return nil }
        return DriveFacts(volume: volume.path, name: v.volumeName ?? volume.lastPathComponent,
                          isInternal: v.volumeIsInternal ?? false, isStartupDisk: v.volumeIsRootFileSystem ?? false,
                          format: v.volumeLocalizedFormatDescription ?? "", total: Int64(v.volumeTotalCapacity ?? 0),
                          free: v.volumeAvailableCapacityForImportantUsage ?? 0,
                          spotlightIndexing: spotlight(volume.path))
    }

    /// `mdutil -s`, which anyone may run: "Indexing enabled." or "Indexing and searching disabled."
    static func spotlight(_ volume: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-s", volume]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
        if text.contains("indexing enabled") { return true }
        if text.contains("disabled") { return false }
        return nil
    }

    /// Turns Spotlight off for the drive (`mdutil -i off`), which needs an administrator: macOS asks for the
    /// password. Blocks while it asks, so run it off the main thread. Returns what went wrong, in words; nil
    /// when done or when the prompt was cancelled.
    static func turnOffSpotlight(_ volume: String) -> String? {
        let quoted = volume.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"/usr/bin/mdutil -i off '\(quoted)'\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        guard (try? process.run()) != nil else { return Self.turnOffByHand }
        process.waitUntilExit()
        if process.terminationStatus == 0 { return nil }
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.contains("-128") ? nil : Self.turnOffByHand
    }

    static let turnOffByHand = "Spotlight could not be turned off for this drive. Add the drive in System Settings › Spotlight › Search Privacy instead."
}

/// How long the storage lasts, for the cameras as they are.
struct StorageOutlook: Equatable, Sendable {
    var estimate: StorageEstimate?
    var drive: DriveFacts?
    /// Days of continuous recording kept, from the retention settings.
    var keepDays: Int
    /// Bytes pond keeps on the drive now (continuous recording and event clips).
    var used: Double = 0
    /// The cameras' rates, to work the estimate out again for other settings (Retention's controls).
    var cameras: [StorageEstimate.Camera] = []

    /// The estimate for other retention settings, on the same drive and cameras.
    func estimate(eventDays: Int, maxContinuousGB: Double?, minFreeGB: Double) -> StorageEstimate? {
        guard let drive else { return nil }
        return StorageEstimate(cameras: cameras, room: Double(drive.free) + used - minFreeGB * 1e9, eventDays: eventDays,
                               maxContinuous: maxContinuousGB.map { $0 * 1e9 })
    }

    /// What adding a camera would do: the estimate with it, on the same drive and settings.
    struct Impact: Equatable, Sendable {
        var camera: StorageEstimate.Camera
        var before: StorageEstimate?
        var after: StorageEstimate
        var keepDays: Int
        var drive: DriveFacts
        /// Bytes pond keeps on the drive now.
        var used: Double
        var reserveGB: Double

        /// The days kept still fit with the camera.
        var fits: Bool { after.continuousDays >= Double(keepDays) }
        /// They fitted before it, so the camera is what tips it over.
        var fittedBefore: Bool { (before?.continuousDays ?? .infinity) >= Double(keepDays) }
        /// Bytes a day of the camera's continuous recording.
        var perDay: Double { camera.rate * 86400 }
    }

    func adding(_ camera: StorageEstimate.Camera, eventDays: Int, maxContinuousGB: Double?, minFreeGB: Double) -> Impact? {
        var with = self
        with.cameras.append(camera)
        guard let drive, let after = with.estimate(eventDays: eventDays, maxContinuousGB: maxContinuousGB, minFreeGB: minFreeGB)
        else { return nil }
        return Impact(camera: camera, before: estimate, after: after, keepDays: keepDays, drive: drive, used: used,
                      reserveGB: minFreeGB)
    }

    static func measure(config: Config, checkedRates: [String: Double]) -> StorageOutlook {
        let path = config.storage.recordingsPath
        let drive = StorageLocation.status(of: path).isReady ? DriveFacts.read(path) : nil
        guard let drive else { return StorageOutlook(estimate: nil, drive: nil, keepDays: config.retention.continuous.days) }
        let cameras = config.cameras.map { camera -> StorageEstimate.Camera in
            if let rate = CameraRecordings.recordedRate(of: camera.id, config: config) {
                return .init(id: camera.id, rate: rate, source: .recorded)
            }
            if let mbps = checkedRates[camera.id] { return .init(id: camera.id, rate: mbps * 1e6 / 8, source: .checked) }
            return .init(id: camera.id, rate: StorageEstimate.typicalRate, source: .assumed)
        }
        let used = Double(CameraRecordings.total(config: config))
        let room = Double(drive.free) + used - config.retention.minFreeGB * 1e9
        let estimate = StorageEstimate(cameras: cameras, room: room, eventDays: config.retention.events.days,
                                       maxContinuous: config.retention.continuous.maxSizeGB.map { $0 * 1e9 })
        return StorageOutlook(estimate: estimate, drive: drive, keepDays: config.retention.continuous.days, used: used,
                              cameras: cameras)
    }
}

extension AppModel {
    /// Measures the storage outlook again, and keeps it for the tabs that show it.
    func refreshStorageOutlook() async {
        lastStorageOutlook = await storageOutlook()
    }

    /// The storage outlook for the settings as they are: measured off the main thread.
    func storageOutlook() async -> StorageOutlook? {
        guard let config else { return nil }
        let rates = Dictionary(uniqueKeysWithValues: config.cameras.compactMap { camera -> (String, Double)? in
            let rate = UserDefaults.standard.double(forKey: AppModel.checkedRateKey(camera.id))
            return rate > 0 ? (camera.id, rate) : nil
        })
        return await Task.detached { StorageOutlook.measure(config: config, checkedRates: rates) }.value
    }

    /// What adding a camera recording at `megabitsPerSecond` would do to the storage; nil if the recordings
    /// folder isn't ready to measure.
    func storageImpact(ofAdding id: String, megabitsPerSecond: Double?) async -> StorageOutlook.Impact? {
        guard let config, let outlook = await storageOutlook(), outlook.drive != nil else { return nil }
        let camera = megabitsPerSecond.map { StorageEstimate.Camera(id: id, rate: $0 * 1e6 / 8, source: .checked) }
            ?? StorageEstimate.Camera(id: id, rate: StorageEstimate.typicalRate, source: .assumed)
        return outlook.adding(camera, eventDays: config.retention.events.days,
                              maxContinuousGB: config.retention.continuous.maxSizeGB, minFreeGB: config.retention.minFreeGB)
    }
}
