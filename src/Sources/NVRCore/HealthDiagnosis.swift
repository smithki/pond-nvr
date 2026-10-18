// The doctor's findings: rules turning a camera's incidents and samples into what's wrong, since when, the
// evidence, and what to try. Problems and warnings (each with a fix) are shown on the camera's tile; notices only
// in the doctor. A finding holds while its evidence does: a calm hour, and it's gone.
import Foundation

public struct HealthFinding: Identifiable, Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        /// Worth knowing; nothing to do.
        case notice
        /// Something to change, and how.
        case warning
        /// Something's wrong.
        case problem

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Kind: String, Sendable, CaseIterable {
        case unstableVideo, dropsOff, loginRefused, macNetwork, packetLoss, keyframesFarApart, clockOff, controlsFailing,
             longPrivate
    }

    public var kind: Kind
    public var severity: Severity
    public var headline: String
    /// What it's seen: "8 stalls in the last hour, the first at 14:02".
    public var evidence: String
    /// What to try (a warning always has one).
    public var fix: String?
    /// Since when it's been so, as far as the record shows.
    public var since: Date?

    public var id: String { kind.rawValue }
    /// Shown on the camera's tile and in the rail (not a notice).
    public var marksTile: Bool { severity >= .warning }
}

/// When a rule finds something (fixed defaults; an advanced setting in the doctor may change them).
public struct HealthThresholds: Codable, Equatable, Sendable {
    /// Stalls in an hour: unstable video.
    public var stallsPerHour = 3
    /// Times unreachable in an hour (this camera alone): dropping off the network.
    public var unreachablePerHour = 3
    /// Of its packets, lost in an hour.
    public var lossRate = 0.01
    /// Seconds between keyframes, on average.
    public var keyframeSeconds = 4.0
    /// Seconds its clock is off.
    public var clockSeconds = 30.0
    /// Of its controls, failing in an hour (out of at least `controlsAtLeast`).
    public var controlFailureRate = 0.2
    public var controlsAtLeast = 5
    /// Hours private before it's said.
    public var privateHours = 24.0

    public init() {}

    public static let standard = HealthThresholds()
}

public enum HealthDiagnosis {
    /// A camera's findings, worst first. `incidents` are every camera's (for this Mac's own trouble, when they
    /// all go at once); `samples` this camera's. `app` names where its settings are changed ("the Reolink app").
    public static func findings(camera: String, incidents all: [HealthIncident], samples: [HealthSample], now: Date = Date(),
                                thresholds t: HealthThresholds = .standard, app: String = "the camera\u{2019}s own app") -> [HealthFinding] {
        let hourAgo = now.addingTimeInterval(-3600)
        let mine = all.filter { $0.camera == camera }.sorted { $0.time < $1.time }
        let lastHour = mine.filter { $0.time >= hourAgo }
        var found: [HealthFinding] = []

        // Unstable video: it connects, then stops.
        let stalls = lastHour.filter { $0.kind == .stalled }
        if stalls.count >= t.stallsPerHour {
            found.append(HealthFinding(
                kind: .unstableVideo, severity: .problem, headline: "Video keeps stopping",
                evidence: "\(stalls.count) stalls in the last hour" + countToday(mine, .stalled, now: now),
                fix: "Its video starts and then stops: usually a weak Wi-Fi signal, or the camera working at its limit. Check its signal and power, or lower its main stream\u{2019}s bitrate in \(app).",
                since: streakStart(mine.filter { $0.kind == .stalled })))
        }

        // Unreachable: this camera alone (when every camera went at once, or as the service started, it was
        // this Mac's network).
        let macWide = macWideTimes(all)
        let unreachable = lastHour.filter { incident in
            incident.kind == .unreachable && !macWide.contains { abs($0.timeIntervalSince(incident.time)) < 60 }
        }
        if unreachable.count >= t.unreachablePerHour {
            found.append(HealthFinding(
                kind: .dropsOff, severity: .problem, headline: "Drops off the network",
                evidence: "Unreachable \(unreachable.count) times in the last hour, while the other cameras weren\u{2019}t",
                fix: "Check its power and its network connection (its Wi-Fi signal, or its cable), and that its address hasn\u{2019}t changed.",
                since: streakStart(unreachable)))
        }
        // While it lasts: once this camera has connected since, it's over (and was this Mac's, not the camera's).
        if let lastMacWide = macWide.filter({ $0 >= hourAgo }).max(),
           mine.contains(where: { $0.kind == .unreachable && abs($0.time.timeIntervalSince(lastMacWide)) < 60 }),
           !mine.contains(where: { $0.kind == .connected && $0.time > lastMacWide }) {
            found.append(HealthFinding(
                kind: .macNetwork, severity: .notice, headline: "This Mac lost the network",
                evidence: "Every camera was unreachable at once at \(clock(lastMacWide))",
                fix: nil, since: lastMacWide))
        }

        if let refused = lastHour.last(where: { $0.kind == .loginRefused }),
           !mine.contains(where: { $0.kind == .connected && $0.time > refused.time }) {
            found.append(HealthFinding(
                kind: .loginRefused, severity: .problem, headline: "Its login is refused",
                evidence: "Refused at \(clock(refused.time))",
                fix: "Check the username and password in its settings (or that its account still exists in \(app)).",
                since: refused.time))
        }

        // The stream itself, this past hour.
        let recent = samples.filter { $0.camera == camera && $0.start >= hourAgo.addingTimeInterval(-HealthSample.seconds) }
        var hour = HealthSample(camera: camera, start: hourAgo)
        for sample in recent { hour.add(sample) }
        if hour.received >= 1000, let loss = hour.lossRate, loss > t.lossRate {
            found.append(HealthFinding(
                kind: .packetLoss, severity: .warning, headline: "Video is losing packets",
                evidence: percent(loss) + " of its video lost in the last hour",
                fix: "A weak link: check its Wi-Fi signal or its cable, or lower its main stream\u{2019}s bitrate in \(app).",
                since: firstSample(recent) { ($0.lossRate ?? 0) > t.lossRate }))
        }
        if hour.flowing >= 600, let interval = hour.keyframeInterval, interval > t.keyframeSeconds {
            found.append(HealthFinding(
                kind: .keyframesFarApart, severity: .warning, headline: "Keyframes are far apart",
                evidence: String(format: "A keyframe every %.0f s", interval),
                fix: "Live views and recordings start at a keyframe. Set its keyframe interval (I-frame interval) in \(app) to twice its frame rate: a keyframe every 2 s.",
                since: nil))
        }
        if let offset = recent.last(where: { $0.clockOffset != nil })?.clockOffset,
           abs(offset) > t.clockSeconds, abs(offset) < 86400 * 2 {
            found.append(HealthFinding(
                kind: .clockOff, severity: .warning, headline: "Its clock is off",
                evidence: duration(abs(offset)) + (offset > 0 ? " ahead of this Mac" : " behind this Mac"),
                fix: "Recordings are stamped with its time. Turn on time sync (NTP) in \(app).",
                since: nil))
        }
        let controls = hour.controlsOK + hour.controlsFailed
        if controls >= t.controlsAtLeast, Double(hour.controlsFailed) / Double(controls) > t.controlFailureRate {
            found.append(HealthFinding(
                kind: .controlsFailing, severity: .warning, headline: "Its controls often fail",
                evidence: "\(hour.controlsFailed) of \(controls) failed in the last hour",
                fix: "It may be busy or allow only a few logins at once: close other apps logged into it, such as \(app).",
                since: nil))
        }

        // Private a long while (left on by mistake?): said, not a problem.
        if let madePrivate = mine.last(where: { $0.kind == .madePrivate }),
           !mine.contains(where: { $0.kind == .madePublic && $0.time > madePrivate.time }),
           now.timeIntervalSince(madePrivate.time) > t.privateHours * 3600 {
            found.append(HealthFinding(
                kind: .longPrivate, severity: .notice, headline: "Private for " + duration(now.timeIntervalSince(madePrivate.time)),
                evidence: "Made private \(madePrivate.time.formatted(date: .abbreviated, time: .shortened))",
                fix: nil, since: madePrivate.time))
        }
        return found.sorted { $0.severity > $1.severity }
    }

    /// When every camera (two or more) went unreachable together, or the service had just started: this Mac's
    /// side, not a camera's.
    static func macWideTimes(_ all: [HealthIncident]) -> [Date] {
        let starts = all.filter { $0.kind == .serviceStarted }.map(\.time)
        let unreachable = all.filter { $0.kind == .unreachable }
        let cameras = Set(all.map(\.camera)).subtracting([""])
        var times: [Date] = []
        for incident in unreachable {
            if starts.contains(where: { incident.time.timeIntervalSince($0) >= 0 && incident.time.timeIntervalSince($0) < 60 }) {
                times.append(incident.time)
                continue
            }
            let together = Set(unreachable.filter { abs($0.time.timeIntervalSince(incident.time)) < 30 }.map(\.camera))
            if cameras.count >= 2, together.count >= 2 { times.append(incident.time) }
        }
        return times
    }

    /// The first of a run of these (each within an hour of the next), up to the latest.
    static func streakStart(_ incidents: [HealthIncident]) -> Date? {
        let times = incidents.map(\.time).sorted()
        guard var start = times.last else { return nil }
        for time in times.reversed() {
            if start.timeIntervalSince(time) > 3600 { break }
            start = time
        }
        return start
    }

    static func firstSample(_ samples: [HealthSample], where bad: (HealthSample) -> Bool) -> Date? {
        samples.sorted { $0.start < $1.start }.first(where: bad)?.start
    }

    static func countToday(_ incidents: [HealthIncident], _ kind: HealthIncident.Kind, now: Date) -> String {
        let today = incidents.filter { $0.kind == kind && Calendar.current.isDate($0.time, inSameDayAs: now) }.count
        return today > 0 ? "; \(today) today" : ""
    }

    static func clock(_ time: Date) -> String { time.formatted(date: .omitted, time: .shortened) }

    static func percent(_ rate: Double) -> String { String(format: rate < 0.1 ? "%.1f%%" : "%.0f%%", rate * 100) }

    /// "40 s", "3 min", "5 h", "2 days".
    public static func duration(_ seconds: Double) -> String {
        switch seconds {
        case ..<90: String(format: "%.0f s", seconds)
        case ..<5400: String(format: "%.0f min", seconds / 60)
        case ..<172_800: String(format: "%.0f h", seconds / 3600)
        default: String(format: "%.0f days", seconds / 86400)
        }
    }
}
