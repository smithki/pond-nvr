// The doctor's view of every camera, from the service's health records (the Health module's database, read
// off the main thread): each camera's findings, its day in samples, and its incidents. Findings can be ignored
// per camera (kept in the app's preferences): they stay in the doctor, dimmed, but leave the camera's tile.
import Control
import Devices
import Foundation
import Health
import PondCore
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

    /// When a rule speaks up: the defaults, or as changed in the doctor's advanced settings (kept in the app's
    /// preferences; the findings are worked out here, from what the service records).
    var thresholds: HealthThresholds = CameraDoctor.keptThresholds() {
        didSet {
            guard thresholds != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(thresholds), forKey: "doctorThresholds")
            diagnose()
        }
    }
    @ObservationIgnored private var config: Config?

    static func keptThresholds() -> HealthThresholds {
        UserDefaults.standard.data(forKey: "doctorThresholds").flatMap { try? JSONDecoder().decode(HealthThresholds.self, from: $0) } ?? .standard
    }

    /// Each camera's last check (Run Check Now): what it found, and when.
    private(set) var checks: [String: (lines: [CheckLine], time: Date)] = [:]
    /// Being checked now.
    private(set) var checking: Set<String> = []

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
        self.incidents = incidents
        self.samples = samples
        self.config = config
        diagnose(now: now)
        hasRecords = !incidents.isEmpty || !samples.isEmpty
        refreshed = now
    }

    /// The findings worked out again from what was read (on reading, or when the thresholds change).
    private func diagnose(now: Date = Date()) {
        guard let config else { return }
        var findings: [String: [HealthFinding]] = [:]
        for camera in config.cameras {
            findings[camera.id] = HealthDiagnosis.findings(camera: camera.id, incidents: incidents, samples: samples, now: now,
                                                           thresholds: thresholds,
                                                           app: camera.device?.appName ?? "the camera\u{2019}s own app")
        }
        self.findings = findings
    }

    /// Checks a camera now, only when asked: its streams and 6 s of its video (as Settings › Cameras' check, through
    /// pond), then a read of its controls through the service, timed. Not a private or waking camera: there's
    /// nothing to see, and it can't be asked.
    func check(_ camera: Config.Camera, model: AppModel) async {
        guard !checking.contains(camera.id) else { return }
        if model.isAsleep(camera.id) {
            checks[camera.id] = ([CheckLine(.warning, model.isWaking(camera.id)
                ? "It\u{2019}s waking up from privacy mode: check again once its video is back."
                : "It\u{2019}s private: turn privacy off to check it.")], Date())
            return
        }
        checking.insert(camera.id)
        defer { checking.remove(camera.id) }
        var lines = await model.check(camera, seconds: 6).lines
        if model.controls(for: camera) != nil {
            let started = Date()
            let reply = await model.controlClient.ask(.init(camera: camera.id, action: "items.values"))
            let took = Date().timeIntervalSince(started)
            if let error = reply.error {
                lines.append(CheckLine(.error, "Its controls didn\u{2019}t answer: \(error.description)."))
            } else {
                let seconds = took.formatted(.number.precision(.fractionLength(1)))
                lines.append(took > 3 ? CheckLine(.warning, "Its controls answered, slowly: \(seconds) s.")
                                      : CheckLine(.ok, "Its controls answered in \(seconds) s."))
            }
        }
        checks[camera.id] = (lines, Date())
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
        case .restarted: "Restarted by Pond"
        }
    }
}
