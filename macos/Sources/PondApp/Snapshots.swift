// For development and the docs: with POND_SNAPSHOTS=<folder> set, the app saves a picture of each view of
// the main window, of each page of the Settings window, and of a camera's settings panel, then quits. The app draws its own windows, so no
// screen-recording permission is needed (though translucent glass comes out flatter than on screen). With
// POND_SNAPSHOTS_ONLY=<names> as well (comma separated: "cameras-settings,events"), only the pictures whose names
// begin with one of them are taken, and the rest (their waits too) skipped: for checking one change quickly.
import AppKit
import QuartzCore
import PondCore
import SwiftUI

@MainActor
enum Snapshots {
    /// The pictures asked for (POND_SNAPSHOTS_ONLY), or nil for all.
    static let only: [String]? = ProcessInfo.processInfo.environment["POND_SNAPSHOTS_ONLY"]?
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    /// Whether any of these pictures (or reports) is to be taken.
    static func wants(_ names: String...) -> Bool {
        guard let only else { return true }
        return names.contains { name in only.contains { name.hasPrefix($0) } }
    }

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
        // The timed checks: not napped (macOS slows an app whose window is hidden, its timers and the main queue
        // late; a check run behind other windows then timed its own naps, stalls of up to half a second with
        // nothing going on).
        let timing = wants("panels", "transitions")
            ? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
                                                    reason: "Timing the Events view's transitions")
            : nil
        defer { if let timing { ProcessInfo.processInfo.endActivity(timing) } }
        // The panel alone, opened and closed over and over (near the top, then far down), for `sample` to see what
        // its moves cost: little else going on, most of the main thread's busy time is theirs. Writes panels.txt.
        if wants("panels") {
            model.mode = .events
            try? await Task.sleep(for: .seconds(5))
            // Timed apart: while things move (the half second after each open or close), and after (what's made
            // once it's still: a stall then holds nothing up that's seen moving).
            var moving: [Double] = [], after: [Double] = []
            func timed(_ action: EventsDrive.Action) async {
                FrameTiming.shared.begin()
                model.eventsDrive = EventsDrive(action: action)
                try? await Task.sleep(for: .seconds(0.5))
                moving += FrameTiming.shared.end()
                FrameTiming.shared.begin()
                try? await Task.sleep(for: .seconds(0.7))
                after += FrameTiming.shared.end()
            }
            for round in 0 ..< 20 {
                let n = round % 2 == 0 ? 12 + round : 3000 + round * 100
                if round == 1 || round % 2 == 0 {
                    model.eventsDrive = EventsDrive(action: .centre(n))
                    try? await Task.sleep(for: .seconds(1.5))
                }
                await timed(.open(n))
                await timed(.close)
            }
            func line(_ name: String, _ lates: [Double]) -> String {
                let ms = lates.map { $0 * 1000 }.sorted()
                return String(format: "%@: slowest %.0f ms, 95th %.0f ms, over 16 ms: %d, over 33 ms: %d (%d answers)\n", name,
                              ms.last ?? 0, ms.isEmpty ? 0 : ms[Int(Double(ms.count - 1) * 0.95)],
                              ms.count { $0 > 16 }, ms.count { $0 > 33 }, ms.count)
            }
            let report = line("panel open and close, moving", moving) + line("panel open and close, after", after)
            try? report.write(toFile: "\(dir)/panels.txt", atomically: true, encoding: .utf8)
        }
        // The Events view's transitions, timed (run on a large library: POND_DEMO_EVENTS): each kind's slowest frame,
        // and how many missed one (16 ms at 60 Hz) or two, written to transitions.txt.
        if wants("transitions") {
            model.mode = .events
            try? await Task.sleep(for: .seconds(5))
            var timings: [String: [Double]] = [:]
            func measure(_ name: String, _ action: EventsDrive.Action, settle: Double = 1.4) async {
                FrameTiming.shared.begin()
                model.eventsDrive = EventsDrive(action: action)
                try? await Task.sleep(for: .seconds(settle))
                timings[name, default: []] += FrameTiming.shared.end()
            }
            for round in 0 ..< 3 {
                let deep = 3000 + round * 4000
                await measure("far jump", .centre(deep))
                await measure("panel open", .open(deep))
                for _ in 0 ..< 4 { await measure("arrow step", .step(later: false), settle: 1.0) }
                await measure("panel close (far)", .close, settle: 2.2)
                await measure("far jump", .centre(10 + round))
                await measure("panel open", .open(12 + round))
                await measure("panel close (near)", .close)
            }
            var report = "Slowest frame, frames over 16 ms and over 33 ms (main thread answers every 4 ms)\n"
            for (name, lates) in timings.sorted(by: { $0.key < $1.key }) {
                let ms = lates.map { $0 * 1000 }.sorted()
                let p95 = ms.isEmpty ? 0 : ms[Int(Double(ms.count - 1) * 0.95)]
                report += String(format: "%@: slowest %.0f ms, 95th %.0f ms, over 16 ms: %d, over 33 ms: %d (%d answers)\n",
                                 name, ms.last ?? 0, p95, ms.count { $0 > 16 }, ms.count { $0 > 33 }, ms.count)
            }
            try? report.write(toFile: "\(dir)/transitions.txt", atomically: true, encoding: .utf8)
        }
        for mode in Mode.allCases where wants(mode.rawValue) {
            model.mode = mode
            try? await Task.sleep(for: .seconds(2.5))
            save(mainWindow(), to: "\(dir)/\(mode.rawValue).png")
        }
        model.mode = .live
        // The Settings window, each kind of page: this Pond's settings, the recorder, every camera, the first camera's
        // doctor and settings, and another Pond's camera.
        for (page, name) in [(SettingsPage.general, "general"), (.storage, "storage"), (.remote, "remote"), (.advanced, "advanced")]
        where wants("settings-\(name)") {
            model.showSettings(page)
            try? await Task.sleep(for: .seconds(1.5))
            save(settingsWindow(), to: "\(dir)/settings-\(name).png")
        }
        // HomeKit, made up (the demo serves nothing to it): one camera in the Home app and recording to Secure Video,
        // one being watched, a doorbell that won't ring, one waiting to be added; the rest not in it.
        if wants("settings-homekit"), let cameras = model.config?.cameras, cameras.count >= 4 {
            var status = HomeKitStatus()
            var recording = HomeKitStatus.Recording()
            recording.on = true
            recording.chosen = true
            recording.lastClip = .init(at: Date().addingTimeInterval(-25 * 60), seconds: 18, bytes: 4_200_000)
            var first = HomeKitStatus.Camera(running: true, paired: true)
            first.recording = recording
            status.cameras[cameras[0].id] = first
            status.cameras[cameras[1].id] = HomeKitStatus.Camera(running: true, paired: true, viewers: 1)
            status.cameras[cameras[2].id] = HomeKitStatus.Camera(running: true, paired: true, doorbell: .unknownModel)
            status.cameras[cameras[3].id] = HomeKitStatus.Camera(running: true, paired: false,
                                                                 setup: .init(code: "123-45-678", uri: "X-HM://0023ISYWY1234"))
            model.pretendHomeKit(Set(cameras.prefix(4).map(\.id)), status: status)
            model.showSettings(.homeKit)
            try? await Task.sleep(for: .seconds(1.5))
            save(settingsWindow(), to: "\(dir)/settings-homekit.png")
        }
        if wants("cameras.png", "sidebar") {
            model.showSettings(.cameras)
            try? await Task.sleep(for: .seconds(2))
            if wants("cameras.png") { save(settingsWindow(), to: "\(dir)/cameras.png") }
        }
        // The sidebar as AppKit has it (SidebarBounds): its bounds, kept after changing pages, and held to as its
        // divider is moved past each end; and, closed, opened again.
        if wants("sidebar"), let view = settingsWindow()?.contentView?.superview, let split = firstSplitView(in: view),
           let item = sidebarItem(in: view) {
            let frame = settingsWindow()?.frame ?? .zero
            var report = "window \(Int(frame.width)) x \(Int(frame.height))"
            if let window = settingsWindow() {
                report += ", least \(Int(window.minSize.width)) x \(Int(window.minSize.height)), most width \(Int(window.maxSize.width))"
            }
            report += "\n"
            report += "canCollapse \(item.canCollapse) min \(item.minimumThickness) max \(item.maximumThickness)\n"
            for (position, name) in [(100.0, "dragged to 100"), (500.0, "dragged to 500"), (SettingsWindow.sidebarWidth.ideal, "back")] {
                split.setPosition(position, ofDividerAt: 0)
                try? await Task.sleep(for: .seconds(0.8))
                report += "\(name): \(Int(item.viewController.view.frame.width)) pt\n"
            }
            item.animator().isCollapsed = true
            try? await Task.sleep(for: .seconds(1.5))
            report += "closed, 1.5 s later: collapsed \(item.isCollapsed)\n"
            // Both layers' first rows at the same place (the Cameras layer's back button stands in its heading's).
            model.showSettings(.general)
            try? await Task.sleep(for: .seconds(1.5))
            let settingsTop = SidebarProbe.top["settings"]
            model.showSettings(.cameras)
            try? await Task.sleep(for: .seconds(1.5))
            let camerasTop = SidebarProbe.top["cameras"]
            // In to a camera, then back (⌘[): the first layer, at the page of it last shown.
            if let window = settingsWindow(), let first = model.config?.cameras.first {
                model.showSettings(.camera(first.id))
                try? await Task.sleep(for: .seconds(1.5))
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, characters: "[",
                                                    charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
                report += "back with ⌘[: first layer \(!SidebarProbe.camerasShown), at \(model.settingsPage)\n"
            }
            report += "first row: settings layer \(settingsTop.map { String(format: "%.1f", $0) } ?? "?"), cameras layer \(camerasTop.map { String(format: "%.1f", $0) } ?? "?")\n"
            try? report.write(toFile: "\(dir)/sidebar.txt", atomically: true, encoding: .utf8)
        }
        if wants("cameras-recorder.png") {
            model.showSettings(.recorder)
            try? await Task.sleep(for: .seconds(1.5))
            save(settingsWindow(), to: "\(dir)/cameras-recorder.png")
        }
        // How long pages take to lay out and draw as the window and the sidebar are resized: 20 steps of each, every
        // step laid out and drawn at once (as a live resize does, frame by frame); each step's time listed.
        if wants("resize-timing", "cameras-recorder-least", "log-", "scrolling"),
           let window = settingsWindow(), let root = window.contentView?.superview, let split = firstSplitView(in: root) {
            func step(_ change: () -> Void) -> Double {
                let start = CACurrentMediaTime()
                change()
                window.layoutIfNeeded()
                window.displayIfNeeded()
                return (CACurrentMediaTime() - start) * 1000
            }
            func words(_ times: [Double]) -> String {
                let sorted = times.sorted()
                return String(format: "median %.1f ms, slowest %.1f ms, all %.0f ms  [", sorted[sorted.count / 2], sorted.last ?? 0, times.reduce(0, +))
                    + times.map { String(format: "%.0f", $0) }.joined(separator: " ") + "]"
            }
            var report = ""
            var pages: [(SettingsPage, String)] = [(.general, "general"), (.recorder, "recorder")]
            if let first = model.config?.cameras.first { pages.insert((.camera(first.id), "doctor"), at: 1) }
            for (page, name) in pages {
                model.cameraTab = .doctor
                model.showSettings(page)
                try? await Task.sleep(for: .seconds(1.5))
                let frame = window.frame
                // From its least width to its most (wider is past what it can be made).
                let widths = (0..<20).map { SettingsWindow.least.width + (SettingsWindow.mostWidth - SettingsWindow.least.width) * Double($0) / 19 }
                let windowTimes = widths.map { width in step { window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height), display: false) } }
                window.setFrame(frame, display: true)
                try? await Task.sleep(for: .seconds(0.5))
                let positions = (0..<20).map { SettingsWindow.sidebarWidth.least + Double($0) * 6 }
                let sidebarTimes = positions.map { position in step { split.setPosition(position, ofDividerAt: 0) } }
                split.setPosition(SettingsWindow.sidebarWidth.ideal, ofDividerAt: 0)
                try? await Task.sleep(for: .seconds(0.5))
                report += "\(name) window: \(words(windowTimes))\n\(name) sidebar: \(words(sidebarTimes))\n"
            }
            model.showSettings(.recorder)
            try? report.write(toFile: "\(dir)/resize-timing.txt", atomically: true, encoding: .utf8)
            // A log card on a page (LogPage), at the window's least size: on the recorder's page and a camera's, the scroll views on the page (none with a scroll bar but the page's) and how far the page
            // scrolls; then the whole log, in its sheet.
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - window.minSize.height, width: window.minSize.width,
                                   height: window.minSize.height), display: true)
            try? await Task.sleep(for: .seconds(1.5))
            save(window, to: "\(dir)/cameras-recorder-least.png")
            var scrolling = "window \(Int(window.frame.width)) x \(Int(window.frame.height))\n"
            var logPages: [(SettingsPage, FullLog, String)] = [(.recorder, .recorder, "recorder")]
            // The camera with the most to show in What happened (its problems, as the card opens).
            if let busiest = model.config?.cameras.max(by: {
                IncidentList(incidents: model.doctor.incidents(of: $0.id), everything: false).shown.count
                    < IncidentList(incidents: model.doctor.incidents(of: $1.id), everything: false).shown.count
            }) { logPages.append((.camera(busiest.id), .camera(busiest.id), "doctor")) }
            for (page, full, name) in logPages {
                model.cameraTab = .doctor
                model.showSettings(page)
                try? await Task.sleep(for: .seconds(1.5))
                save(window, to: "\(dir)/log-\(name).png")
                scrolling += "\(name):\n"
                func scrolls(in view: NSView, depth: Int) {
                    if let scroll = view as? NSScrollView {
                        let f = scroll.convert(scroll.bounds, to: nil)
                        scrolling += String(repeating: "  ", count: depth) + "· \(type(of: scroll)) at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width)) x \(Int(f.height)), scroll bar \(scroll.hasVerticalScroller)\n"
                    }
                    for sub in view.subviews { scrolls(in: sub, depth: depth + (view is NSScrollView ? 1 : 0)) }
                }
                if let root = window.contentView { scrolls(in: root, depth: 1) }
                // How far the page scrolls (at most a little: its card is the newest lines, not the whole log).
                if let page = window.contentView.flatMap({ first(NSScrollView.self, in: $0) }) {
                    let room = (page.documentView?.frame.height ?? 0) + page.contentView.contentInsets.bottom
                        - page.contentView.bounds.height + page.contentView.contentInsets.top
                    scrolling += "  the page scrolls \(max(0, Int(room))) pt\n"
                }
                model.fullLog = full
                try? await Task.sleep(for: .seconds(2))
                save(window.attachedSheet, to: "\(dir)/log-\(name)-all.png")
                model.fullLog = nil
                try? await Task.sleep(for: .seconds(1))
            }
            try? scrolling.write(toFile: "\(dir)/scrolling.txt", atomically: true, encoding: .utf8)
            model.showSettings(.recorder)
            window.setFrame(frame, display: true)
        }
        if let first = model.config?.cameras.first {
            if wants("cameras-doctor") {
                model.showCamera(first.id, tab: .doctor)
                try? await Task.sleep(for: .seconds(1.5))
                save(settingsWindow(), to: "\(dir)/cameras-doctor.png")
            }
            if wants("cameras-settings.png") {
                model.showCamera(first.id, tab: .settings)
                try? await Task.sleep(for: .seconds(1.5))
                save(settingsWindow(), to: "\(dir)/cameras-settings.png")
            }
        }
        // A private camera's page too (its toolbar's Private on).
        if wants("cameras-settings-private"), let shy = model.config?.cameras.first(where: { model.isPrivate($0.id) }) {
            model.showCamera(shy.id, tab: .settings)
            try? await Task.sleep(for: .seconds(1.5))
            save(settingsWindow(), to: "\(dir)/cameras-settings-private.png")
        }
        if wants("cameras-remote"), let remote = model.remotePonds.lazy.compactMap({ $0.cameras?.first }).first {
            model.showSettings(.camera(remote.id))
            try? await Task.sleep(for: .seconds(1.5))
            save(settingsWindow(), to: "\(dir)/cameras-remote.png")
        }
        // A camera's settings panel, over the main window.
        if wants("camera-panel"), let first = model.config?.cameras.first {
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

    static func first<View: NSView>(_ kind: View.Type, in view: NSView) -> View? {
        if let found = view as? View { return found }
        for sub in view.subviews { if let found = first(kind, in: sub) { return found } }
        return nil
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
