// How many video decoders Pond has open (detection's, the closer looks', HomeKit's): what the memory the Mac's
// video decoder holds for Pond should be in proportion to (see VideoMemoryGuard).
import Foundation

public enum DecoderCount {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    public static func opened() { lock.withLock { count += 1 } }
    public static func closed() { lock.withLock { count = max(0, count - 1) } }
    public static var open: Int { lock.withLock { count } }
}
