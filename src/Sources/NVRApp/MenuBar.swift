// Pond in the menu bar (optional, on by default: Settings › General): whether it's recording, or what's wrong (the
// service watched); each camera's privacy, on and off; and the way to Live, the doctor and Settings. While it's
// shown, closing the window leaves Pond running, so it keeps watching the service.
import AppKit
import ServiceManagement
import SwiftUI

enum MenuBarItem {
    static let key = "menuBarItem"

    static var isShown: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Pond started at login (quietly, in the menu bar while it's shown), so an unattended Mac that restarts is watched.
enum OpenAtLogin {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// On or off; why not, if it couldn't be.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The menu bar's symbol: recording, or something's wrong.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.watch.problem != nil {
            Image(systemName: "exclamationmark.triangle")
        } else if model.isRecording {
            Image(systemName: "record.circle")
        } else {
            Image(systemName: "circle.dashed")
        }
    }
}

struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let problem = model.watch.problem {
            Text(problem.title)
            Button("\(problem.settings == .doctor ? "Open the Doctor" : "Recorder Settings")\u{2026}") { show(problem.settings) }
        } else {
            Text(model.isRecording ? "Recording" : "Not recording")
        }
        let cameras = model.config?.cameras ?? []
        if !cameras.isEmpty {
            Section("Private") {
                ForEach(cameras) { camera in
                    Toggle(camera.name, isOn: Binding(get: { model.isPrivate(camera.id) },
                                                      set: { on in Task { await model.setPrivacy(camera.id, on) } }))
                        .disabled(model.isPrivateOnCameraOnly(camera.id))
                }
            }
        }
        Divider()
        Button("Open Live") { open(.live) }
        Button("Open Events") { open(.events) }
        Button("Camera Doctor\u{2026}") { show(.doctor) }
        Button("Settings\u{2026}") { show(model.settingsTab) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Pond") { AppDelegate.quit() }
            .keyboardShortcut("q")
    }

    func open(_ mode: Mode) {
        model.mode = mode
        openWindow(id: "main")
        NSApp.activate()
    }

    func show(_ tab: SettingsTab) {
        model.settingsTab = tab
        openSettings()
        NSApp.activate()
    }
}
