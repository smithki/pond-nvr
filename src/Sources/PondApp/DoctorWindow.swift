// The doctor, in a window of its own (⌥⌘D, Window › Doctor): for working out why, beside the live view or the
// timeline it's about, where the toolbar's overview is for noticing and the quick fix. A list down its side (this
// Mac's recorder, then each camera with its state), and the page for what's chosen: the recorder (whether it runs,
// the media engine, its log), every camera at a glance, or one camera's findings, day and record.
import PondCore
import SwiftUI

/// What the doctor's window shows.
enum DoctorPage: Hashable {
    /// Every camera at a glance (and the thresholds).
    case cameras
    case recorder
    case camera(String)
}

extension AppModel {
    /// Opens the doctor's window (or brings it forward) at a page.
    func showDoctor(_ page: DoctorPage = .cameras) {
        doctorPage = page
        AppModel.openWindow?(DoctorWindow.id)
        NSApp.activate()
    }

    /// The doctor at a camera, or at every camera.
    func showDoctor(camera: String?) { showDoctor(camera.map(DoctorPage.camera) ?? .cameras) }

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
                } else {
                    DoctorView()
                }
            }
            .navigationTitle(title(cameras))
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
        case .cameras: "Doctor"
        case let .camera(id): cameras.first { $0.id == id }?.name ?? "Doctor"
        }
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
