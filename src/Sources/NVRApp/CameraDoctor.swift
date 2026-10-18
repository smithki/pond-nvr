// The doctor's view of every camera, from the service's health records (the Health module's database, read
// off the main thread): each camera's findings, its day in samples, and its incidents. Findings can be ignored
// per camera (kept in the app's preferences): they stay in the doctor, dimmed, but leave the camera's tile.
import Devices
import Foundation
import Health
import NVRCore
import SwiftUI

@MainActor
@Observable
final class CameraDoctor {
    private(set) var incidents: [HealthIncident] = []
    private(set) var samples: [HealthSample] = []
    /// Each camera's findings, worst first (ignored ones included).
    private(set) var findings: [String: [HealthFinding]] = [:]
    /// Read at least once (nothing kept yet, or no database: said apart from "all well").
    private(set) var hasRecords = false
    private(set) var refreshed: Date?
    @ObservationIgnored private var store: HealthStore?
    @ObservationIgnored private var storePath: String?

    /// "camera|finding", ignored.
    private(set) var ignored: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "doctorIgnored") ?? [])

    static let incidentsKept: TimeInterval = 7 * 86400
    static let samplesShown: TimeInterval = 86400

    /// Read again (off the main thread), and the findings worked out.
    func refresh(config: Config?) async {
        guard let config else { return }
        let path = config.storage.databasePath
        if store == nil || storePath != path {
            store = HealthStore(path: path, readOnly: true)
            storePath = path
        }
        guard let store else { return }
        let now = Date()
        let incidentsSince = now.addingTimeInterval(-Self.incidentsKept), samplesSince = now.addingTimeInterval(-Self.samplesShown)
        // Off the main thread: the database is read in its own queue, and the app goes on meanwhile.
        let (incidents, samples) = await Task.detached(priority: .utility) {
            (store.incidents(since: incidentsSince), store.samples(since: samplesSince))
        }.value
        var findings: [String: [HealthFinding]] = [:]
        for camera in config.cameras {
            findings[camera.id] = HealthDiagnosis.findings(camera: camera.id, incidents: incidents, samples: samples, now: now,
                                                           app: camera.device?.appName ?? "the camera\u{2019}s own app")
        }
        self.incidents = incidents
        self.samples = samples
        self.findings = findings
        hasRecords = !incidents.isEmpty || !samples.isEmpty
        refreshed = now
    }

    func isIgnored(_ camera: String, _ finding: HealthFinding) -> Bool { ignored.contains("\(camera)|\(finding.id)") }

    func setIgnored(_ camera: String, _ finding: HealthFinding, _ ignore: Bool) {
        let key = "\(camera)|\(finding.id)"
        if ignore { ignored.insert(key) } else { ignored.remove(key) }
        UserDefaults.standard.set(Array(ignored).sorted(), forKey: "doctorIgnored")
    }

    /// What a camera's tile shows: its worst finding worth a mark (a problem, or a warning with a fix), unless
    /// ignored.
    func mark(_ camera: String) -> HealthFinding? {
        findings[camera]?.first { $0.marksTile && !isIgnored(camera, $0) }
    }

    func incidents(of camera: String) -> [HealthIncident] { incidents.filter { $0.camera == camera } }
    func samples(of camera: String) -> [HealthSample] { samples.filter { $0.camera == camera } }

    /// A camera's state in a word, for lists: the worst finding not ignored.
    func worst(_ camera: String) -> HealthFinding? { findings[camera]?.first { !isIgnored(camera, $0) } }

    /// Plain text for a bug report: the camera's model and firmware, its findings and its last day's incidents
    /// (no address, password or picture).
    func report(_ camera: Config.Camera) -> String {
        var lines = ["Pond \(Brand.version): \(camera.name)"]
        if let device = camera.device {
            lines.append("\(device.manufacturer) \(device.model)" + (device.firmware.map { ", firmware \($0)" } ?? "")
                         + ", talked to through \(device.provider ?? "?")")
        }
        lines.append("")
        let found = findings[camera.id] ?? []
        lines.append(found.isEmpty ? "No findings." : "Findings:")
        for finding in found {
            lines.append("- \(finding.headline): \(finding.evidence)" + (isIgnored(camera.id, finding) ? " (ignored)" : ""))
        }
        let day = samples(of: camera.id)
        var total = HealthSample(camera: camera.id, start: Date())
        for sample in day { total.add(sample) }
        if total.flowing > 0 {
            lines.append("")
            lines.append(String(format: "Last day: video for %@, %.1f fps, a keyframe every %.1f s, %.2f%% lost, %.0f kbit/s",
                                HealthDiagnosis.duration(total.flowing), total.fps ?? 0, total.keyframeInterval ?? 0,
                                (total.lossRate ?? 0) * 100, total.kilobitsPerSecond ?? 0))
        }
        let since = Date().addingTimeInterval(-86400)
        let recent = incidents(of: camera.id).filter { $0.time >= since }
        if !recent.isEmpty {
            lines.append("")
            lines.append("Incidents, last day:")
            for incident in recent {
                lines.append("\(incident.time.formatted(date: .omitted, time: .standard))  \(Self.words(incident.kind))"
                             + (incident.detail.map { ": \($0)" } ?? ""))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// An incident in words.
    static func words(_ kind: HealthIncident.Kind) -> String {
        switch kind {
        case .connected: "Video started"
        case .stalled: "Video stopped"
        case .unreachable: "Unreachable"
        case .loginRefused: "Login refused"
        case .failed: "Couldn\u{2019}t connect"
        case .privacyMode: "Privacy mode on the camera"
        case .madePrivate: "Made private"
        case .madePublic: "No longer private"
        case .controlFailed: "A control failed"
        case .serviceStarted: "The recorder started"
        case .wakeFailed: "Didn\u{2019}t start its video after privacy mode"
        }
    }
}
