// Settings › Doctor: how each camera is doing, from what the recorder sees of it. All cameras at a glance, or one:
// its findings (what's wrong, since when, the evidence, what to try; ignored per camera), its day in charts, and
// what happened to it, in the log's manner (a day's heading, times, marks; problems by default). Copy Report gives
// it all as text, without its address or password.
import AppKit
import Charts
import NVRCore
import SwiftUI

struct DoctorView: View {
    @Environment(AppModel.self) private var model
    @State private var everything = false

    var cameras: [Config.Camera] { model.config?.cameras ?? [] }
    var doctor: CameraDoctor { model.doctor }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Camera", selection: $model.doctorCamera) {
                    Text("All cameras").tag(String?.none)
                    Divider()
                    ForEach(cameras) { Text($0.name).tag(String?.some($0.id)) }
                }
            } footer: {
                Text("From what the recorder sees of each camera, kept for a week. Nothing more is asked of the cameras.")
                    .foregroundStyle(.secondary)
            }
            if !doctor.hasRecords {
                Section {
                    Text("Nothing recorded yet. The recorder keeps what it sees of each camera while it runs.").foregroundStyle(.secondary)
                }
            } else if let id = model.doctorCamera, let camera = cameras.first(where: { $0.id == id }) {
                cameraSections(camera)
            } else {
                overview
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await doctor.refresh(config: model.config)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: All cameras

    var overview: some View {
        Section("Cameras") {
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
            }
        }
    }

    // MARK: One camera

    @ViewBuilder
    func cameraSections(_ camera: Config.Camera) -> some View {
        let found = doctor.findings[camera.id] ?? []
        Section("Findings") {
            if found.isEmpty {
                Label("No problems in the last hour", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(found) { finding in FindingRow(camera: camera, finding: finding) }
        }
        Section("Last 24 hours") {
            DayCharts(samples: doctor.samples(of: camera.id), incidents: doctor.incidents(of: camera.id))
                .frame(height: 110)
        }
        Section {
            IncidentList(incidents: doctor.incidents(of: camera.id), everything: everything)
                .frame(height: 120)
                .listRowInsets(EdgeInsets())
        } header: {
            HStack {
                Text("What happened")
                Spacer()
                // As the log: what went wrong by default, everything on asking.
                Picker("Show", selection: $everything) {
                    Text("Problems").tag(false)
                    Text("Everything").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        } footer: {
            HStack {
                Spacer()
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(doctor.report(camera), forType: .string)
                }
                .help("Copy what the doctor sees of \(camera.name) as text, for a bug report (without its address or password)")
            }
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

/// One finding: what, the evidence and since when, what to try; ignored or not.
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
        .opacity(ignored ? 0.55 : 1)
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

/// What happened, newest last, under each day's heading; problems only unless `everything`.
struct IncidentList: View {
    let incidents: [HealthIncident]
    let everything: Bool

    static let problems: Set<HealthIncident.Kind> = [.stalled, .unreachable, .loginRefused, .failed, .controlFailed, .privacyMode]

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
                    .padding(10)
                }
                // At the newest, as the log opens.
                .onAppear { scroller.scrollTo(rows.count - 1, anchor: .bottom) }
                .onChange(of: rows.count) { scroller.scrollTo(rows.count - 1, anchor: .bottom) }
            }
        }
    }

    func row(_ incident: HealthIncident) -> some View {
        let (mark, color): (String, Color) = switch incident.kind {
        case .stalled, .unreachable, .loginRefused, .failed: ("✗", .red)
        case .controlFailed, .privacyMode: ("!", .orange)
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
