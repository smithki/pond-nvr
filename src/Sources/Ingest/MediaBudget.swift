// One budget for the Mac's media engine: every job of Pond's that decodes or encodes video claims its share (pixels
// a second through the engine), so that when there's more than it can do, the least important gives way first and
// says so, rather than everything stuttering at once. In order, most important first:
//
//   HomeKit Secure Video recordings   never shed; a new one that doesn't fit is re-encoded from the sub-stream
//   live re-encoding                  the Home app's, another Pond's; a new one that doesn't fit is turned down (the
//                                     camera's own stream is passed through instead, which costs nothing)
//   live views in this Mac's app      counted (they decode in the app), never shed
//   detection                         shed to keyframes only (a picture every couple of seconds), restored after
//   closer looks                      shed by closing, opened again when there's room
//
// Continuous recording decodes nothing and isn't in it. The capacity is the chip's (its media engines), estimated by
// its name, or POND_MEDIA_CAPACITY (pixels a second) to try a small one.
import Foundation

public final class MediaBudget: @unchecked Sendable {
    public static let shared = MediaBudget(capacity: MediaBudget.forThisMac())

    /// What a job is, the most important last (so `<` is "gives way to").
    public enum Kind: Int, Comparable, CaseIterable, Sendable, Codable {
        case closerLook, detection, appLive, liveReencode, homeKitRecording

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        public var words: String {
            switch self {
            case .closerLook: "closer looks"
            case .detection: "detection"
            case .appLive: "live views in the app"
            case .liveReencode: "live re-encoding"
            case .homeKitRecording: "HomeKit recordings"
            }
        }
    }

    /// Pixels a second: a decode's, and an encode's (weighed more: encoding costs the engine more).
    public static func decode(width: Int, height: Int, fps: Double) -> Double { Double(width * height) * fps }
    public static func encode(width: Int, height: Int, fps: Double) -> Double { Double(width * height) * fps * 1.5 }

    /// A stream's decode, by its SPS's picture size (H.264's or H.265's; else `fallback`'s), at a camera's usual 15
    /// fps unless told.
    public static func decode(sps: [UInt8]?, fallback: (width: Int, height: Int), fps: Double = 15) -> Double {
        let size = sps.flatMap { s in H264SPS(nal: s).map { ($0.width, $0.height) } ?? H265SPS(nal: s).map { ($0.width, $0.height) } } ?? fallback
        return decode(width: size.0, height: size.1, fps: fps)
    }

    /// A job's share, held until released.
    public final class Grant: @unchecked Sendable {
        public let kind: Kind
        public let label: String
        /// Its cost now (less while shed), and in full.
        public fileprivate(set) var cost: Double
        public fileprivate(set) var full: Double
        /// Its cost when shed (detection's keyframes only); nil: shed by stopping (a closer look).
        let reduced: Double?
        /// Shed now, or (for a recording, a live re-encode) granted only in its lesser form.
        public fileprivate(set) var isShed = false
        let onShed: @Sendable (Bool) -> Void
        fileprivate weak var budget: MediaBudget?

        fileprivate init(kind: Kind, label: String, cost: Double, reduced: Double?, onShed: @escaping @Sendable (Bool) -> Void) {
            self.kind = kind
            self.label = label
            self.cost = cost
            full = cost
            self.reduced = reduced
            self.onShed = onShed
        }

        /// Its real cost, once known (the first picture's size): the budget made to fit again.
        public func update(cost: Double) { budget?.update(self, cost: cost) }

        /// Let go (the job's done): what was shed for it may come back. Every grant is released by its job.
        public func release() { budget?.release(self) }
    }

    public private(set) var capacity: Double
    /// Where it says what it sheds and gives back (the service's log, once it has one).
    nonisolated(unsafe) public var log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var grants: [ObjectIdentifier: Grant] = [:]

    public init(capacity: Double, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.capacity = capacity
        self.log = log
    }

    /// What happens to a claim.
    public enum Answer {
        /// Granted in full.
        case granted(Grant)
        /// Granted only in its lesser form (a recording from the sub-stream; detection on keyframes), its cost the
        /// one given for that.
        case reduced(Grant)
        /// Not granted (a closer look, a live re-encode): there's no room.
        case refused
    }

    /// A job's share: `cost` in full; `reduced`, what it costs in its lesser form (a recording from the sub-stream,
    /// detection on keyframes), if it has one. Room is made by shedding what's less important; told to `onShed`
    /// when it's shed itself later (true) and given back (false).
    public func claim(_ kind: Kind, cost: Double, label: String, reduced: Double? = nil,
                      onShed: @escaping @Sendable (Bool) -> Void = { _ in }) -> Answer {
        var told: [(Grant, Bool)] = []
        let answer: Answer = lock.withLock {
            let grant = Grant(kind: kind, label: label, cost: cost, reduced: kind == .detection ? reduced : nil, onShed: onShed)
            grant.budget = self
            if makeRoom(cost, for: kind, told: &told) {
                grants[ObjectIdentifier(grant)] = grant
                return .granted(grant)
            }
            // In its lesser form, if it has one.
            if let reduced, makeRoom(reduced, for: kind, told: &told) {
                grant.cost = reduced
                grant.isShed = true
                grants[ObjectIdentifier(grant)] = grant
                return .reduced(grant)
            }
            switch kind {
            case .homeKitRecording, .appLive:
                // Never turned down: over the budget, then, and said.
                grant.cost = reduced ?? cost
                grant.isShed = reduced != nil
                grants[ObjectIdentifier(grant)] = grant
                return reduced == nil ? .granted(grant) : .reduced(grant)
            case .detection:
                grant.cost = reduced ?? cost
                grant.isShed = reduced != nil
                grants[ObjectIdentifier(grant)] = grant
                return .reduced(grant)
            case .liveReencode, .closerLook:
                return .refused
            }
        }
        tell(told)
        switch answer {
        case .reduced: say("\(label): \(kind == .homeKitRecording ? "from the sub-stream" : "detection on keyframes only"), the media engine being full")
        case .refused where kind == .liveReencode: say("\(label): not re-encoded, the media engine being full: its own stream sent as it is")
        default: break
        }
        return answer
    }

    /// Room for `cost` more of `kind`'s, shedding what gives way to it (the least important first, the costliest of
    /// those first): whether there is now.
    private func makeRoom(_ cost: Double, for kind: Kind, told: inout [(Grant, Bool)]) -> Bool {
        var used = grants.values.reduce(0) { $0 + $1.cost }
        if used + cost <= capacity { return true }
        let sheddable = grants.values.filter { $0.kind < kind && ($0.kind == .closerLook || ($0.kind == .detection && !$0.isShed)) }
            .sorted { ($0.kind, -$0.cost) < ($1.kind, -$1.cost) }
        for grant in sheddable {
            if grant.kind == .closerLook {
                grants.removeValue(forKey: ObjectIdentifier(grant))
                used -= grant.cost
                grant.budget = nil
            } else if let reduced = grant.reduced {
                used -= grant.cost - reduced
                grant.cost = reduced
                grant.isShed = true
            }
            told.append((grant, true))
            if used + cost <= capacity { return true }
        }
        return false
    }

    func update(_ grant: Grant, cost: Double) {
        var told: [(Grant, Bool)] = []
        lock.withLock {
            guard grants[ObjectIdentifier(grant)] != nil else { return }
            let before = grant.cost
            grant.full = cost
            if !grant.isShed { grant.cost = cost }
            grants.removeValue(forKey: ObjectIdentifier(grant))
            // (Its own cost made room for, as a claim's is; or given back.)
            if grant.cost > before { _ = makeRoom(grant.cost, for: grant.kind, told: &told) }
            grants[ObjectIdentifier(grant)] = grant
            if grant.cost < before { restore(told: &told) }
        }
        tell(told)
    }

    func release(_ grant: Grant) {
        var told: [(Grant, Bool)] = []
        lock.withLock {
            guard grants.removeValue(forKey: ObjectIdentifier(grant)) != nil else { return }
            grant.budget = nil
            restore(told: &told)
        }
        tell(told)
    }

    /// What was shed (detection) given back, the most important first, while there's room.
    private func restore(told: inout [(Grant, Bool)]) {
        var used = grants.values.reduce(0) { $0 + $1.cost }
        for grant in grants.values.filter({ $0.isShed && $0.kind == .detection }).sorted(by: { $0.full < $1.full }) {
            let more = grant.full - grant.cost
            guard used + more <= capacity else { break }
            used += more
            grant.cost = grant.full
            grant.isShed = false
            told.append((grant, false))
        }
    }

    private func tell(_ told: [(Grant, Bool)]) {
        guard !told.isEmpty else { return }
        for (grant, shed) in told { grant.onShed(shed) }
        let shedding = told.filter(\.1).map(\.0), restoring = told.filter { !$0.1 }.map(\.0)
        if !shedding.isEmpty {
            say("media engine full (\(percent)%): " + describe(shedding, closer: "closed", detection: "on keyframes only"))
        }
        if !restoring.isEmpty { say("media engine has room again (\(percent)%): " + describe(restoring, closer: "", detection: "on every picture")) }
    }

    private func describe(_ grants: [Grant], closer: String, detection: String) -> String {
        let looks = grants.filter { $0.kind == .closerLook }.count, watching = grants.filter { $0.kind == .detection }.map(\.label)
        return [looks > 0 ? "\(looks) closer look\(looks == 1 ? "" : "s") \(closer)" : nil,
                watching.isEmpty ? nil : "detection \(detection) for \(watching.sorted().joined(separator: ", "))"]
            .compactMap { $0 }.joined(separator: "; ")
    }

    private func say(_ line: String) { log(line) }

    // MARK: What it's doing

    public struct Report: Codable, Equatable, Sendable {
        public var capacity: Double
        public var used: Double
        /// By kind (its words), and how many of each.
        public var kinds: [Part]
        /// What's shed now: detection's cameras, and how many closer looks there'd be (they've closed).
        public var shed: [String]

        public struct Part: Codable, Equatable, Sendable {
            public var kind: Kind
            public var cost: Double
            public var count: Int
        }

        public var percent: Int { capacity > 0 ? Int((used / capacity * 100).rounded()) : 0 }
    }

    public var report: Report {
        lock.withLock {
            let used = grants.values.reduce(0) { $0 + $1.cost }
            let kinds = Kind.allCases.reversed().compactMap { kind -> Report.Part? in
                let mine = grants.values.filter { $0.kind == kind }
                return mine.isEmpty ? nil : .init(kind: kind, cost: mine.reduce(0) { $0 + $1.cost }, count: mine.count)
            }
            let shed = grants.values.filter(\.isShed).map { "\($0.label) (\($0.kind == .homeKitRecording ? "sub-stream" : "keyframes"))" }.sorted()
            return Report(capacity: capacity, used: used, kinds: kinds, shed: shed)
        }
    }

    private var percent: Int {
        let used = grants.values.reduce(0) { $0 + $1.cost }
        return capacity > 0 ? Int((used / capacity * 100).rounded()) : 0
    }

    /// Pixels a second in words: "2.5 Gpx/s", "30 Mpx/s".
    public static func words(_ pixels: Double) -> String {
        pixels >= 1e9 ? String(format: "%.1f Gpx/s", pixels / 1e9) : String(format: "%.0f Mpx/s", pixels / 1e6)
    }

    // MARK: The chip

    /// The base chip's worth: about what the soak kept up with (16 4K cameras at 15 fps decoded for HomeKit, ~2
    /// Gpx/s), with a little over.
    public static let baseCapacity = 2.5e9

    /// By the chip's name (its media engines: two on a Pro, four on a Max, eight on an Ultra), or POND_MEDIA_CAPACITY.
    public static func forThisMac() -> Double {
        if let given = ProcessInfo.processInfo.environment["POND_MEDIA_CAPACITY"].flatMap(Double.init), given > 0 { return given }
        return capacity(for: chipName())
    }

    public static func capacity(for chip: String) -> Double {
        if chip.contains("Ultra") { return baseCapacity * 8 }
        if chip.contains("Max") { return baseCapacity * 4 }
        if chip.contains("Pro") { return baseCapacity * 2 }
        return baseCapacity
    }

    public static func chipName() -> String {
        #if canImport(Darwin)
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        return ""
        #endif
    }
}
