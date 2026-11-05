// For development and the docs: with POND_SNAPSHOTS=<folder> set, the app saves a picture of each view of
// the main window and of each Settings tab, then quits. The app draws its own windows, so no
// screen-recording permission is needed (though translucent glass comes out flatter than on screen).
import AppKit
import PondCore
import SwiftUI

@MainActor
enum Snapshots {
    static func take(into dir: String, model: AppModel) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))
        // With --zones ID: just that camera's zone editor, in a window of its own.
        if let at = CommandLine.arguments.firstIndex(of: "--zones"), at + 1 < CommandLine.arguments.count,
           let camera = model.config?.cameras.first(where: { $0.id == CommandLine.arguments[at + 1] }) {
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: ZoneEditorSheet(camera: camera, zones: .constant(camera.zones.isEmpty ? Self.sampleZones : camera.zones)).environment(model))
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(4))
            if let view = window.contentView { window.setContentSize(view.fittingSize) }
            try? await Task.sleep(for: .seconds(0.5))
            save(window, to: "\(dir)/zones.png")
            NSApp.terminate(nil)
            return
        }
        // With --add-camera: just Add Camera, once the cameras on the network are in.
        if model.addingCamera {
            try? await Task.sleep(for: .seconds(6))
            save(NSApp.windows.first { $0.isVisible && $0.sheetParent != nil }, to: "\(dir)/add-camera.png")
            NSApp.terminate(nil)
            return
        }
        for mode in Mode.allCases {
            model.mode = mode
            try? await Task.sleep(for: .seconds(2.5))
            save(mainWindow(), to: "\(dir)/\(mode.rawValue).png")
        }
        model.mode = .live
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        for tab in SettingsTab.allCases {
            model.settingsTab = tab
            try? await Task.sleep(for: .seconds(1.2))
            save(NSApp.keyWindow, to: "\(dir)/settings-\(tab.rawValue).png")
        }
        NSApp.terminate(nil)
    }

    /// For a camera without zones, to show what they look like.
    static let sampleZones = [
        Config.Zone(id: "path", name: "Path", points: [[0.25, 0.55], [0.6, 0.5], [0.75, 0.95], [0.2, 0.95]], categories: ["person", "package"]),
        Config.Zone(id: "street", name: "Street", points: [[0, 0.2], [1, 0.15], [1, 0.35], [0, 0.4]], kind: .ignore),
    ]

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.identifier?.rawValue.contains("main") == true }
            ?? NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.frame.width > 700 }
    }

    static func save(_ window: NSWindow?, to path: String) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
