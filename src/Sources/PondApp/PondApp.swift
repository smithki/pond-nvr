// Pond NVR.app: live view, the recordings timeline and (later) events in one window, and the settings in the
// Settings window (⌘,). Recording itself is done by the login service (`pond run`); closing the app does not
// stop it.
import Control
import SwiftUI
import UserNotifications

@main
struct PondApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage(Appearance.key) private var appearance = Appearance.dark
    @AppStorage(MenuBarItem.key) private var menuBarItem = true

    var body: some Scene {
        Window("Pond", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(appearance.scheme)
                .frame(minWidth: LiveLayout.minimumWindowWidth, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        // Opened at every launch, even if it was closed when Pond last quit (from the menu bar item); only at login does
        // it stay closed (AppDelegate).
        .defaultLaunchBehavior(.presented)
        .commands {
            // The standard Quit is disabled while a sheet is open; this one closes the sheet and quits.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Pond") { AppDelegate.quit() }.keyboardShortcut("q")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(appearance.scheme)
        }

        MenuBarExtra(isInserted: $menuBarItem) {
            MenuBarMenu().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The main window's views, chosen in the toolbar.
enum Mode: String, CaseIterable, Identifiable {
    case live, timeline, events

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .timeline: "Timeline"
        case .events: "Events"
        }
    }

    var symbol: String {
        switch self {
        case .live: "video"
        case .timeline: "calendar.day.timeline.left"
        case .events: "bell.badge"
        }
    }
}

/// Dark unless chosen otherwise in Settings: video reads best on a dark surround.
enum Appearance: String, CaseIterable, Identifiable {
    case dark, light, system

    static let key = "appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Same as the Mac"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(LiveView.railKey) private var showRail = true

    var body: some View {
        @Bindable var model = model
        Group {
            if model.config == nil {
                SetupView()
            } else {
                switch model.mode {
                case .live: LiveView()
                case .timeline: TimelineView()
                case .events: EventsView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Find Cameras' card, over the top right of whatever view is showing: part of the window (no popover
        // window to resize), so it grows and shrinks with its content like any view. A click anywhere else
        // closes it, as a popover's would.
        .overlay {
            if model.showingFoundCameras {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.3)) { model.showingFoundCameras = false } }
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.showingFoundCameras {
                // Its arrow under the button's middle.
                let width: CGFloat = 400, margin: CGFloat = 12
                let arrowX = width - (model.findCamerasButtonFromTrailing - margin)
                FoundCamerasPanel(model: model) {
                    withAnimation(.snappy(duration: 0.3)) { model.showingFoundCameras = false }
                }
                .padding(.top, 10)
                .frame(width: width)
                .glassEffect(.regular, in: Callout(arrowX: arrowX))
                .padding([.top, .trailing], margin)
                .animation(.snappy(duration: 0.3), value: arrowX)
                .transition(.scale(scale: 0.9, anchor: UnitPoint(x: arrowX / width, y: 0)).combined(with: .opacity))
            }
        }
        // Switching views animates the toolbar (its glass morphs as items come and go) but not the views:
        // the one leaving would play its tiles' exit animations over the one arriving.
        .transaction(value: model.mode) { $0.animation = nil }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            // Native toolbar items throughout, so they look and answer the pointer as in any Mac app. Leading:
            // Back and Forward first, by the window's buttons, so they stay put whatever the view (for stepping
            // back several views in a row); then the rail's toggle (in Live) and the recorder's state.
            ToolbarItemGroup(placement: .navigation) {
                Button { withAnimation(.snappy(duration: 0.3)) { model.goBack() } } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model.backHistory.isEmpty)
                .help(model.backHistory.last.map { "Back to \($0.title) (⌘[)" } ?? "Back")
                Button { withAnimation(.snappy(duration: 0.3)) { model.goForward() } } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model.forwardHistory.isEmpty)
                .help(model.forwardHistory.last.map { "Forward to \($0.title) (⌘])" } ?? "Forward")
            }
            // A toggle: the toolbar shows it on while the rail is open. Hidden rather than left out in the other
            // views, so the toolbar's glass morphs as it goes and comes back with the view switch.
            // The rail's toggle, in Live only: a toggle, so the toolbar shows it on while the rail is open. Left
            // out of the toolbar in the other views rather than hidden: it pops cleanly, where the toolbar's
            // hiding fades it out under the recorder's state.
            if model.mode == .live, model.config?.cameras.isEmpty == false {
                ToolbarItem(placement: .navigation) {
                    // Not while there's no room for it beside the open controls (shown, the dock hid it again at
                    // once, and bounced), whoever hid it: a wider window, or the controls closed, and it's back on.
                    let madeRoom = !showRail && (model.railMadeRoom || !model.railFits)
                    Toggle(isOn: $showRail.animation(LiveView.panelAnimation)) {
                        Label(showRail ? "Hide Cameras" : "Show Cameras", systemImage: "sidebar.leading")
                    }
                    .disabled(madeRoom)
                    .help(!madeRoom ? (showRail ? "Hide the list of cameras" : "Show the list of cameras")
                          : model.railMadeRoom ? "The cameras are hidden to make room for the controls; a wider window shows them again"
                          : "No room for the cameras beside the controls; make the window wider, or hide the controls, to show them")
                }
            }
            // The recorder's state, which is also which Pond is shown: its menu has the recorder's settings and the
            // other Ponds paired with this one.
            ToolbarItem(placement: .navigation) {
                PondSwitcher { tab in
                    model.settingsTab = tab
                    openSettings()
                }
            }
            ToolbarItem(placement: .principal) {
                // Animated, so the toolbar's glass morphs as items come and go with the view.
                Picker("View", selection: $model.mode.animation(.snappy(duration: 0.3))) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(model.config == nil)
            }
            // In a demo, which one, always in sight (nothing here is the real setup), in glass of its own; its menu
            // switches to another.
            if let demo = DemoSession.scenario {
                ToolbarItem(placement: .primaryAction) { DemoMenu(current: demo) }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            // Find Cameras, just before Add Camera and in its glass: always there (an item that came and went
            // would rebuild Add Camera's glass each time), showing the cameras found when there are some.
            ToolbarItem(placement: .primaryAction) { FindCamerasButton() }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Find Cameras' card closed: Add Camera lists the cameras on the network too.
                    withAnimation(.snappy(duration: 0.3)) { model.showingFoundCameras = false }
                    model.settingsTab = .cameras
                    model.addingCamera = true
                } label: {
                    Label("Add Camera", systemImage: "plus")
                }
                .help("Add a camera")
                .disabled(model.config == nil)
            }
        }
        .toolbar(removing: .title)
        .sheet(isPresented: $model.addingCamera) { AddCameraSheet() }
        // The Ponds paired with this one, and which are connected, for the switcher: every 10 s (every 2 s until the
        // service first answers).
        .task {
            while !Task.isCancelled {
                if model.config != nil {
                    let reply = await model.controlClient.ask(.init(camera: "", action: "remote.status"), timeout: 5)
                    if reply.remote != nil || model.remoteStatus != nil { model.remoteStatus = reply.remote }
                    // Their cameras, for Live.
                    if !model.otherPonds.isEmpty, let ponds = await model.controlClient.ask(.init(camera: "", action: "remote.ponds"), timeout: 30).ponds,
                       ponds != model.remotePonds {
                        model.remotePonds = ponds
                        // --ponds NAME: that Pond alone shown, once it's known (for trying it, and pictures of it).
                        if let name = launchArgument("--ponds"), model.shownPonds == .all,
                           let pond = ponds.first(where: { $0.name == name }) {
                            model.shownPonds = .pond(pond.id)
                        }
                        model.refreshPrivacy()
                    }
                }
                try? await Task.sleep(for: .seconds(model.remoteStatus == nil ? 2 : 10))
            }
        }
        // Cameras on the network: looked for as the app opens, then again once a day while it stays open
        // (checked each hour).
        .task {
            if model.config != nil { await model.findCameras() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                if model.config != nil { await model.findCamerasIfDue() }
            }
        }
        .task {
            if launchArgument("--settings") != nil { openSettings() }
            // --window WIDTHxHEIGHT: the main window that size (for trying narrow windows, and pictures of them).
            if let size = launchArgument("--window")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                try? await Task.sleep(for: .milliseconds(300))
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
                    var frame = window.frame
                    frame.origin.y += frame.height - size[1]
                    frame.size = CGSize(width: size[0], height: size[1])
                    window.setFrame(frame, display: true)
                }
            }
            // --camera ID: that camera's settings, open (for trying them out, and pictures of them).
            if let id = launchArgument("--camera") {
                model.settingsTab = .cameras
                model.cameraToEdit = id
                openSettings()
            }
            // --doctor [ID]: the doctor, open (at that camera).
            if let at = CommandLine.arguments.firstIndex(of: "--doctor") {
                model.settingsTab = .doctor
                let next = at + 1 < CommandLine.arguments.count ? CommandLine.arguments[at + 1] : ""
                model.doctorCamera = next.hasPrefix("-") || next.isEmpty ? nil : next
                openSettings()
            }
            // --add-camera: Add Camera, open (likewise).
            if CommandLine.arguments.contains("--add-camera") { model.addingCamera = true }
            if let dir = ProcessInfo.processInfo.environment["POND_SNAPSHOTS"] { await Snapshots.take(into: dir, model: model) }
        }
        .task {
            // The service's state every 4 s; HomeKit's (a small file) every 2 s, so "live in Home" is prompt.
            var tick = 0
            while !Task.isCancelled {
                if tick % 2 == 0 { model.refreshService() }
                model.refreshHomeKit()
                model.refreshPrivacy()
                // What the live views decode, for the media engine's budget, every 6 s.
                if tick % 3 == 0 { await model.reportLiveViews() }
                // The doctor's findings for the tiles' marks, every 30 s (every 5 s while it's open).
                if tick % 15 == 0 { await model.doctor.refresh(config: model.config) }
                tick += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("Not saved", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(model.loadError == nil ? "No settings yet" : "The settings cannot be read", systemImage: "gearshape")
        } description: {
            if let error = model.loadError {
                Text(error)
            } else {
                Text("Pond keeps its settings in \(model.store.path). Create them with the defaults, then choose where recordings go and add your cameras.")
            }
        } actions: {
            if model.loadError == nil {
                Button("Create Settings") { model.createSettings() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Try Again") { model.reload() }
            }
        }
    }
}

/// Restart Recorder, while the recorder runs with settings other than the saved ones; gone when they match
/// again. Where the change is made (a section's header, the cameras' bar), so Settings doesn't grow a bar.
struct RestartRecorderButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.needsRestart {
                // Filled orange, as what wants doing is elsewhere in the app: easy to see beside a header.
                Button { model.restartService() } label: {
                    Label(model.isChangingService ? "Restarting\u{2026}" : "Restart Recorder", systemImage: "arrow.clockwise")
                }
                .disabled(model.isChangingService)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                .help("The recorder is still using the settings it started with. Restarting it pauses recording for a few seconds.")
                .transition(.scale(scale: 0.85, anchor: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.needsRestart)
    }
}

extension View {
    /// The Restart Recorder button at the trailing end of a section header, laid over it so the header keeps
    /// its height whether the button is there or not.
    func restartRecorderButton() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { RestartRecorderButton() }
    }
}


/// Lines from a camera check, with icons.
struct CheckLinesView: View {
    let lines: [CheckLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Label {
                    Text(line.text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    switch line.kind {
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

/// Quitting closes any sheet first. AppKit refuses to quit while a window has one attached (a camera's
/// settings left open in Settings kept the app from quitting): its Quit menu item is disabled and a quit
/// request from the Dock or a script is turned down before the app is asked. So both come here. An unsaved
/// sheet is dropped, as Cancel would.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Closing the main window closes the rest (Settings, and any sheet on it) as well: the app is that
    /// window, and what was opened from it goes with it.
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // Opened at login, with the menu bar item: quietly, its window closed (the service watched from the menu bar).
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == kAEOpenApplication,
           event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem, MenuBarItem.isShown {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true { window.close() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let closing = object as? NSWindow, closing.identifier?.rawValue.hasPrefix("main") == true else { return }
                for window in NSApp.windows where window !== closing && window.isVisible && window.level == .normal {
                    while let sheet = window.attachedSheet { window.endSheet(sheet) }
                    window.close()
                }
            }
        }
    }

    /// With the menu bar item, closing the window leaves Pond running (watching the service); without, it quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MenuBarItem.isShown }

    func applicationWillTerminate(_ notification: Notification) {
        // A demo's own services go with it.
        DemoSession.stop()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(quitEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }

    @objc func quitEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        Self.quit()
    }

    /// The service watch's notification clicked: where it's fixed, open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let tab = (response.notification.request.content.userInfo["settings"] as? String).flatMap(SettingsTab.init(rawValue:))
        await MainActor.run {
            if let tab { AppModel.current?.settingsTab = tab }
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// Shown even while Pond is the app in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    static func quit() {
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }
}

/// Find Cameras in the toolbar: a look at the network for cameras that aren't set up, on a click (it also
/// looks on its own: as the app opens, and daily), its icon pulsing while it looks. When it has found some,
/// "Cameras Found" with a green viewfinder and count instead (something to do), each to add or ignore.
struct FindCamerasButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cameras = model.newCameras
        let found = !cameras.isEmpty
        let looking = model.findingCameras && !found
        Button {
            if !found, !model.findingCameras { Task { await model.findCameras() } }
            withAnimation(.snappy(duration: 0.3)) { model.showingFoundCameras.toggle() }
        } label: {
            // Not animated when cameras turn up: the toolbar's glass takes the new width at once (it doesn't
            // animate items), so the words simply appear.
            if found {
                HStack(spacing: 6) {
                    Image(systemName: "camera.viewfinder").foregroundStyle(.green)
                    Text(cameras.count == 1 ? "Camera Found" : "Cameras Found")
                    Text("\(cameras.count)")
                        .monospacedDigit()
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.18), in: Capsule())
                }
                .padding(.horizontal, 4)
            } else {
                Label("Find Cameras", systemImage: "camera.viewfinder")
                    .symbolEffect(.pulse, isActive: looking)
            }
        }
        .transaction(value: found) { $0.animation = nil }
        .reportingMiddleFromTrailing { if model.findCamerasButtonFromTrailing != $0 { model.findCamerasButtonFromTrailing = $0 } }
        .help(cameras.isEmpty ? "Look for cameras on your network that aren\u{2019}t set up in Pond"
                              : "Cameras on your network that aren\u{2019}t set up in Pond: add them, or ignore them")
        .disabled(model.config == nil)
    }
}

/// Find Cameras' card: the cameras found, each to add or ignore, and the ignored ones folded away, each to
/// show again.
struct FoundCamerasPanel: View {
    var model: AppModel
    var close: () -> Void
    @State private var showingIgnored = false

    var body: some View {
        let cameras = model.newCameras
        VStack(alignment: .leading, spacing: 12) {
            if cameras.isEmpty {
                if model.findingCameras {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking for cameras on your network\u{2026}")
                    }
                } else {
                    Text("No new cameras on your network").font(.headline)
                }
            } else {
                Text(cameras.count == 1 ? "A camera on your network" : "Cameras on your network").font(.headline)
            }
            ForEach(cameras) { camera in
                FoundCameraRow(camera: camera) {
                    Button("Ignore") { model.ignore(camera) }
                    Button("Add\u{2026}") {
                        close()
                        model.add(camera)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Text(cameras.isEmpty
                 ? "Pond also looks as it opens, and once a day. Cameras already set up aren\u{2019}t listed."
                 : "Found on your network and not set up in Pond. Ignored ones aren\u{2019}t mentioned again.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let ignored = model.ignoredFound
            if !ignored.isEmpty {
                Divider()
                // A plain fold (a disclosure group takes the keyboard's focus as the card opens).
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showingIgnored.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showingIgnored ? 90 : 0))
                        Text("Ignored (\(ignored.count))").font(.headline)
                        Spacer(minLength: 0)
                    }
                    // The whole row, and a little above and below, takes the click.
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                if showingIgnored {
                    ForEach(ignored) { camera in
                        FoundCameraRow(camera: camera, dimmed: true) {
                            Button("Show Again") { model.showAgain(camera) }
                        }
                    }
                }
            }
        }
        .padding(16)
        // Esc closes it.
        .background {
            Button("Close", action: close).keyboardShortcut(.cancelAction).hidden()
        }
    }
}
