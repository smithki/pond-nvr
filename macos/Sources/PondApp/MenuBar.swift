// Pond in the menu bar (optional, on by default: Settings › General): whether it's recording, or what's wrong (the
// service watched); each camera's privacy, on and off; and the way to Live, the doctor and Settings. While it's
// shown, closing the window leaves Pond running, so it keeps watching the service.
import AppKit
import ServiceManagement
import SwiftUI

enum MenuBarItem {
    static let key = "menuBarItem"

    static var isShown: Bool { AppDefaults.store.object(forKey: key) as? Bool ?? true }
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

/// The menu bar's mark: Pond's logomark while it's recording (dimmed while it isn't), a warning while something's
/// wrong.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    /// The app icon's own mark (its SVG, in the bundle), cropped to what's drawn in it and made a template image
    /// (coloured as the menu bar's other icons), the menu bar's height; nil outside the app bundle. Worked out from the
    /// icon each launch, so a new icon brings a new mark.
    static let mark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Mark", withExtension: "svg"), let svg = NSImage(contentsOf: url),
              let cropped = cropped(svg) else { return nil }
        let height = 16.0
        let image = NSImage(cgImage: cropped, size: NSSize(width: height * Double(cropped.width) / Double(cropped.height), height: height))
        image.isTemplate = true
        return image
    }()

    /// The image drawn large (for a sharp mark at 2× and 3×), cropped to where anything's drawn.
    static func cropped(_ image: NSImage, side: Int = 512) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self), let whole = context.makeImage() else { return nil }
        var (left, right, top, bottom) = (side, -1, side, -1)
        for y in 0 ..< side {
            for x in 0 ..< side where data[(y * side + x) * 4 + 3] > 8 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left else { return nil }
        // (A pixel's margin, so antialiased edges aren't cut.)
        let box = CGRect(x: left - 1, y: top - 1, width: right - left + 3, height: bottom - top + 3)
            .intersection(CGRect(x: 0, y: 0, width: side, height: side))
        return whole.cropping(to: box)
    }

    var body: some View {
        if model.attention.contains(where: { $0.level == .problem }) {
            Image(systemName: "exclamationmark.triangle")
        } else if let mark = Self.mark {
            Image(nsImage: mark).opacity(model.isRecording ? 1 : 0.45)
        } else {
            Image(systemName: model.isRecording ? "record.circle" : "circle.dashed")
        }
    }
}

struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // (So the doctor's window can be opened from here with the main window closed.)
        let _ = AppModel.openWindow == nil ? (AppModel.openWindow = { openWindow(id: $0) }) : ()
        // What needs attention (the toolbar's overview's list), else the recorder's state.
        let items = model.attention.filter { $0.level >= .warning }
        if items.isEmpty {
            Text(model.recorderWords)
            // The latest daily summary, in a line: all well, or that something wasn't recorded (the doctor has it).
            if let summary = model.watch.lastSummary, Date().timeIntervalSince(summary.at) < 36 * 3600 {
                Text("\(summary.allWell ? "All well" : "Not everything recorded") at \(summary.at.formatted(date: .omitted, time: .shortened))")
            }
        } else {
            ForEach(items.prefix(5)) { Text($0.title) }
            if items.count > 5 { Text("and \(items.count - 5) more") }
            if items.contains(where: { $0.fix == .recorder }) { Button("Recorder\u{2026}") { model.showSettings(.recorder) } }
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
        let new = model.seenEvents.count
        Button(new == 0 ? "Open Events" : "Open Events (\(new) new)") { open(.events) }
        Button("Open Cameras\u{2026}") { model.showSettings(.cameras) }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        Button("Settings\u{2026}") { model.showSettings() }
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
}
