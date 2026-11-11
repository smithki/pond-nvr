// The Settings window (⌘,; Pond › Settings…, the toolbar's overview and Cameras button, the menu bar item): every
// setting that isn't changed where it's used, and the health of the recorder and each camera, beside the live view or
// the timeline they're about. (A camera's everyday settings are also in a panel over the main window, from wherever
// the camera is: CameraSettingsPanel.) Its sidebar has two layers, sliding between them: this Pond's settings
// (General, Storage, Remote Access, Cameras ›, Advanced), and, from Cameras, the recorder, every camera at a glance
// and each camera, dragged into order, with Add Camera under them. A camera's page has its Doctor (findings, day and
// record) and its Settings as tabs. One window, as wide and tall as one likes; its pages' cards keep one margin.
import Devices
import PondCore
import SwiftUI

/// What the Settings window shows.
enum SettingsPage: Hashable {
    case general, storage, remote, homeKit, advanced
    /// This Mac's recorder (whether it runs, the media engine, its log).
    case recorder
    /// Every camera at a glance (and the thresholds).
    case cameras
    case camera(String)

    /// On the sidebar's Cameras layer (the recorder and the cameras), not its first.
    var isCameras: Bool {
        switch self {
        case .recorder, .cameras, .camera: true
        default: false
        }
    }

    /// From `--settings NAME` (and the names of the old Settings tabs).
    init?(name: String) {
        switch name {
        case "general": self = .general
        case "storage": self = .storage
        case "remote": self = .remote
        case "homekit": self = .homeKit
        case "advanced": self = .advanced
        case "recorder": self = .recorder
        case "cameras": self = .cameras
        default: return nil
        }
    }
}

/// A camera's page: its doctor, or its settings.
enum CameraTab: Hashable {
    case doctor, settings
}

extension AppModel {
    /// Opens the Settings window (or brings it forward), at a page.
    func showSettings(_ page: SettingsPage) {
        settingsPage = page
        AppModel.openWindow?(SettingsWindow.id)
        NSApp.activate()
    }

    /// Opens the Settings window where it was (General, the first time).
    func showSettings() {
        AppModel.openWindow?(SettingsWindow.id)
        NSApp.activate()
    }

    /// The doctor at a camera, or at every camera.
    func showDoctor(camera: String?) {
        cameraTab = .doctor
        showSettings(camera.map(SettingsPage.camera) ?? .cameras)
    }

    /// A camera's page in the Settings window, at its doctor or its settings.
    func showCamera(_ camera: String, tab: CameraTab) {
        cameraTab = tab
        showSettings(.camera(camera))
    }

    /// The camera the doctor's camera page shows (nil: every camera), as DoctorView reads it.
    var doctorCamera: String? {
        get { if case let .camera(id) = settingsPage { id } else { nil } }
        set { settingsPage = newValue.map(SettingsPage.camera) ?? .cameras }
    }
}

struct SettingsWindow: View {
    static let id = "settings"
    /// The sidebar's width: dragged between `least` and `most`, never closed.
    static let sidebarWidth = (least: 220.0, ideal: 250.0, most: 340.0)
    /// The page's width as the window first opens: the cards at their widest (PageMargin.readable) with room to
    /// either side.
    static let pageWidth = 850.0
    /// As it first opens: the sidebar at its ideal width, the page at `pageWidth`.
    static let size = CGSize(width: sidebarWidth.ideal + pageWidth, height: 760)
    static let least = CGSize(width: 960, height: 680)
    /// The widest it goes: the sidebar at its widest beside the page at `pageWidth`. Wider only ever widened the
    /// margins (the cards stop at PageMargin.readable).
    static let mostWidth = sidebarWidth.most + pageWidth
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var adding = false
    /// The sidebar's Cameras layer shown (slid in over its first): on opening at a camera or the recorder, on
    /// choosing Cameras; back with its "Settings" row (the page stays until another is chosen).
    @State private var camerasShown = false
    /// The first layer's page last shown, gone back to from the Cameras layer.
    @State private var lastPondPage = SettingsPage.general
    /// Always both columns: set back to it if the split view closes the sidebar all the same (there's no toggle).
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        let cameras = model.config?.cameras ?? []
        NavigationSplitView(columnVisibility: $columns) {
            ZStack {
                if camerasShown {
                    camerasLayer(cameras)
                        .transition(.move(edge: .trailing))
                } else {
                    settingsLayer(cameras)
                        .transition(.move(edge: .leading))
                }
            }
            .clipped()
            // The list always shown: dragged wider or narrower within its bounds, never closed (SidebarBounds; and
            // `columns` opens it again if it's closed all the same). The pages keep their margins at any width
            // (PageMargin), so their width may change.
            .navigationSplitViewColumnWidth(min: Self.sidebarWidth.least, ideal: Self.sidebarWidth.ideal,
                                            max: Self.sidebarWidth.most)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(cameras)
                .navigationTitle(title(cameras))
                // A camera's page: its doctor, or its settings; and the page's own action, where it has one.
                .toolbar {
                    if model.settingsPage.isCameras {
                        ToolbarItem(placement: .primaryAction) { pageAction(cameras) }
                    } else {
                        // Held but unseen, with no glass: a toolbar with nothing in it is drawn shorter, and the
                        // window (its traffic lights, its pages) moved going between these pages and the cameras'.
                        ToolbarItem(placement: .primaryAction) {
                            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    if case let .camera(id) = model.settingsPage, cameras.contains(where: { $0.id == id }) {
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
        .onChange(of: columns) { if columns != .all { columns = .all } }
        // Its bounds where a drag keeps to them: AppKit's split view item (SwiftUI's own column width isn't kept to).
        .background(SidebarBounds(least: Self.sidebarWidth.least, ideal: Self.sidebarWidth.ideal, most: Self.sidebarWidth.most))
        // Opened at a camera or the recorder (from Live, the overview, a link): on the Cameras layer.
        .onChange(of: model.settingsPage, initial: true) { _, page in
            if !page.isCameras { lastPondPage = page }
            if page.isCameras != camerasShown { withAnimation(Self.slide) { camerasShown = page.isCameras } }
        }
        .onChange(of: camerasShown, initial: true) { SidebarProbe.camerasShown = camerasShown }
        // The doctor's findings for the list's dots: every 5 s while it's open (every 30 s otherwise, from the main
        // window).
        .task {
            while !Task.isCancelled {
                await model.doctor.refresh(config: model.config)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // Measured as it opens, so Storage has it before it's first shown.
        .task { await model.refreshStorageOutlook() }
        .onAppear { AppModel.openWindow = { openWindow(id: $0) } }
        .sheet(isPresented: $adding) { AddCameraSheet() }
        .sheet(item: $model.fullLog) { FullLogSheet(which: $0) }
        // What couldn't be saved, said here (where it was changed), as in the main window.
        .alert("Not saved", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }

    /// The slide between the sidebar's layers.
    static let slide = Animation.snappy(duration: 0.32)

    /// The sidebar's first layer: this Pond's settings, and Cameras (sliding to its layer).
    func settingsLayer(_ cameras: [Config.Camera]) -> some View {
        List(selection: Binding(get: { Optional(model.settingsPage.isCameras ? .cameras : model.settingsPage) },
                                set: { page in
                                    guard let page else { return }
                                    model.settingsPage = page
                                    // Cameras chosen: in to its layer.
                                    if page.isCameras { withAnimation(Self.slide) { camerasShown = true } }
                                })) {
            Section {
                SidebarRow(title: "General", subtitle: "Name, appearance, menu bar, search", symbol: "gearshape")
                    .tag(SettingsPage.general)
                    .background(SidebarProbe(layer: "settings"))
                let storage = storageState
                SidebarRow(title: "Storage", subtitle: storage.words, symbol: "externaldrive", dot: storage.dot)
                    .tag(SettingsPage.storage)
                let remote = remoteAccessState
                SidebarRow(title: "Remote Access", subtitle: remote.words, symbol: "network", dot: remote.dot)
                    .tag(SettingsPage.remote)
                let homeKit = homeKitState(cameras)
                SidebarRow(title: "HomeKit", subtitle: homeKit.words, symbol: "homekit", dot: homeKit.dot)
                    .tag(SettingsPage.homeKit)
                let all = camerasState(cameras)
                SidebarRow(title: "Cameras", subtitle: all.words, symbol: "video", dot: all.dot, drills: true)
                    .tag(SettingsPage.cameras)
                // In line with the rest (a section of its own stood it apart, with more room above it than between
                // the others).
                SidebarRow(title: "Advanced", subtitle: advancedWords, symbol: "gearshape.2")
                    .tag(SettingsPage.advanced)
            } header: {
                // As tall as the Cameras layer's back button's heading (headingHeight).
                Text(model.thisPondName)
                    .frame(maxWidth: .infinity, minHeight: Self.headingHeight, maxHeight: Self.headingHeight, alignment: .leading)
            }
        }
        // → on Cameras goes in, as a click does.
        .onKeyPress(.rightArrow) {
            guard model.settingsPage.isCameras else { return .ignored }
            withAnimation(Self.slide) { camerasShown = true }
            return .handled
        }
    }

    /// The sidebar's Cameras layer: back to Settings, the recorder, every camera, each camera (in order, dragged),
    /// other Ponds' cameras, and Add Camera under them.
    func camerasLayer(_ cameras: [Config.Camera]) -> some View {
        List(selection: Binding(get: { Optional(model.settingsPage) }, set: { if let page = $0 { model.settingsPage = page } })) {
            // Back to the first layer: the list's own first section's heading, so both layers' rows start at the same
            // place (an inset over the list moved the first layer's rows as it slid back). An ordinary button, in
            // the keyboard's Tab order.
            Section {
                SidebarRow(title: "Recorder", subtitle: model.recorderWords, symbol: "record.circle", dot: recorderColour)
                    .tag(SettingsPage.recorder)
                    .background(SidebarProbe(layer: "cameras"))
                let all = camerasState(cameras)
                SidebarRow(title: "All Cameras", subtitle: all.words, symbol: "square.grid.2x2", dot: all.dot)
                    .tag(SettingsPage.cameras)
            } header: {
                // A control of its own, as the Add Camera capsule under the list is: flat, small enough to stand in
                // the heading's place without moving the rows under it.
                Button { back() } label: {
                    Label(model.thisPondName, systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                // Laid out as tall as the heading it stands in for (the capsule is 1 pt taller, and moved the rows
                // under it: measured, sidebar.txt).
                // Clear of the first row's highlight under it (they touched), as tall as the first layer's heading.
                .frame(maxWidth: .infinity, minHeight: Self.headingHeight, maxHeight: Self.headingHeight, alignment: .leading)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to this Pond\u{2019}s settings (\u{2318}[)")
                .textCase(nil)
            }
            Section("Cameras") {
                ForEach(cameras) { camera in
                    let worst = model.doctor.worst(camera.id)
                    // No password first: nothing else can be known of it until it has one.
                    let noPassword = !model.hasPassword(camera.id)
                    SidebarRow(title: camera.name,
                               subtitle: noPassword ? "No password"
                                   : worst?.headline ?? (model.isPrivate(camera.id) ? "Private" : "No problems"),
                               symbol: camera.kind == .doorbell ? "video.doorbell" : "video",
                               dot: noPassword ? .orange : StatusDot(finding: worst, isPrivate: model.isPrivate(camera.id)).color)
                        .tag(SettingsPage.camera(camera.id))
                }
                // Dragged into order: the order they're shown in everywhere (Live, the timeline, Events).
                .onMove { from, to in
                    guard let first = from.first else { return }
                    model.moveCamera(cameras[first].id, to: to > first ? to - 1 : to)
                }
            }
            // Other Ponds' cameras, with what this Mac knows of them (their doctor is on their own Mac).
            ForEach(model.remotePonds, id: \.id) { pond in
                Section(pond.name) {
                    ForEach(pond.cameras ?? [], id: \.id) { camera in
                        let state = model.remoteState(pond, camera)
                        SidebarRow(title: camera.name, subtitle: state.words, symbol: "video", dot: state.dot)
                            .tag(SettingsPage.camera(camera.id))
                    }
                }
            }
        }
        // ← goes back, as the heading's button does.
        .onKeyPress(.leftArrow) {
            back()
            return .handled
        }
        // Add Camera, under the list: a plain capsule (the system's bordered button, flat, not glass), centred.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { adding = true } label: { Label("Add Camera\u{2026}", systemImage: "plus") }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .help("Add a camera by its address, or one found on your network")
                .disabled(model.config == nil)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    /// Each layer's first heading's height: the back button's capsule and room under it, clear of a chosen row's
    /// highlight; the first layer's the same, so both layers' rows start at one place.
    static let headingHeight = 28.0

    /// Back to the sidebar's first layer, and to the page of it last shown (General if none): Cameras isn't chosen
    /// there any more, so choosing it, anywhere on its row, goes in again. (Left chosen, a click on it changed
    /// nothing: the list says nothing of a click on the row already chosen.)
    func back() {
        withAnimation(Self.slide) {
            camerasShown = false
            model.settingsPage = lastPondPage
        }
    }

    /// The chosen page.
    @ViewBuilder func detail(_ cameras: [Config.Camera]) -> some View {
        switch model.settingsPage {
        case .general: GeneralSettings()
        case .advanced: AdvancedSettings()
        case .storage: needsSettings { StorageView() }
        case .remote: needsSettings { RemoteAccessView() }
        case .homeKit: needsSettings { HomeKitPage() }
        case .recorder: needsSettings { RecorderView() }
        case .cameras: needsSettings { DoctorView() }
        case let .camera(id):
            needsSettings {
                if let camera = cameras.first(where: { $0.id == id }) {
                    if model.cameraTab == .settings {
                        // Its settings, here on its page (a page of their own for each camera: its fields its own).
                        CameraSettingsPage(camera: camera).id(camera.id)
                    } else {
                        DoctorView()
                    }
                } else if let (pond, camera) = remoteCamera(id) {
                    RemoteCameraPage(pond: pond, camera: camera)
                } else {
                    DoctorView()
                }
            }
        }
    }

    /// A page that needs Pond set up first: until then, the setup.
    @ViewBuilder func needsSettings(@ViewBuilder _ content: () -> some View) -> some View {
        if model.config == nil { SetupView() } else { content() }
    }

    func title(_ cameras: [Config.Camera]) -> String {
        switch model.settingsPage {
        case .general: "General"
        case .storage: "Storage"
        case .remote: "Remote Access"
        case .homeKit: "HomeKit"
        case .advanced: "Advanced"
        case .recorder: "Recorder"
        case .cameras: "Cameras"
        case let .camera(id): cameras.first { $0.id == id }?.name ?? remoteCamera(id)?.camera.name ?? "Cameras"
        }
    }

    /// The page's own action: a camera into Live, every camera checked, the recorder restarted.
    @ViewBuilder func pageAction(_ cameras: [Config.Camera]) -> some View {
        switch model.settingsPage {
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
        default:
            EmptyView()
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

    /// A dot for the worst of what needs attention (the toolbar's overview's list), else all's well.
    func dot(_ items: [Attention]) -> Color {
        items.contains { $0.level == .problem } ? .red : items.contains { $0.level == .warning } ? .orange : .green
    }

    /// Every camera: how many, and how many need attention (the overview's, so the two agree).
    func camerasState(_ cameras: [Config.Camera]) -> (words: String, dot: Color?) {
        guard !cameras.isEmpty else { return ("None yet: add one", nil) }
        let items = model.attention.filter { $0.camera != nil && $0.level >= .warning && $0.pond == nil }
        let count = cameras.count == 1 ? "1 camera" : "\(cameras.count) cameras"
        if items.isEmpty { return ("\(count) \u{00B7} no problems", .green) }
        return ("\(count) \u{00B7} \(items.count) need\(items.count == 1 ? "s" : "") attention", dot(items))
    }

    /// Storage: the drive's trouble if it has some, else how long recordings are kept and the room for them.
    var storageState: (words: String, dot: Color?) {
        guard model.config != nil else { return ("Where recordings go, how long they stay", nil) }
        let items = model.attention.filter { $0.fix == .storageSettings }
        if let first = items.first { return (first.short, dot(items)) }
        guard let outlook = model.lastStorageOutlook else { return ("Where recordings go, how long they stay", nil) }
        let keep = outlook.keepDays == 1 ? "1 day" : "\(outlook.keepDays) days"
        return ("Keeps \(keep) of recordings", .green)
    }

    /// Remote Access: off, or the other Ponds paired, connected or in trouble.
    var remoteAccessState: (words: String, dot: Color?) {
        guard let remote = model.config?.remote, remote.enabled else { return ("Off \u{00B7} reach this Mac from elsewhere", nil) }
        let items = model.attention.filter { $0.fix == .remoteSettings }
        if let first = items.first { return (first.short, dot(items)) }
        let ponds = model.otherPonds, connected = ponds.count { model.isConnected($0) }
        if ponds.isEmpty { return ("On \u{00B7} nothing paired yet", .green) }
        return ("On \u{00B7} \(connected) of \(ponds.count) Pond\(ponds.count == 1 ? "" : "s") connected", .green)
    }

    /// HomeKit: how many cameras are in the Home app, or the first that needs something done.
    func homeKitState(_ cameras: [Config.Camera]) -> (words: String, dot: Color?) {
        let inHome = cameras.filter(\.homekit)
        guard !inHome.isEmpty else { return ("No cameras in the Home app", nil) }
        let count = "\(inHome.count) of \(cameras.count) camera\(cameras.count == 1 ? "" : "s") in the Home app"
        let states = inHome.compactMap { camera in model.homeKitState(for: camera).map { (camera, $0) } }
        if states.contains(where: { $0.1 == .serviceStopped }) { return ("Off \u{00B7} the recorder isn\u{2019}t running", .orange) }
        if let (camera, state) = states.first(where: { $0.1.needsAttention }) {
            return ("\(camera.name): \(HomeKitText(state, camera: camera).title.lowercasedFirst)", .orange)
        }
        if inHome.contains(where: { camera in model.homeKitRecording(for: camera).map { RecordingText($0, camera: camera).attention } == true }) {
            return (count + " \u{00B7} a recording failed", .orange)
        }
        return (count, .green)
    }

    /// Advanced: beta and test features, and the version.
    var advancedWords: String {
        "\(model.config?.testFeatures == true ? "Beta features on" : "Beta features off") \u{00B7} Pond \(Brand.version)"
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
/// A row of the Settings window's sidebar, on either layer alike: what it is (its symbol and name), a line of what's
/// there or how it's doing, said before it's opened, and its state as a dot (none where there's nothing to say); a
/// chevron where choosing it slides to a layer of its own.
struct SidebarRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var dot: Color?
    var drills = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if let dot {
                    Circle().fill(dot).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                // A slot for the chevron on every row, empty where the row doesn't open a list: the dots stand in one
                // column, on rows with a chevron and without.
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .frame(width: 8)
                    .opacity(drills ? 1 : 0)
                    .accessibilityHidden(!drills)
            }
        }
        .padding(.vertical, 3)
        // Its state in words for VoiceOver (the dot is a colour only).
        .accessibilityElement(children: .combine)
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
        .pageForm()
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


/// Holds the Settings window's sidebar to its bounds and keeps it from collapsing as it's dragged: what a drag keeps
/// to is AppKit's split view item (its least and most thickness, whether it can collapse), which SwiftUI sets back to
/// its own defaults as it updates (140 pt, no most, collapsible), and its column width doesn't reach. So they're set
/// on the item, and set again whenever SwiftUI changes them (watched), so they hold between updates, as a drag
/// happens; and closed all the same (by anything), it's opened again.
struct SidebarBounds: NSViewRepresentable {
    let least: Double
    let ideal: Double
    let most: Double

    final class Coordinator {
        var item: NSSplitViewItem?
        var watching: [NSKeyValueObservation] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        attach(view, context.coordinator, tries: 30)
    }

    /// Once the view's in its window: the sidebar's item found, set, and watched.
    func attach(_ view: NSView, _ coordinator: Coordinator, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let root = view.window?.contentView?.superview, let item = Self.sidebarItem(in: root) else {
                if tries > 0 { attach(view, coordinator, tries: tries - 1) }
                return
            }
            apply(to: item)
            // At its ideal width the first time (SwiftUI's ideal isn't kept to: it opened at its least), unless it
            // was left at another (AppKit keeps the width the sidebar was left at, under the split view's name).
            if coordinator.item == nil, let split = Self.splitView(in: root) {
                let left = split.autosaveName.map { UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \($0)") != nil } ?? false
                if AppDefaults.isDemo || !left { split.setPosition(ideal, ofDividerAt: 0) }
            }
            // A demo doesn't remember its sidebar's width: AppKit keeps it in the app's own preferences, the real
            // Pond's (AppDefaults).
            if AppDefaults.isDemo, let split = Self.splitView(in: root), split.autosaveName != nil { split.autosaveName = nil }
            guard coordinator.item !== item else { return }
            coordinator.item = item
            let least = least, ideal = ideal, most = most
            // (Observers are called off the main actor's books; the item's only touched back on the main queue.)
            let again: @Sendable (NSSplitViewItem) -> Void = { item in
                nonisolated(unsafe) let item = item
                DispatchQueue.main.async { SidebarBounds(least: least, ideal: ideal, most: most).apply(to: item) }
            }
            let reopen: @Sendable (NSSplitViewItem) -> Void = { item in
                nonisolated(unsafe) let item = item
                DispatchQueue.main.async { if item.isCollapsed { item.animator().isCollapsed = false } }
            }
            coordinator.watching = [
                item.observe(\.minimumThickness) { item, _ in again(item) },
                item.observe(\.maximumThickness) { item, _ in again(item) },
                item.observe(\.canCollapse) { item, _ in again(item) },
                // Closed all the same (by anything): open again.
                item.observe(\.isCollapsed) { item, _ in reopen(item) },
            ]
        }
    }

    func apply(to item: NSSplitViewItem) {
        if item.canCollapse { item.canCollapse = false }
        if item.minimumThickness != least { item.minimumThickness = least }
        if item.maximumThickness != most { item.maximumThickness = most }
    }

    /// The first split view under `view`.
    static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews { if let split = splitView(in: sub) { return split } }
        return nil
    }

    /// The sidebar's split view item: the sidebar of the first split view's controller under `view`.
    static func sidebarItem(in view: NSView) -> NSSplitViewItem? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
            return controller.splitViewItems.first { $0.behavior == .sidebar } ?? controller.splitViewItems.first
        }
        for sub in view.subviews { if let item = sidebarItem(in: sub) { return item } }
        return nil
    }
}

/// Where a sidebar layer's first row stands in the window, kept for the snapshots' check that both layers' rows
/// start at the same place (Snapshots, sidebar.txt).
struct SidebarProbe: View {
    let layer: String
    @MainActor static var top: [String: Double] = [:]
    /// The Cameras layer shown.
    @MainActor static var camerasShown = false

    var body: some View {
        Color.clear.onGeometryChange(for: Double.self) { $0.frame(in: .global).minY } action: { y in
            Self.top[layer] = y
        }
    }
}
