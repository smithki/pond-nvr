// Pond.app: live view, the recordings timeline and (later) events in one window, and the settings in the
// Settings window (⌘,). Recording itself is done by the login service (`pond run`); closing the app does not
// stop it.
import Control
import SwiftUI

@main
struct NVRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage(Appearance.key) private var appearance = Appearance.dark

    var body: some Scene {
        Window("Pond", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(appearance.scheme)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
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
                    Toggle(isOn: $showRail.animation(.snappy(duration: 0.25))) {
                        Label(showRail ? "Hide Cameras" : "Show Cameras", systemImage: "sidebar.leading")
                    }
                    .help(showRail ? "Hide the list of cameras" : "Show the list of cameras")
                }
            }
            ToolbarItem(placement: .navigation) {
                RecorderStatusButton {
                    model.settingsTab = .recorder
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
            ToolbarItem(placement: .primaryAction) {
                Button {
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
        .task {
            if launchArgument("--settings") != nil { openSettings() }
            // --camera ID: that camera's settings, open (for trying them out, and pictures of them).
            if let id = launchArgument("--camera") {
                model.settingsTab = .cameras
                model.cameraToEdit = id
                openSettings()
            }
            if let dir = ProcessInfo.processInfo.environment["POND_SNAPSHOTS"] { await Snapshots.take(into: dir, model: model) }
        }
        .task {
            // The service's state every 4 s; HomeKit's (a small file) every 2 s, so "live in Home" is prompt.
            var tick = 0
            while !Task.isCancelled {
                if tick % 2 == 0 { model.refreshService() }
                model.refreshHomeKit()
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

/// Whether the background recorder runs; opens its settings. While it runs with settings other than the
/// saved ones, it says so in orange (Restart Recorder), and opens a popover to restart it instead: in the
/// toolbar, so nothing in the window moves.
struct RecorderStatusButton: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void
    @State private var askingRestart = false

    var body: some View {
        Button { model.needsRestart ? askingRestart.toggle() : action() } label: {
            HStack(spacing: 6) {
                switch model.serviceState {
                case .running where model.needsRestart:
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    Text("Restart Recorder")
                case .running:
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("Recording")
                case .stopped:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Recorder stopped")
                case .notInstalled:
                    Image(systemName: "record.circle").foregroundStyle(.secondary)
                    Text("Not recording")
                }
            }
            .padding(.horizontal, 4)
        }
        .help(model.needsRestart ? "The recorder is still using its old settings. Click to restart it." : "The background recorder. Click for its settings.")
        .popover(isPresented: $askingRestart, arrowEdge: .bottom) { restartPopover }
        .animation(.snappy(duration: 0.25), value: model.needsRestart)
    }

    var restartPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The recorder is still using its old settings").font(.headline)
            Text("Settings it works from changed since it started. Restarting it uses them, and pauses recording for a few seconds.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Settings\u{2026}") {
                    askingRestart = false
                    action()
                }
                Spacer()
                Button(model.isChangingService ? "Restarting\u{2026}" : "Restart Recorder") {
                    askingRestart = false
                    model.restartService()
                }
                .disabled(model.isChangingService)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the main window closes the rest (Settings, and any sheet on it) as well: the app is that
    /// window, and what was opened from it goes with it.
    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(quitEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }

    @objc func quitEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        Self.quit()
    }

    static func quit() {
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }
}
