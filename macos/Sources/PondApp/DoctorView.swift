// The doctor's page (in its window, SettingsWindow): how each camera is doing, from what the recorder sees of it. All
// cameras at a glance, or one:
// its findings (what's wrong, since when, the evidence, what to try; ignored per camera), its day in charts, and
// what happened to it, in the log's manner (a day's heading, times, marks; problems by default). Copy Report gives
// it all as text, without its address or password.
import AppKit
import Charts
import Control
import PondCore
import SwiftUI

struct DoctorView: View {
    @Environment(AppModel.self) private var model
    /// Ignored findings shown: they're folded away under the others until asked for.
    @State private var showIgnored = false
    /// The check's sheet, over the page: a check running (Run Check…), or the last one's details (Details…).
    @State private var checkSheet: CheckRequest?

    struct CheckRequest: Identifiable {
        let camera: Config.Camera
        /// The last check's result, shown rather than a new check run.
        var shown: (lines: [CheckLine], passed: Bool)?
        var id: String { camera.id }
    }

    var cameras: [Config.Camera] { model.config?.cameras ?? [] }
    var doctor: CameraDoctor { model.doctor }

    // (Refreshed by its window, every 5 s.)
    var body: some View {
        if doctor.hasRecords, let id = model.doctorCamera, let camera = cameras.first(where: { $0.id == id }) {
            // How it is, then what happened (a card of one height on every page; the page scrolls).
            LogPage {
                cameraSections(camera)
            } card: {
                whatHappened(camera)
            }
            .sheet(item: $checkSheet) { request in
                CheckSheet(camera: request.camera, initial: request.shown,
                           runCheck: { await doctor.check(request.camera, model: model) }) { field in
                    // The fix, on its settings: the sheet closes, and the Settings tab opens at the field.
                    checkSheet = nil
                    model.showCameraSettings(request.camera.id, focus: field)
                }
            }
        } else {
            Form {
                if !doctor.hasRecords {
                    Section {
                        Text("Nothing recorded yet. The recorder keeps what it sees of each camera while it runs.").foregroundStyle(.secondary)
                    } header: {
                        header(nil)
                    }
                } else {
                    overview
                }
            }
            .pageForm()
        }
    }


    /// The page's first row, its title: which camera (or all) as a heading like the page's others, in line with
    /// them, opening a menu of the cameras (a chevron after it says so); then what can be done with it.
    func header(_ camera: Config.Camera?) -> some View {
        HStack(spacing: 10) {
            // What the section is (the camera's name is the window's title; it's chosen in the window's list).
            Text(camera == nil ? "Every camera" : "Now")
            Spacer()
            // Its buttons as any others (not in the heading's type).
            Group {
                if let camera {
                    // Only when asked: the doctor otherwise asks nothing of the camera. In a sheet of its own, as it
                    // runs and then with what it found, and the fix.
                    Button("Run Check\u{2026}") { checkSheet = CheckRequest(camera: camera) }
                        .help("Log in to \(camera.name), watch its video for a few seconds and read its controls, now")
                    Button("Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(doctor.report(camera), forType: .string)
                    }
                    .help("Copy what the doctor sees of \(camera.name) as text, for a bug report (without its address or password)")
                } else {
                    // Held but unseen: the row is as tall with or without its buttons, so the heading lands in the same
                    // place on every page (switching between them, it stays put).
                    Button("Copy Report") {}.hidden().accessibilityHidden(true)
                }
            }
            .font(.body)
        }
        .controlSize(.small)
        .textCase(nil)
    }

    /// For a camera recording to HomeKit Secure Video, a row among its findings: when Pond last sent the home hub
    /// a clip, with what to do if they're sent but never show in the Home app behind its ⓘ (Pond can't see
    /// whether the hub keeps them). Seen with a doorbell whose clips the hub took, analysed (its notifications
    /// came) and threw away, until it was removed from HomeKit and added again: its recording setup had gone wrong.
    @ViewBuilder
    func homeKitRecordingRow(_ camera: Config.Camera) -> some View {
        if let recording = model.homeKitRecording(for: camera) {
            HStack(spacing: 8) {
                Label("HomeKit Secure Video", systemImage: "video.badge.checkmark")
                Spacer()
                if let clip = recording.lastClip {
                    Text("last clip sent " + clip.at.formatted(date: Calendar.current.isDateInToday(clip.at) ? .omitted : .abbreviated,
                                                                 time: .shortened) + " (\(Int(clip.seconds.rounded())) s)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("no clip sent yet").foregroundStyle(.secondary)
                }
                HomeKitClipsTip(camera: camera)
            }
        }
    }

    // MARK: All cameras

    var overview: some View {
        Group {
            Section {
                ForEach(cameras) { camera in
                    Button { model.doctorCamera = camera.id } label: {
                        HStack(spacing: 10) {
                            StatusDot(finding: doctor.worst(camera.id), isPrivate: model.isPrivate(camera.id))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(camera.name)
                                Text(doctor.worst(camera.id)?.headline ?? (model.isPrivate(camera.id) ? "Private" : "No problems"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    // (The first camera's row would wear the focus ring as the page opens.)
                    .focusEffectDisabled()
                }
            } header: {
                header(nil)
            } footer: {
                Text("From what the recorder sees of each camera, kept for a week. Nothing more is asked of the cameras unless you run a check.")
                    .foregroundStyle(.secondary)
            }
            ThresholdsSection()
        }
    }

    // MARK: One camera

    @ViewBuilder
    func cameraSections(_ camera: Config.Camera) -> some View {
        let found = doctor.findings[camera.id] ?? []
        // Those ignored, folded away under the rest (still seen there, and given back with Unignore).
        let ignored = found.filter { doctor.isIgnored(camera.id, $0) }
        let shown = found.filter { !doctor.isIgnored(camera.id, $0) }
        Section {
            if shown.isEmpty {
                Label("No problems in the last hour", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(shown) { finding in FindingRow(camera: camera, finding: finding) }
            if !ignored.isEmpty {
                FoldRow(title: "Ignored", summary: "\(ignored.count)", expanded: $showIgnored)
                if showIgnored {
                    ForEach(ignored) { finding in
                        FindingRow(camera: camera, finding: finding).padding(.leading, FoldRow.indent)
                    }
                }
            }
            homeKitRecordingRow(camera)
            if let check = doctor.checks[camera.id] {
                // The last check in a line, under the findings it may explain (one row, so the page doesn't move and
                // what happened keeps its room); its details in the check's sheet.
                LastCheckRow(check: check) {
                    checkSheet = CheckRequest(camera: camera, shown: (check.lines, !check.lines.contains { $0.kind == .error }))
                }
            }
        } header: {
            header(camera)
        }
        Section("Last 24 hours") {
            IncidentStrip(incidents: doctor.incidents(of: camera.id), samples: doctor.samples(of: camera.id))
            DayCharts(samples: doctor.samples(of: camera.id), incidents: doctor.incidents(of: camera.id))
                .frame(height: 90)
        }
    }

    /// What went wrong with the camera lately, in a card at the page's foot (its newest problems; Show All… has the
    /// rest, and everything else that happened, in a sheet: FullLogSheet).
    func whatHappened(_ camera: Config.Camera) -> some View {
        PageCard {
            CardHeading(title: "What happened") {
                Button("Show All\u{2026}") { model.fullLog = .camera(camera.id) }
                    .help("Everything that happened to \(camera.name) this week")
            }
        } content: {
            IncidentList(incidents: doctor.incidents(of: camera.id), everything: false, peek: true)
                // A list of its own for each camera: each opens at its newest (the same scroll view, given other
                // lines, kept where it was).
                .id(camera.id)
        }
    }
}

/// A camera's state as a dot: red for a problem, orange a warning, grey a notice or privacy, green all well.
struct StatusDot: View {
    let finding: HealthFinding?
    var isPrivate = false

    var color: Color {
        switch finding?.severity {
        case .problem?: .red
        case .warning?: .orange
        case .notice?: .gray
        case nil: isPrivate ? .indigo : .green
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
}

/// One finding: what, the evidence and since when, what to try; and Ignore (or, under Ignored, Unignore).
struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    let finding: HealthFinding

    var body: some View {
        let ignored = model.doctor.isIgnored(camera.id, finding)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(finding.severity))
                .foregroundStyle(Self.color(finding.severity))
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.headline).font(.headline)
                Text(finding.evidence + (finding.since.map { ", since " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                    .foregroundStyle(.secondary)
                if let fix = finding.fix { Text(fix).font(.callout) }
            }
            Spacer(minLength: 8)
            if finding.severity >= .warning {
                Button(ignored ? "Unignore" : "Ignore") { model.doctor.setIgnored(camera.id, finding, !ignored) }
                    .controlSize(.small)
                    .help(ignored ? "Show it on the camera\u{2019}s tile again" : "Keep it here, but off the camera\u{2019}s tile")
            }
        }
        .padding(.vertical, 2)
    }

    static func symbol(_ severity: HealthFinding.Severity) -> String {
        switch severity {
        case .problem: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .notice: "info.circle.fill"
        }
    }

    static func color(_ severity: HealthFinding.Severity) -> Color {
        switch severity {
        case .problem: .red
        case .warning: .orange
        case .notice: .secondary
        }
    }
}

/// The day: its frame rate every five minutes, and what went wrong each hour.
struct DayCharts: View {
    let samples: [HealthSample]
    let incidents: [HealthIncident]

    /// Both over the same day, marked every six hours.
    static var day: ClosedRange<Date> { Date().addingTimeInterval(-86400) ... Date() }
    static var hours: some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour())
        }
    }

    struct Hour: Identifiable {
        let start: Date
        let count: Int
        var id: Date { start }
    }

    var troubles: [Hour] {
        let since = Date().addingTimeInterval(-86400)
        let bad = incidents.filter { $0.time >= since && [.stalled, .unreachable, .loginRefused, .failed].contains($0.kind) }
        let hours = Dictionary(grouping: bad) { Calendar.current.dateInterval(of: .hour, for: $0.time)?.start ?? $0.time }
        return hours.map { Hour(start: $0.key, count: $0.value.count) }
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Frames a second").font(.caption).foregroundStyle(.secondary)
                Chart(samples, id: \.start) { sample in
                    if let fps = sample.fps {
                        LineMark(x: .value("Time", sample.start), y: .value("fps", fps)).interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXScale(domain: Self.day)
                .chartXAxis { Self.hours }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Interruptions an hour").font(.caption).foregroundStyle(.secondary)
                Chart(troubles) { hour in
                    BarMark(x: .value("Hour", hour.start, unit: .hour), y: .value("Interruptions", hour.count))
                        .foregroundStyle(.orange)
                }
                .chartXScale(domain: Self.day)
                .chartXAxis { Self.hours }
            }
        }
    }
}

/// The day at a glance, drawn as the Timeline draws a day: when the camera was down (red), private (indigo), and
/// marks where its video stalled or Pond restarted it (orange), over the same 24 hours as the charts below.
struct IncidentStrip: View {
    let incidents: [HealthIncident]
    /// Its five minutes at a time: green only where video was seen (not while this Mac was off).
    let samples: [HealthSample]

    /// unknown: before anything was recorded of it (drawn as the bare track).
    enum State: Equatable { case unknown, up, down, hidden }

    struct Span: Identifiable {
        let start: Date, end: Date, state: State
        var id: Date { start }
    }

    /// What a kind says of the camera from then on (nil: it doesn't change it).
    static func state(after kind: HealthIncident.Kind) -> State? {
        switch kind {
        case .connected, .madePublic: .up
        case .unreachable, .loginRefused, .failed, .wakeFailed: .down
        case .privacyMode, .madePrivate: .hidden
        case .stalled, .controlFailed, .serviceStarted, .restarted: nil
        }
    }

    static func spans(_ incidents: [HealthIncident], in day: ClosedRange<Date>) -> [Span] {
        let sorted = incidents.sorted { $0.time < $1.time }
        var state = sorted.last { $0.time < day.lowerBound }.flatMap { Self.state(after: $0.kind) } ?? .unknown
        var since = day.lowerBound
        var spans: [Span] = []
        for incident in sorted where day.contains(incident.time) {
            guard let next = Self.state(after: incident.kind), next != state else { continue }
            if state != .unknown { spans.append(Span(start: since, end: incident.time, state: state)) }
            state = next
            since = incident.time
        }
        if state != .unknown { spans.append(Span(start: since, end: day.upperBound, state: state)) }
        return spans
    }

    static let marked: Set<HealthIncident.Kind> = [.stalled, .restarted]

    var body: some View {
        let day = DayCharts.day
        let spans = Self.spans(incidents, in: day)
        let marks = incidents.filter { day.contains($0.time) && Self.marked.contains($0.kind) }.map(\.time)
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let length = day.upperBound.timeIntervalSince(day.lowerBound)
                func x(_ time: Date) -> CGFloat { size.width * time.timeIntervalSince(day.lowerBound) / length }
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                context.fill(track, with: .color(.secondary.opacity(0.2)))
                context.clip(to: track)
                for sample in samples where sample.frames > 0 && day.contains(sample.start) {
                    let rect = CGRect(x: x(sample.start), y: 0, width: x(sample.start.addingTimeInterval(HealthSample.seconds)) - x(sample.start) + 0.5,
                                      height: size.height)
                    context.fill(Path(rect), with: .color(Self.color(.up)))
                }
                for span in spans where span.state != .up {
                    let rect = CGRect(x: x(span.start), y: 0, width: max(2, x(span.end) - x(span.start)), height: size.height)
                    context.fill(Path(rect), with: .color(Self.color(span.state)))
                }
                for time in marks {
                    context.fill(Path(CGRect(x: x(time) - 1, y: 0, width: 2, height: size.height)), with: .color(.orange))
                }
            }
            .frame(height: 10)
            .accessibilityLabel(Self.summary(spans, marks: marks.count))
            HStack(spacing: 12) {
                Self.key(.green.opacity(0.35), "Connected")
                Self.key(.red, "Down")
                Self.key(.indigo, "Private")
                Self.key(.orange, "Stalled or restarted")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    static func color(_ state: State) -> Color {
        switch state {
        case .up: .green.opacity(0.35)
        case .down: .red
        case .hidden: .indigo
        case .unknown: .clear
        }
    }

    static func key(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
    }

    static func summary(_ spans: [Span], marks: Int) -> String {
        let down = spans.filter { $0.state == .down }.count, hidden = spans.filter { $0.state == .hidden }.count
        if down == 0 && hidden == 0 && marks == 0 { return "Connected all day" }
        return "Down \(down) times, private \(hidden) times, \(marks) stalls or restarts"
    }
}

/// What happened, newest last, under each day's heading; problems only unless `everything`.
struct IncidentList: View {
    let incidents: [HealthIncident]
    let everything: Bool
    /// The newest only, on a page (DoctorView.whatHappened): not scrolling, no scroll bar.
    var peek = false
    /// More than it shows (on a page): its top fades (PeekFade).
    @State private var overflows = false

    static let problems: Set<HealthIncident.Kind> = [.stalled, .unreachable, .loginRefused, .failed, .controlFailed, .privacyMode, .wakeFailed,
                                                     .restarted]

    var shown: [HealthIncident] { everything ? incidents : incidents.filter { Self.problems.contains($0.kind) } }

    var body: some View {
        let rows = shown
        if rows.isEmpty {
            Text(everything ? "Nothing yet." : "Nothing went wrong this week.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, incident in
                            if index == 0 || !Calendar.current.isDate(rows[index - 1].time, inSameDayAs: incident.time) {
                                Text(Self.day(incident.time))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, index == 0 ? 0 : 8)
                            }
                            row(incident).id(index)
                        }
                    }
                    .padding(.vertical, 10)
                }
                // A few lines start at the card's top, the newest last (not at its foot under an empty space). More
                // than it holds: opened at the newest, and kept there as lines come (scrolled up for earlier ones).
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                // The scroll bar clear of the card's rounded corners and its edge.
                .contentMargins(.vertical, 10, for: .scrollIndicators)
                .contentMargins(.trailing, 4, for: .scrollIndicators)
                .scrollDisabled(peek)
                .scrollIndicators(peek ? .never : .automatic)
                .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > $0.containerSize.height + 1 } action: { _, more in
                    overflows = more
                }
                .modifier(PeekFade(on: peek && overflows))
                // A few lines don't scroll (or bounce) at all.
                .scrollBounceBehavior(.basedOnSize)
                .onAppear { scroller.scrollTo(rows.count - 1, anchor: .bottom) }
                .onChange(of: rows.count) { scroller.scrollTo(rows.count - 1, anchor: .bottom) }
            }
        }
    }

    func row(_ incident: HealthIncident) -> some View {
        let (mark, color): (String, Color) = switch incident.kind {
        case .stalled, .unreachable, .loginRefused, .failed, .wakeFailed: ("✗", .red)
        case .controlFailed, .privacyMode, .restarted: ("!", .orange)
        case .connected: ("✓", .green)
        default: ("", .clear)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(incident.time.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
            Text(mark).foregroundStyle(color).frame(width: 10)
            Text(CameraDoctor.words(incident.kind) + (incident.detail.map { ": \($0)" } ?? ""))
                .foregroundStyle(Self.problems.contains(incident.kind) ? .primary : .secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
    }

    static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .complete, time: .omitted)
    }
}

/// When the doctor speaks up, as an advanced setting: each rule's figure, changed here for every camera (until
/// then, the defaults). Folded away; the figures a finding shows say what it saw against them.
struct ThresholdsSection: View {
    @Environment(AppModel.self) private var model
    /// Open or not: closed each time the page is shown (an advanced setting, looked at now and then).
    @State private var shown = false

    var body: some View {
        @Bindable var doctor = model.doctor
        Section {
            // The settings' own fold: the whole row opens it.
            FoldRow(title: "Thresholds", summary: doctor.thresholds == .standard ? "Defaults" : "Changed",
                    expanded: $shown)
            if shown {
                Group {
                    let t = doctor.thresholds
                    ThresholdPicker(title: "Video keeps stopping", detail: "Its video stops while connected, this often.",
                                    value: Double(t.stallsPerHour), presets: [2, 3, 5, 10], range: 1 ... 60, step: 1,
                                    unit: "times an hour", label: Self.timesAnHour) { doctor.thresholds.stallsPerHour = Int($0) }
                    ThresholdPicker(title: "Drops off the network", detail: "Unreachable this often while the other cameras aren\u{2019}t.",
                                    value: Double(t.unreachablePerHour), presets: [2, 3, 5, 10], range: 1 ... 60, step: 1,
                                    unit: "times an hour", label: Self.timesAnHour) { doctor.thresholds.unreachablePerHour = Int($0) }
                    ThresholdPicker(title: "Video is losing packets", detail: "More than this much of its video lost in an hour.",
                                    value: t.lossRate * 100, presets: [0.5, 1, 2, 5], range: 0.1 ... 50, step: 0.1,
                                    unit: "%", label: { Self.number($0) + "%" }) { doctor.thresholds.lossRate = $0 / 100 }
                    ThresholdPicker(title: "Keyframes are far apart", detail: "Further apart than this on average: slow to start live, in the Home app too.",
                                    value: t.keyframeSeconds, presets: [2, 4, 6, 10], range: 1 ... 60, step: 0.5,
                                    unit: "s", label: Self.duration) { doctor.thresholds.keyframeSeconds = $0 }
                    ThresholdPicker(title: "Its clock is off", detail: "Further than this from the Mac\u{2019}s clock.",
                                    value: t.clockSeconds, presets: [10, 30, 60, 300], range: 1 ... 3600, step: 1,
                                    unit: "s", label: Self.duration) { doctor.thresholds.clockSeconds = $0 }
                    ThresholdPicker(title: "Its controls often fail", detail: "More than this share of at least \(t.controlsAtLeast) asked of it in an hour.",
                                    value: t.controlFailureRate * 100, presets: [10, 20, 50], range: 1 ... 100, step: 1,
                                    unit: "%", label: { Self.number($0) + "%" }) { doctor.thresholds.controlFailureRate = $0 / 100 }
                    ThresholdPicker(title: "Private for long", detail: "Said (as a notice) once it has been private this long.",
                                    value: t.privateHours, presets: [12, 24, 72, 168], range: 1 ... 720, step: 1,
                                    unit: "h", label: Self.hours) { doctor.thresholds.privateHours = $0 }
                    HStack {
                        Spacer()
                        Button("Restore Defaults") { doctor.thresholds = .standard }
                            .disabled(doctor.thresholds == .standard)
                    }
                }
                .padding(.leading, FoldRow.indent)
            }
        } footer: {
            Text("When a finding is made, for every camera. The defaults suit most cameras; to keep one camera\u{2019}s finding off its tile, Ignore it instead.")
                .foregroundStyle(.secondary)
        }
    }

    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0 ... 1))) }

    static func timesAnHour(_ value: Double) -> String { Int(value) == 1 ? "once an hour" : "\(Int(value)) times an hour" }

    /// Seconds in words: "4 s", "1 minute", "5 minutes".
    static func duration(_ seconds: Double) -> String {
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            let minutes = Int(seconds / 60)
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return number(seconds) + " s"
    }

    /// Hours in words: "12 hours", "1 day", "3 days", "1 week".
    static func hours(_ hours: Double) -> String {
        if hours == 168 { return "1 week" }
        if hours >= 24, hours.truncatingRemainder(dividingBy: 24) == 0 {
            let days = Int(hours / 24)
            return days == 1 ? "1 day" : "\(days) days"
        }
        return Int(hours) == 1 ? "1 hour" : "\(number(hours)) hours"
    }
}

/// A threshold from a menu of sensible choices, or any figure (Custom…), on one row, as the retention settings'
/// days are: the menu, and in custom mode the figure with its arrows and unit beside it. `value` is in the units
/// shown (a percentage as 1 for 1%).
struct ThresholdPicker: View {
    let title: String
    let detail: String
    let value: Double
    let presets: [Double]
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let label: (Double) -> String
    let set: (Double) -> Void
    @State private var custom = false

    var body: some View {
        // (Within a hair: a percentage comes back from a fraction.)
        let showingCustom = custom || !presets.contains { abs($0 - value) < 0.0001 }
        LabeledContent {
            HStack(spacing: 6) {
                if showingCustom {
                    TextField(unit, value: Binding(get: { value }, set: { if range.contains($0) { set($0) } }),
                              format: .number.precision(.fractionLength(0 ... 1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("", value: Binding(get: { value }, set: { set(min(range.upperBound, max(range.lowerBound, $0))) }),
                            in: range, step: step)
                        .labelsHidden()
                    Text(unit).foregroundStyle(.secondary)
                }
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(label(preset)) {
                            custom = false
                            set(preset)
                        }
                    }
                    Divider()
                    Button("Custom\u{2026}") { custom = true }
                } label: {
                    Text(showingCustom ? "Custom" : label(value))
                }
                .fixedSize()
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

/// What to do when a camera's clips are sent to the home hub but never appear in the Home app: a fresh HomeKit
/// identity (see docs/doctor.md), from the camera's settings.
struct HomeKitClipsTip: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help("Clips sent but not in the Home app?")
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Clips sent but never in the Home app?").font(.headline)
                    Text("The home hub\u{2019}s recording setup for \(camera.name) may be stuck. Remove it from HomeKit in its settings, remove it in the Home app too, then add it again with its new setup code. Its Home app settings and automations are set up again.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Camera Settings\u{2026}") {
                            shown = false
                            model.showCameraSettings(camera.id)
                        }
                    }
                }
                .padding(16)
                .frame(width: 320)
            }
    }
}


/// A camera's last check in one row: how it went, in a word and its first line that matters, when, and its details.
struct LastCheckRow: View {
    let check: (lines: [CheckLine], time: Date)
    let details: () -> Void

    /// The line that says most: the first error, else the first warning, else the first line.
    var lead: CheckLine? {
        check.lines.first { $0.kind == .error } ?? check.lines.first { $0.kind == .warning } ?? check.lines.first
    }

    var body: some View {
        HStack(spacing: 8) {
            let kind = lead?.kind ?? .ok
            Image(systemName: kind == .error ? "xmark.octagon.fill" : kind == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(kind == .error ? .red : kind == .warning ? .orange : .green)
            Text("Last check at \(check.time.formatted(date: .omitted, time: .shortened)):")
                .foregroundStyle(.secondary)
            Text(kind == .ok ? "it answered and its video came" : lead?.text ?? "")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Details\u{2026}", action: details)
                .controlSize(.small)
        }
    }
}
