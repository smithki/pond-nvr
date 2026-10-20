// When a question asks about, from its words: "last night", "yesterday afternoon", "this week", "on Monday", "Friday
// night", "in the last 3 hours", "two days ago"; or a time of day on any day ("at night", "in the mornings"). Worked
// out here, not by a language model (which gets dates wrong): the words are found, the times reckoned from now.
import Foundation

/// A stretch of time, and/or a part of every day.
public struct TimeFilter: Equatable, Sendable {
    public var range: ClosedRange<Date>?
    /// Hours of the day (from, to: 22, 6 runs over midnight), on any day of `range` (or any day at all).
    public var hours: Hours?

    public struct Hours: Equatable, Sendable {
        public var from: Int
        public var to: Int

        public func contains(_ hour: Int) -> Bool { from <= to ? (hour >= from && hour < to) : (hour >= from || hour < to) }
    }

    public init(range: ClosedRange<Date>? = nil, hours: Hours? = nil) {
        self.range = range
        self.hours = hours
    }

    public var isEmpty: Bool { range == nil && hours == nil }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        if let range, !range.contains(date) { return false }
        if let hours, !hours.contains(calendar.component(.hour, from: date)) { return false }
        return true
    }
}

public enum TimeWords {
    /// Parts of the day.
    static let parts: [String: (Int, Int)] = ["morning": (5, 12), "afternoon": (12, 17), "evening": (17, 22), "night": (20, 6)]
    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let numbers = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                          "nine": 9, "ten": 10, "few": 3, "couple": 2]

    /// The time `text` speaks of (nil if it names none), and the words that said it (to be taken out of the rest).
    public static func find(in text: String, now: Date = Date(), calendar: Calendar = .current) -> (filter: TimeFilter, words: [String])? {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var used: [String] = []
        let today = calendar.startOfDay(for: now)
        func day(_ back: Int) -> Date { calendar.date(byAdding: .day, value: -back, to: today)! }
        // (Up to now, at most; a stretch not begun yet, empty at its start.)
        func within(_ from: Date, _ to: Date) -> ClosedRange<Date> { from ... max(from, min(to, now)) }
        func part(_ name: String, of day: Date) -> ClosedRange<Date> { Self.part(name, of: day, calendar: calendar, now: now) }
        func has(_ phrase: String...) -> Bool {
            for i in 0 ... max(0, words.count - phrase.count) where Array(words[i ..< min(words.count, i + phrase.count)]) == phrase {
                used += phrase
                return true
            }
            return false
        }
        func number(after word: String) -> (Int, String)? {
            guard let i = words.firstIndex(of: word), i + 2 < words.count else { return nil }
            let n = Int(words[i + 1]) ?? numbers[words[i + 1]]
            return n.map { ($0, words[i + 2]) }
        }

        // "last night": yesterday evening to this morning.
        if has("last", "night") { return (TimeFilter(range: part("night", of: day(1))), used) }
        if has("tonight") { return (TimeFilter(range: part("night", of: day(0))), used) }
        // "this morning", "yesterday afternoon".
        for name in ["morning", "afternoon", "evening", "night"] {
            if has("this", name) { return (TimeFilter(range: part(name, of: day(0))), used) }
            if has("yesterday", name) { return (TimeFilter(range: part(name, of: day(1))), used) }
        }
        // "monday", "on tuesday", "last friday", "friday night": the latest such day (today, if it's today).
        for (index, name) in weekdays.enumerated() where words.contains(name) {
            used.append(name)
            if words.contains("last") { used.append("last") }
            if words.contains("on") { used.append("on") }
            let back = (calendar.component(.weekday, from: now) - 1 - index + 7) % 7 + (words.contains("last") && words.firstIndex(of: "last")! + 1 == words.firstIndex(of: name)! ? 7 : 0)
            let date = day(back)
            for part in ["morning", "afternoon", "evening", "night"] where words.contains(part) {
                used.append(part)
                return (TimeFilter(range: Self.part(part, of: date, calendar: calendar, now: now)), used)
            }
            return (TimeFilter(range: within(date, calendar.date(byAdding: .day, value: 1, to: date)!)), used)
        }
        if has("today") { return (TimeFilter(range: within(today, now)), used) }
        if has("yesterday") { return (TimeFilter(range: within(day(1), today)), used) }
        // "in the last 3 hours", "past two days", "last week", "this week", "this month".
        for word in ["last", "past"] {
            if let (n, unit) = number(after: word), let seconds = Self.seconds(unit) {
                used += [word, words[words.firstIndex(of: word)! + 1], unit]
                return (TimeFilter(range: now.addingTimeInterval(-Double(n) * seconds) ... now), used)
            }
            if let i = words.firstIndex(of: word), i + 1 < words.count, let seconds = Self.seconds(words[i + 1]) {
                // "last hour", "past day"; "last week" is the week before this one.
                used += [word, words[i + 1]]
                if words[i + 1].hasPrefix("week"), word == "last", let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
                    return (TimeFilter(range: calendar.date(byAdding: .day, value: -7, to: start)! ... start), used)
                }
                return (TimeFilter(range: now.addingTimeInterval(-seconds) ... now), used)
            }
        }
        if has("this", "week"), let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
            return (TimeFilter(range: within(start, now)), used)
        }
        if has("this", "month"), let start = calendar.dateInterval(of: .month, for: now)?.start {
            return (TimeFilter(range: within(start, now)), used)
        }
        // "two days ago", "3 hours ago".
        if let ago = words.firstIndex(of: "ago"), ago >= 2, let seconds = Self.seconds(words[ago - 1]),
           let n = Int(words[ago - 2]) ?? numbers[words[ago - 2]] {
            used += [words[ago - 2], words[ago - 1], "ago"]
            if seconds >= 86400 {
                let date = day(n * Int(seconds / 86400))
                return (TimeFilter(range: within(date, calendar.date(byAdding: .day, value: 1, to: date)!)), used)
            }
            let at = now.addingTimeInterval(-Double(n) * seconds)
            return (TimeFilter(range: at.addingTimeInterval(-seconds / 2) ... min(now, at.addingTimeInterval(seconds / 2))), used)
        }
        // A part of every day: "at night", "in the morning", "evenings".
        for (name, (a, b)) in parts where words.contains(name) || words.contains(name + "s") {
            used.append(words.contains(name) ? name : name + "s")
            return (TimeFilter(hours: .init(from: a, to: b)), used)
        }
        return nil
    }

    static func part(_ name: String, of day: Date, calendar: Calendar, now: Date) -> ClosedRange<Date> {
        let (a, b) = parts[name]!
        let start = calendar.date(byAdding: .hour, value: a, to: day)!
        let end = calendar.date(byAdding: .hour, value: b <= a ? 24 + b : b, to: day)!
        return start ... max(start, min(end, now))
    }

    static func seconds(_ unit: String) -> Double? {
        switch unit {
        case "minute", "minutes", "min", "mins": 60
        case "hour", "hours", "hr", "hrs": 3600
        case "day", "days": 86400
        case "week", "weeks": 7 * 86400
        case "month", "months": 30 * 86400
        default: nil
        }
    }
}
