// Decides what to delete. Pure: it is given the recorded files on one volume, the settings, the time and the
// volume's free space, and returns the files to delete and anything worth warning about. The caller lists
// the files (leaving out the ones still being written) and does the deleting.
//
// Rules, in order:
//  1. Continuous recording older than retention.continuous.days goes.
//  2. Event clips and snapshots older than retention.events.days go.
//  3. If continuous recording is over retention.continuous.maxSizeGB, the oldest goes until it is not.
//  4. If the volume has less than retention.minFreeGB free, the oldest continuous recording goes until it
//     has. Event clips are never deleted for space: they are what the user chose to keep.
import Foundation

public struct RecordedFile: Equatable, Sendable {
    public enum Kind: Sendable { case continuous, event }

    public var path: String
    public var camera: String
    public var kind: Kind
    public var start: Date
    public var bytes: Int64

    public init(path: String, camera: String, kind: Kind, start: Date, bytes: Int64) {
        self.path = path
        self.camera = camera
        self.kind = kind
        self.start = start
        self.bytes = bytes
    }
}

public struct RetentionPlan: Equatable, Sendable {
    public var deletions: [RecordedFile]
    public var warnings: [String]

    public var bytesFreed: Int64 { deletions.reduce(0) { $0 + $1.bytes } }
}

public enum Retention {
    static let bytesPerGB = 1_000_000_000.0   // decimal, as drives are sold

    public static func plan(files: [RecordedFile], policy: Config.Retention, now: Date,
                            space: VolumeSpace?) -> RetentionPlan {
        var delete: [RecordedFile] = []
        let continuousCutoff = now.addingTimeInterval(-Double(policy.continuous.days) * 86400)
        let eventCutoff = now.addingTimeInterval(-Double(policy.events.days) * 86400)

        // Oldest first, so the space rules below take from the front.
        var continuous = files.filter { $0.kind == .continuous }.sorted { $0.start < $1.start }
        let expiredCount = continuous.prefix { $0.start < continuousCutoff }.count
        delete += continuous.prefix(expiredCount)
        continuous.removeFirst(expiredCount)
        delete += files.filter { $0.kind == .event && $0.start < eventCutoff }.sorted { $0.start < $1.start }

        if let max = policy.continuous.maxSizeGB {
            let limit = Int64(max * bytesPerGB)
            var size = continuous.reduce(Int64(0)) { $0 + $1.bytes }
            while size > limit, !continuous.isEmpty {
                let oldest = continuous.removeFirst()
                delete.append(oldest)
                size -= oldest.bytes
            }
        }

        var warnings: [String] = []
        if let space {
            let reserve = Int64(policy.minFreeGB * bytesPerGB)
            var free = space.free + delete.reduce(0) { $0 + $1.bytes }
            var deletedForSpace = false
            while free < reserve, !continuous.isEmpty {
                let oldest = continuous.removeFirst()
                delete.append(oldest)
                free += oldest.bytes
                deletedForSpace = true
            }
            if free < reserve {
                let short = Double(reserve - free) / bytesPerGB
                warnings.append(String(format: "The drive is %.1f GB short of the %.0f GB to keep free, with no continuous recording left to delete. Event clips or other files fill it: keep events for fewer days, lower the reserve, or use a bigger drive.", short, policy.minFreeGB))
            } else if deletedForSpace, let oldest = continuous.first {
                let kept = now.timeIntervalSince(oldest.start) / 86400
                warnings.append(String(format: "Only %.1f of the %d days of continuous recording fit on the drive.", kept, policy.continuous.days))
            }
        }
        return RetentionPlan(deletions: delete, warnings: warnings)
    }
}
