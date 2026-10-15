// For development and the docs: with POND_SNAPSHOTS=<folder> set, the app saves a picture of each view of
// the main window and of each Settings tab, then quits. The app draws its own windows, so no
// screen-recording permission is needed (though translucent glass comes out flatter than on screen).
import AppKit
import SwiftUI

@MainActor
enum Snapshots {
    static func take(into dir: String, model: AppModel) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))
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
