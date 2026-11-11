import Foundation

/// A fresh temporary folder, removed when the test ends.
final class TempDir {
    let path: String

    init() throws {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("pond-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }
}
