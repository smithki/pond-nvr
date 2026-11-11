// The daily "all well": once a day, what was recorded since the last, in a sentence or a few lines, so that silence
// never has to mean "probably fine". From the cameras' gaps in recording and why (RecordingGaps): a gap every camera
// had at once (this Mac asleep, the drive full) said once for all of them, not camera by camera.
import Foundation

public struct DailySummary: Codable, Equatable, Sendable {
    public var allWell: Bool
    public var title: String
    public var body: String
    /// When it was made, and since when it tells.
    public var at: Date
    public var since: Date

    /// Lines past this many are counted ("and 2 more").
    public static let shownLines = 3

    /// Of `cameras` (id, name: those to be recorded), their `gaps` within `since`…`until`; `privateNow` cameras are
    /// said to be private rather than counted.
    public static func make(cameras: [(id: String, name: String)], gaps: [String: [RecordingGap]], privateNow: Set<String> = [],
                            since: Date, until: Date, calendar: Calendar = .current) -> DailySummary {
        let watched = cameras.filter { !privateNow.contains($0.id) }
        let names = Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0.name) })
        // Each camera's gaps in the period (clipped to it), and each kept with those like it: the same stretch (to a
        // couple of minutes) and the same reason.
        struct Group { var range: ClosedRange<Date>; var reason: RecordingGap.Reason; var cameras: [String] }
        var groups: [Group] = []
        for camera in watched {
            for gap in gaps[camera.id] ?? [] where gap.range.upperBound > since && gap.range.lowerBound < until {
                let range = max(gap.range.lowerBound, since) ... min(gap.range.upperBound, until)
                if let i = groups.firstIndex(where: {
                    $0.reason == gap.reason && abs($0.range.lowerBound.timeIntervalSince(range.lowerBound)) < 150
                        && abs($0.range.upperBound.timeIntervalSince(range.upperBound)) < 150
                }) {
                    groups[i].cameras.append(camera.id)
                } else {
                    groups.append(Group(range: range, reason: gap.reason, cameras: [camera.id]))
                }
            }
        }
        groups.sort { $0.range.lowerBound < $1.range.lowerBound }
        let privately = cameras.filter { privateNow.contains($0.id) }.map(\.name)
        let privateNote = privately.isEmpty ? "" : " (" + list(privately) + (privately.count == 1 ? " is" : " are") + " private)"
        guard !groups.isEmpty else {
            let count = watched.count == 1 ? "1 camera" : "\(watched.count) cameras"
            return DailySummary(allWell: true, title: "All well",
                                body: "Everything recorded since \(when(since, now: until, calendar: calendar)): \(count), no gaps." + privateNote,
                                at: until, since: since)
        }
        var lines = groups.prefix(shownLines).map { group -> String in
            let span = "\(time(group.range.lowerBound)) \u{2013} \(time(group.range.upperBound))"
            let why = group.reason.words.map { ": \($0)" } ?? ""
            if group.cameras.count == watched.count, watched.count > 1 { return "Nothing recorded \(span)\(why)." }
            let who = list(group.cameras.compactMap { names[$0] })
            return "\(who) not recorded \(span)\(why)."
        }
        if groups.count > shownLines { lines.append("And \(groups.count - shownLines) more: the doctor has them all.") }
        let total = groups.reduce(0) { $0 + $1.range.upperBound.timeIntervalSince($1.range.lowerBound) }
        return DailySummary(allWell: false,
                            title: groups.count == 1 ? "Not everything was recorded" : "Not everything was recorded (\(HealthDiagnosis.duration(total)) of gaps)",
                            body: lines.joined(separator: "\n"), at: until, since: since)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "8:00 AM yesterday", or "2:10 PM" today.
    static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        calendar.isDate(date, inSameDayAs: now) ? time(date) : "\(time(date)) yesterday"
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
