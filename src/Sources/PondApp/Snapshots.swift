// For development and the docs: with POND_SNAPSHOTS=<folder> set, the app saves a picture of each view of
// the main window, of each page of the Settings window, and of a camera's settings panel, then quits. The app draws its own windows, so no
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
        // The Settings window, each kind of page: this Pond's settings, the recorder, every camera, the first camera's
        // doctor and settings, and another Pond's camera.
        for (page, name) in [(SettingsPage.general, "general"), (.storage, "storage"), (.remote, "remote"), (.advanced, "advanced")] {
            model.showSettings(page)
            try? await Task.sleep(for: .seconds(1.5))
            save(settingsWindow(), to: "\(dir)/settings-\(name).png")
        }
        model.showSettings(.cameras)
        try? await Task.sleep(for: .seconds(2))
        save(settingsWindow(), to: "\(dir)/cameras.png")
        // The sidebar as AppKit has it (SidebarBounds): its bounds, kept after changing pages, and held to as its
        // divider is moved past each end; and, closed, opened again.
        if let view = settingsWindow()?.contentView?.superview, let split = firstSplitView(in: view),
           let item = sidebarItem(in: view) {
            let frame = settingsWindow()?.frame ?? .zero
            var report = "window \(Int(frame.width)) x \(Int(frame.height))\n"
            report += "canCollapse \(item.canCollapse) min \(item.minimumThickness) max \(item.maximumThickness)\n"
            for (position, name) in [(100.0, "dragged to 100"), (500.0, "dragged to 500"), (SettingsWindow.sidebarWidth.ideal, "back")] {
                split.setPosition(position, ofDividerAt: 0)
                try? await Task.sleep(for: .seconds(0.8))
                report += "\(name): \(Int(item.viewController.view.frame.width)) pt\n"
            }
            item.animator().isCollapsed = true
            try? await Task.sleep(for: .seconds(1.5))
            report += "closed, 1.5 s later: collapsed \(item.isCollapsed)\n"
            try? report.write(toFile: "\(dir)/sidebar.txt", atomically: true, encoding: .utf8)
        }
        model.showSettings(.recorder)
        try? await Task.sleep(for: .seconds(1.5))
        save(settingsWindow(), to: "\(dir)/cameras-recorder.png")
        if let first = model.config?.cameras.first {
            model.showCamera(first.id, tab: .doctor)
            try? await Task.sleep(for: .seconds(1.5))
            save(settingsWindow(), to: "\(dir)/cameras-doctor.png")
            model.showCamera(first.id, tab: .settings)
            try? await Task.sleep(for: .seconds(1.5))
            save(settingsWindow(), to: "\(dir)/cameras-settings.png")
        }
        if let remote = model.remotePonds.lazy.compactMap({ $0.cameras?.first }).first {
            model.showSettings(.camera(remote.id))
            try? await Task.sleep(for: .seconds(1.5))
            save(settingsWindow(), to: "\(dir)/cameras-remote.png")
        }
        // A camera's settings panel, over the main window.
        if let first = model.config?.cameras.first {
            mainWindow()?.makeKeyAndOrderFront(nil)
            model.editCameraSettings(first.id)
            try? await Task.sleep(for: .seconds(2))
            save(NSApp.windows.first { $0.isVisible && $0.sheetParent != nil }, to: "\(dir)/camera-panel.png")
            // Closed again: an open sheet keeps the app from quitting.
            model.cameraSettingsPanel = nil
            try? await Task.sleep(for: .seconds(1))
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

    static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews { if let split = firstSplitView(in: sub) { return split } }
        return nil
    }

    /// The first split view controller's first item under a view (the Settings window's sidebar).
    static func sidebarItem(in view: NSView) -> NSSplitViewItem? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
            return controller.splitViewItems.first
        }
        for sub in view.subviews { if let item = sidebarItem(in: sub) { return item } }
        return nil
    }

    /// The Settings window (not necessarily key: another app may be in front).
    static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.identifier?.rawValue.contains(SettingsWindow.id) == true }
    }

    static func save(_ window: NSWindow?, to path: String) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
