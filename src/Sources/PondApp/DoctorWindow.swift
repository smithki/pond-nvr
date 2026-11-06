// The camera window (⌥⌘D, Window › Cameras): a camera's health and its settings in one place, beside the live view
// or the timeline it's about, where the toolbar's overview is for noticing and the quick fix. A list down its side
// (this Mac's recorder, then each camera with its state), and the page for what's chosen: the recorder (whether it
// runs, the media engine, its log), every camera at a glance, or one camera: its Doctor (findings, day and record)
// or its Settings (what Settings › Cameras opens for it, here on its page).
import Devices
import PondCore
import SwiftUI

/// What the doctor's window shows.
enum DoctorPage: Hashable {
    /// Every camera at a glance (and the thresholds).
    case cameras
    case recorder
    case camera(String)
}

/// A camera's page: its doctor, or its settings.
enum CameraTab: Hashable {
    case doctor, settings
}

extension AppModel {
    /// Opens the doctor's window (or brings it forward) at a page.
    func showDoctor(_ page: DoctorPage = .cameras) {
        doctorPage = page
        AppModel.openWindow?(DoctorWindow.id)
        NSApp.activate()
    }

    /// The doctor at a camera, or at every camera.
    func showDoctor(camera: String?) {
        cameraTab = .doctor
        showDoctor(camera.map(DoctorPage.camera) ?? .cameras)
    }

    /// A camera's page in the camera window, at its doctor or its settings.
    func showCamera(_ camera: String, tab: CameraTab) {
        cameraTab = tab
        showDoctor(.camera(camera))
    }

    /// The camera the doctor's camera page shows (nil: every camera), as DoctorView reads it.
    var doctorCamera: String? {
        get { if case let .camera(id) = doctorPage { id } else { nil } }
        set { doctorPage = newValue.map(DoctorPage.camera) ?? .cameras }
    }
}

struct DoctorWindow: View {
    static let id = "doctor"
    /// Its one size (it isn't resized: PondApp).
    static let size = CGSize(width: 960, height: 680)
    static let sidebarWidth = 230.0
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        let cameras = model.config?.cameras ?? []
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding(get: { Optional(model.doctorPage) }, set: { if let page = $0 { model.doctorPage = page } })) {
                Section(model.thisPondName) {
                    DoctorRow(title: "Recorder", subtitle: model.recorderWords, dot: recorderColour)
                        .tag(DoctorPage.recorder)
                    DoctorRow(title: "All Cameras", subtitle: summary(cameras), symbol: "square.grid.2x2")
                        .tag(DoctorPage.cameras)
                }
                Section("Cameras") {
                    ForEach(cameras) { camera in
                        let worst = model.doctor.worst(camera.id)
                        DoctorRow(title: camera.name,
                                  subtitle: worst?.headline ?? (model.isPrivate(camera.id) ? "Private" : "No problems"),
                                  dot: StatusDot(finding: worst, isPrivate: model.isPrivate(camera.id)).color)
                            .tag(DoctorPage.camera(camera.id))
                    }
                }
                // Other Ponds' cameras, with what this Mac knows of them (their doctor is on their own Mac).
                ForEach(model.remotePonds, id: \.id) { pond in
                    Section(pond.name) {
                        ForEach(pond.cameras ?? [], id: \.id) { camera in
                            let state = model.remoteState(pond, camera)
                            DoctorRow(title: camera.name, subtitle: state.words, dot: state.dot)
                                .tag(DoctorPage.camera(camera.id))
                        }
                    }
                }
            }
            // The list always shown, at one width: hidden, the page would widen past what it's laid out for.
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                if model.config == nil {
                    ContentUnavailableView("No settings yet", systemImage: "stethoscope",
                                           description: Text("Set Pond up in its main window first."))
                } else if model.doctorPage == .recorder {
                    RecorderView()
                } else if model.cameraTab == .settings, case let .camera(id) = model.doctorPage,
                          let camera = cameras.first(where: { $0.id == id }) {
                    // Its settings, here on its page (a page of their own for each camera: its fields its own).
                    EditCameraSheet(camera: camera, embedded: true).id(camera.id)
                } else if case let .camera(id) = model.doctorPage, let (pond, camera) = remoteCamera(id) {
                    RemoteCameraPage(pond: pond, camera: camera)
                } else {
                    DoctorView()
                }
            }
            .navigationTitle(title(cameras))
            // A camera's page: its doctor, or its settings. And on every page an action of its own (the toolbar's
            // there on each, so the page doesn't move from one to the next).
            .toolbar {
                ToolbarItem(placement: .primaryAction) { pageAction(cameras) }
                if case let .camera(id) = model.doctorPage, cameras.contains(where: { $0.id == id }) {
                    ToolbarItem(placement: .principal) {
                        Picker("Page", selection: $model.cameraTab) {
                            Text("Doctor").tag(CameraTab.doctor)
                            Text("Settings").tag(CameraTab.settings)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .focusEffectDisabled()
                    }
                }
            }
        }
        // The doctor's findings for the list's dots: every 5 s while it's open (every 30 s otherwise, from the main
        // window).
        .task {
            while !Task.isCancelled {
                await model.doctor.refresh(config: model.config)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onAppear { AppModel.openWindow = { openWindow(id: $0) } }
    }

    func title(_ cameras: [Config.Camera]) -> String {
        switch model.doctorPage {
        case .recorder: "Recorder"
        case .cameras: "Cameras"
        case let .camera(id): cameras.first { $0.id == id }?.name ?? remoteCamera(id)?.camera.name ?? "Cameras"
        }
    }

    /// The page's own action: a camera into Live, every camera checked, the recorder restarted.
    @ViewBuilder func pageAction(_ cameras: [Config.Camera]) -> some View {
        switch model.doctorPage {
        case let .camera(id):
            Button("Show in Live", systemImage: "play.rectangle") { model.showInLive(id) }
                .help("Show \(title(cameras)) alone in Live, in the main window")
                .disabled(!cameras.contains { $0.id == id } && remoteCamera(id) == nil)
        case .cameras:
            let checking = !model.doctor.checking.isEmpty
            Button(checking ? "Checking\u{2026}" : "Check All Cameras", systemImage: "stethoscope") {
                Task { for camera in cameras { await model.doctor.check(camera, model: model) } }
            }
            .help("Watch each camera\u{2019}s video for a few seconds and read its controls, one after another")
            .disabled(checking || cameras.isEmpty)
        case .recorder:
            Button("Restart Recorder", systemImage: "arrow.clockwise") { _ = model.restartService() }
                .help("Stop the background recorder and start it again")
                .disabled(model.isRestartingRecorder)
        }
    }

    /// Another Pond's camera by its id, with its Pond.
    func remoteCamera(_ id: String) -> (pond: ControlSocket.RemotePond, camera: ControlSocket.RemotePond.Camera)? {
        guard AppModel.pond(of: id) != nil else { return nil }
        for pond in model.remotePonds {
            if let camera = pond.cameras?.first(where: { $0.id == id }) { return (pond, camera) }
        }
        return nil
    }

    func summary(_ cameras: [Config.Camera]) -> String {
        let marked = cameras.count { model.doctor.mark($0.id) != nil }
        return marked == 0 ? "No problems" : marked == 1 ? "1 needs attention" : "\(marked) need attention"
    }

    var recorderColour: Color {
        switch model.serviceState {
        case _ where model.isRestartingRecorder: .secondary
        case .running where model.needsRestart: .orange
        case .running: .green
        case .stopped: .red
        case .notInstalled: .secondary
        }
    }
}

/// A row of the doctor's list: a dot (or a symbol) for its state, its name, and its state in words.
struct DoctorRow: View {
    let title: String
    let subtitle: String
    var dot: Color?
    var symbol: String?

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 10)
            } else {
                Circle().fill(dot ?? .secondary).frame(width: 9, height: 9).frame(width: 10)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Another Pond's camera: what this Mac knows of it (whether its Pond is connected, and whether it's private). Its
/// doctor and its settings are on its own Pond's Mac, where its recordings are.
struct RemoteCameraPage: View {
    @Environment(AppModel.self) private var model
    let pond: ControlSocket.RemotePond
    let camera: ControlSocket.RemotePond.Camera

    var device: ControlSocket.RemoteDevice? { model.otherPonds.first { $0.id == pond.id } }

    var body: some View {
        Form {
            Section {
                LabeledContent("Pond", value: pond.name)
                LabeledContent("Connection", value: device.map(model.connection) ?? "Not connected")
                if let problem = pond.problem {
                    LabeledContent("Problem", value: problem)
                }
                LabeledContent("Camera", value: camera.isPrivate ? "Private" : camera.waking ? "Waking up" : "Shown")
                if let made = camera.model, !made.isEmpty {
                    LabeledContent("Model", value: made)
                }
            } footer: {
                Text("Its health and settings are kept on \(pond.name)\u{2019}s Mac, with its recordings. Open Pond there to see its doctor or change it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension AppModel {
    /// Another Pond's camera, for its row: in a few words, and its dot.
    func remoteState(_ pond: ControlSocket.RemotePond, _ camera: ControlSocket.RemotePond.Camera) -> (words: String, dot: Color) {
        let connected = otherPonds.first { $0.id == pond.id }.map(isConnected) ?? false
        if pond.problem != nil { return ("\(pond.name) can\u{2019}t be reached", .orange) }
        if !connected { return ("\(pond.name) not connected", .secondary) }
        if camera.isPrivate { return ("Private", .indigo) }
        return (camera.waking ? "Waking up" : "Connected", .green)
    }
}
