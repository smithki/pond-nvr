// How many closer looks may decode at once. Each open tap decodes every picture of a camera's main stream (each
// needs the ones before it) on the Mac's media engine, which also records to HomeKit and plays live views: with
// many cameras, or 4K ones, moving at once, they'd take it all. So only so many at a time, by the chip (its media
// engines: more on a Pro, Max or Ultra); a camera following someone (a person, a vehicle) before one where
// something only moves, which gives up its slot to it. Without a slot, a camera is still watched, on its sub-stream.
import Foundation

final class TapSlots: @unchecked Sendable {
    /// How much a tap's ask is worth: following someone, or only motion.
    enum Priority: Int, Comparable, Sendable {
        case motion = 0
        case following = 1
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    static let shared = TapSlots(limit: TapSlots.forThisMac())

    let limit: Int
    private let lock = NSLock()
    /// The taps holding a slot: how much they're worth, and how to tell one to give it up.
    private var holders: [ObjectIdentifier: (priority: Priority, yield: @Sendable () -> Void)] = [:]

    init(limit: Int) { self.limit = max(1, limit) }

    /// A slot for `tap`, at `priority`: true if it has one (kept, or given now, or taken from one worth less).
    func claim(_ tap: AnyObject, priority: Priority, yield: @escaping @Sendable () -> Void) -> Bool {
        let id = ObjectIdentifier(tap)
        let displaced: (@Sendable () -> Void)? = lock.withLock {
            if holders[id] != nil {
                holders[id]!.priority = priority
                return nil
            }
            if holders.count < limit {
                holders[id] = (priority, yield)
                return nil
            }
            guard let lowest = holders.min(by: { $0.value.priority < $1.value.priority }), lowest.value.priority < priority else {
                return { }   // (none to take from: refused, said by not being kept)
            }
            holders.removeValue(forKey: lowest.key)
            holders[id] = (priority, yield)
            return lowest.value.yield
        }
        displaced?()
        return lock.withLock { holders[id] != nil }
    }

    /// The slot let go (the tap closed).
    func release(_ tap: AnyObject) { _ = lock.withLock { holders.removeValue(forKey: ObjectIdentifier(tap)) } }

    var held: Int { lock.withLock { holders.count } }

    /// By the chip's name: its media engines, roughly (an estimate; one tap per engine's worth, room left over).
    static func forThisMac() -> Int {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        let chip = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return limit(for: chip)
    }

    static func limit(for chip: String) -> Int {
        if chip.contains("Ultra") { return 12 }
        if chip.contains("Max") { return 8 }
        if chip.contains("Pro") { return 6 }
        return 4
    }
}
