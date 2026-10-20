// Captures Pond's main window as it really draws (Liquid Glass and all, unlike POND_SNAPSHOTS' pictures): opens a
// fresh copy of dist/Pond NVR.app in the background (not taking the focus), captures only its window, and quits it.
// Needs screen-recording permission for the terminal it runs in.
//
//   swift scripts/capture-window.swift OUT.png [--mode live|timeline|events] [--appearance dark|light|system]
//                                              [--inactive] [--wait SECONDS]
//
// --inactive takes the focus from it first (a small window of this script's own, briefly), for how it looks behind
// another app's window. For checks that can't be tests: the glass at the Events view's edges, the toolbar's look.
import AppKit

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    defer { arguments.removeSubrange(i ... i + 1) }
    return arguments[i + 1]
}
func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}
let mode = option("--mode") ?? "events"
let appearance = option("--appearance")
let wait = option("--wait").flatMap(Double.init) ?? 5
let inactive = flag("--inactive")
guard let out = arguments.first else {
    FileHandle.standardError.write(Data("usage: swift scripts/capture-window.swift OUT.png [--mode M] [--appearance A] [--inactive] [--wait S]\n".utf8))
    exit(2)
}

let app = URL(fileURLWithPath: "dist/Pond NVR.app")
guard FileManager.default.fileExists(atPath: app.path) else {
    FileHandle.standardError.write(Data("No dist/Pond NVR.app here: make app, and run this from the repo's top.\n".utf8))
    exit(1)
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = false
// (The app's settings read the launch's own arguments first: -appearance light is that one launch's, not saved.)
configuration.arguments = ["--mode", mode] + (appearance.map { ["-appearance", $0] } ?? [])

var launched: NSRunningApplication?
let opened = DispatchSemaphore(value: 0)
NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, error in
    if let error { FileHandle.standardError.write(Data("Couldn't open it: \(error.localizedDescription)\n".utf8)) }
    launched = running
    opened.signal()
}
opened.wait()
guard let pond = launched else { exit(1) }
defer { pond.terminate() }

/// Its main window (the biggest of its windows on screen), once there is one.
func window() -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list
        .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pond.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
        .max { (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) < (($1[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) }
        .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
}

var id: CGWindowID?
for _ in 0 ..< 30 where id == nil {
    Thread.sleep(forTimeInterval: 0.5)
    id = window()
}
guard let id else {
    FileHandle.standardError.write(Data("Its window didn't appear (is it on another Space?).\n".utf8))
    pond.terminate()
    exit(1)
}
// (Time to settle: events read, pictures in.)
Thread.sleep(forTimeInterval: wait)

if inactive {
    // A small window of this script's own takes the focus.
    NSApplication.shared.setActivationPolicy(.accessory)
    let focus = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 120, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
    focus.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
}

let capture = Process()
capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = ["-x", "-o", "-l", String(id), out]
try capture.run()
capture.waitUntilExit()
pond.terminate()
print(capture.terminationStatus == 0 ? "✓ \(out)" : "✗ screencapture failed (screen-recording permission?)")
exit(capture.terminationStatus)
