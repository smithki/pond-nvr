// The window number of a process's main window (the largest on screen of its own, at the normal level), for
// `screencapture -l`: scripts/motion-check.sh captures the demo's window by it.
//
//   swift scripts/window-id.swift PID
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: swift scripts/window-id.swift PID\n".utf8))
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
let largest = own.max { a, b in
    func area(_ w: [String: Any]) -> Double {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
    return area(a) < area(b)
}
guard let window = largest, let number = window[kCGWindowNumber as String] else { exit(1) }
print(number)
