// HomeKit at a glance, a page of the Settings window: which cameras are in the Home app, how each is doing there
// and what it sends (live video, HomeKit Secure Video's recordings, a doorbell's ring), with the one thing to do for
// each; and the cameras that aren't, to add. Each camera's own HomeKit settings stay on its Settings tab; this page
// is the whole house at once, so nobody has to open every camera to know.
import PondCore
import SwiftUI

struct HomeKitPage: View {
    @Environment(AppModel.self) private var model
    /// The camera whose setup code is shown, over the page.
    @State private var pairing: Pairing?
    /// Pond's own sensor's setup code, over the page.
    @State private var pairingSensor = false

    struct Pairing: Identifiable {
        let id: String
    }

    var cameras: [Config.Camera] { model.config?.cameras ?? [] }

    var body: some View {
        let inHome = cameras.filter(\.homekit), outside = cameras.filter { !$0.homekit }
        Form {
            // Nothing in the Home app works without the background service: said once, at the top, with its fix
            // (each camera would otherwise say it again).
            if !inHome.isEmpty, !serviceRunning {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The Home app can\u{2019}t reach your cameras")
                            Text("It reaches them through Pond\u{2019}s background recorder, which isn\u{2019}t running.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Start Recorder") { model.applyHomeKitChange() }
                    }
                }
            }
            Section {
                if inHome.isEmpty {
                    Text("No camera is in the Home app yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(inHome) { camera in
                        HomeKitCameraRow(camera: camera, serviceRunning: serviceRunning) { pairing = Pairing(id: camera.id) }
                    }
                }
            } header: {
                Text("In the Home app")
            } footer: {
                Text("Each camera is an accessory of its own in the Home app, served by this Mac. A camera recording to HomeKit Secure Video sends its clips to your home hub, which keeps them in iCloud.")
                    .foregroundStyle(.secondary)
            }
            sensorSection
            if !outside.isEmpty {
                Section("Not in the Home app") {
                    ForEach(outside) { camera in
                        HStack(spacing: 10) {
                            CameraSymbol(camera: camera)
                            Text(camera.name).lineLimit(1)
                            Spacer()
                            Button("Add to the Home App\u{2026}") {
                                model.setHomeKit(camera.id, true)
                                pairing = Pairing(id: camera.id)
                            }
                            .help("Shows its setup code to scan in the Home app. If the recorder is running, it restarts: recording pauses for a few seconds.")
                        }
                    }
                }
            }
        }
        .pageForm()
        .sheet(item: $pairing) { HomeKitPairingSheet(cameraID: $0.id) }
        .sheet(isPresented: $pairingSensor) { SensorPairingSheet() }
        // What the service says of HomeKit, as it changes (a camera added in the Home app, someone watching).
        .task {
            while !Task.isCancelled {
                model.refreshHomeKit()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Pond's own sensor: off (and what it's for), or how it is and what it says now.
    var sensorSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "sensor.fill").foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    if model.config?.homekitSensor == true {
                        let sensor = model.homeKitSensor
                        HStack(spacing: 6) {
                            Text("Recording")
                            Circle().fill(sensorColor(sensor)).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(sensorTitle(sensor)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let alert = sensor?.alert {
                            Text(alert).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Pond\u{2019}s own sensor")
                        Text("Lets the Home app tell you, wherever you are, when Pond stops recording.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if model.config?.homekitSensor == true {
                    if let sensor = model.homeKitSensor, !sensor.paired, sensor.running {
                        Button("Show Setup Code\u{2026}") { pairingSensor = true }
                    }
                    Button("Turn Off") { model.setHomeKitSensor(false) }
                        .help("Stops the sensor; it stays in the Home app, not responding, until it\u{2019}s removed there")
                } else {
                    Button("Add to the Home App\u{2026}") {
                        model.setHomeKitSensor(true)
                        pairingSensor = true
                    }
                    .help("Shows its setup code to scan in the Home app")
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Pond\u{2019}s status")
        } footer: {
            Text("A contact sensor named Recording: closed while Pond records, open when a camera hasn\u{2019}t recorded for 5 minutes, the recordings drive can\u{2019}t be written to, or this Mac goes to sleep. Turn on its notifications in the Home app (the sensor\u{2019}s settings \u{203A} Status and Notifications). If this Mac is off or Pond\u{2019}s recorder isn\u{2019}t running, the Home app shows it as Not Responding, which it doesn\u{2019}t notify about.")
                .foregroundStyle(.secondary)
        }
    }

    func sensorTitle(_ sensor: HomeKitStatus.Sensor?) -> String {
        guard serviceRunning, let sensor, sensor.running else { return serviceRunning ? "Starting\u{2026}" : "Recorder not running" }
        if !sensor.paired { return "Not added to the Home app yet" }
        return sensor.alert == nil ? "Closed: all well" : "Open"
    }

    func sensorColor(_ sensor: HomeKitStatus.Sensor?) -> Color {
        guard serviceRunning, let sensor, sensor.running else { return .secondary }
        if !sensor.paired || sensor.alert != nil { return .orange }
        return .green
    }

    var serviceRunning: Bool {
        if case .running = model.serviceState { true } else { false }
    }
}

/// A camera's symbol, as in the sidebar: a doorbell or a camera.
struct CameraSymbol: View {
    let camera: Config.Camera

    var body: some View {
        Image(systemName: camera.kind == .doorbell ? "video.doorbell" : "video")
            .foregroundStyle(.secondary)
            .frame(width: 20)
    }
}

/// One camera in the Home app: its name, how it's doing there, what it sends, and the one thing to do.
struct HomeKitCameraRow: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    let serviceRunning: Bool
    let showSetup: () -> Void

    var body: some View {
        let state = model.homeKitState(for: camera) ?? .serviceStopped
        let text = HomeKitText(state, camera: camera)
        let recording = model.homeKitRecording(for: camera).map { RecordingText($0, camera: camera) }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            CameraSymbol(camera: camera)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(camera.name).lineLimit(1)
                    Circle().fill(color(state, recording)).frame(width: 8, height: 8).accessibilityHidden(true)
                    // (Under "In the Home app", a camera that's well isn't said to be in it again.)
                    Text(state == .ready ? "No problems" : state == .live ? "Being watched" : text.title)
                        .foregroundStyle(state.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                // What it sends there (once it's there).
                if !state.needsAttention || state.isDoorbellOnly {
                    Text(sends(state, recording))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // What's wrong (the stopped service is said once, above the list).
                    if state != .serviceStopped || serviceRunning {
                        Text(text.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
            action(state, text)
        }
        .padding(.vertical, 2)
        .help(recording?.detail ?? text.detail)
    }

    /// The one thing to do: add it with its code, fix what's wrong, or its own HomeKit settings.
    @ViewBuilder
    func action(_ state: HomeKitState, _ text: HomeKitText) -> some View {
        switch state {
        case .notAdded:
            Button("Show Setup Code\u{2026}") { showSetup() }
        case .serviceStopped:
            EmptyView()
        default:
            if text.actions.contains(.showLog) {
                Button("Show Log") { HomeKitText.openLog() }
            } else if text.actions.contains(.startService) {
                Button("Restart Recorder") { model.applyHomeKitChange() }
            } else {
                Button("Settings\u{2026}") { model.showCameraSettings(camera.id, focus: nil) }
                    .help("\(camera.name)\u{2019}s settings, HomeKit among them")
            }
        }
    }

    /// Live video always; HomeKit Secure Video when it's offered (its state, and its last clip); a doorbell's ring.
    func sends(_ state: HomeKitState, _ recording: RecordingText?) -> String {
        var parts = ["Live video"]
        if let recording {
            let r = model.homeKitRecording(for: camera)
            // Off now after being on (home and away can differ): until when, rather than its last clip.
            let when = r.flatMap { $0.on ? nil : $0.onUntil }.map { ", on until \(RecordingText.when($0, now: Date()))" }
                ?? lastClip.map { ", last \($0)" } ?? ""
            parts.append("Secure Video: " + recording.title.lowercasedFirst + when)
        }
        if camera.kind == .doorbell {
            if case .doorbellButton = state { parts.append("doesn\u{2019}t ring") } else { parts.append("rings") }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// When the hub last took a clip ("at 2:57 PM", "yesterday at 9:12 AM").
    var lastClip: String? {
        model.homeKitRecording(for: camera)?.lastClip.map { RecordingText.when($0.at, now: Date()) }
    }

    func color(_ state: HomeKitState, _ recording: RecordingText?) -> Color {
        if state == .serviceStopped { return .secondary }
        if state.needsAttention && !state.isDoorbellOnly { return .orange }
        if recording?.attention == true || state.isDoorbellOnly { return .orange }
        return .green
    }
}

extension HomeKitState {
    /// In the Home app and working, all but a doorbell's ring.
    var isDoorbellOnly: Bool {
        if case .doorbellButton = self { true } else { false }
    }
}

extension String {
    /// "Recording motion" → "recording motion" (a title used inside a sentence).
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// A camera's setup code, over the HomeKit page, as it's added: the code and QR code until the Home app has it,
/// then that it's in.
struct HomeKitPairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let cameraID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add \(model.config?.cameras.first { $0.id == cameraID }?.name ?? "the Camera") to the Home App")
                .font(.title2.bold())
            HomeKitPairing(cameraID: cameraID)
            Text("In the Home app: + \u{203A} Add Accessory, then scan the code (or enter it).")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task {
            while !Task.isCancelled {
                model.refreshHomeKit()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Pond's own sensor's setup code, as it's added: the code and QR code until the Home app has it, then that it's in.
struct SensorPairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Pond\u{2019}s Sensor to the Home App").font(.title2.bold())
            if let sensor = model.homeKitSensor, sensor.paired {
                Label("Pond\u{2019}s sensor is in the Home app", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text("To hear when Pond stops recording: in the Home app, open the sensor\u{2019}s settings \u{203A} Status and Notifications, and turn on Activity Notifications.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let setup = model.homeKitSensor?.setup { HomeKitSetupCode(code: setup.code, payload: setup.uri) }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.homeKitSensor?.setup == nil ? "Starting HomeKit\u{2026}" : "Waiting for the Home app\u{2026}")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task {
            while !Task.isCancelled {
                model.refreshHomeKit()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
