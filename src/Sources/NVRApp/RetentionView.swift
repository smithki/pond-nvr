// How long recordings are kept, and how much of the drive they may take, as one picture: days chosen from
// a menu (each showing the space it needs), and the drive as a bar of what is on it, with sliders for the
// most continuous recording may use and the space kept free, each with a field for an exact number. The
// numbers follow the cameras' real rates (see StorageOutlook), and say when the days kept do not fit.
import NVRCore
import SwiftUI

struct RetentionView: View {
    @Environment(AppModel.self) private var model
    /// The last measurement, shown at once (see AppModel.lastStorageOutlook).
    var outlook: StorageOutlook? { model.lastStorageOutlook }
    /// While a slider is dragged: its value, shown live and saved when it is let go.
    @State private var draftLimit: Double?
    @State private var draftReserve: Double?

    static let continuousPresets = [1, 3, 7, 14, 30, 60, 90, 180, 365]
    static let eventPresets = [7, 14, 30, 90, 180, 365, 730]

    var retention: Config.Retention { model.config?.retention ?? Config.Retention() }
    var limitGB: Double? { draftLimit.map { $0 >= limitRange.upperBound ? nil : $0 } ?? retention.continuous.maxSizeGB }
    var reserveGB: Double { draftReserve ?? retention.minFreeGB }

    /// The estimate for the settings as shown (with a slider being dragged).
    var estimate: StorageEstimate? {
        outlook?.estimate(eventDays: retention.events.days, maxContinuousGB: limitGB, minFreeGB: reserveGB)
    }

    var body: some View {
        Form {
            Section {
                DaysPicker(title: "Keep continuous recording", days: retention.continuous.days, presets: Self.continuousPresets,
                           range: 1 ... 3650, detail: continuousDetail) { days in
                    model.update { $0.retention.continuous.days = days }
                }
                DaysPicker(title: "Keep event clips and snapshots", days: retention.events.days, presets: Self.eventPresets,
                           range: 1 ... 3650, detail: eventsDetail) { days in
                    model.update { $0.retention.events.days = days }
                }
            } header: {
                Text("How long").restartRecorderButton()
            } footer: {
                Text("Older recording is deleted. Event clips are never deleted to make space: they stay for their days, whatever happens to continuous recording.")
                    .foregroundStyle(.secondary)
            }

            if let outlook, let drive = outlook.drive, let estimate {
                Section {
                    StorageBar(segments: segments(drive: drive, outlook: outlook, estimate: estimate))
                        .padding(.vertical, 4)
                    limitRow(drive: drive, estimate: estimate)
                    reserveRow(drive: drive)
                } header: {
                    Text("Space on \(drive.name)")
                } footer: {
                    Text("Recording stops growing at whichever comes first: the days kept, the most it may use, or the drive reaching the space kept free. Then the oldest continuous recording makes way for the newest.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Space") {
                    LabeledContent("Keep free", value: "\(Int(retention.minFreeGB)) GB")
                    Text("The drive\u{2019}s space shows here when the recordings folder is ready (Storage).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model.config) { await model.refreshStorageOutlook() }
    }

    // MARK: - Days

    var continuousDetail: String? {
        guard let e = estimate else { return nil }
        let keep = retention.continuous.days
        let need = e.continuousPerDay * Double(keep)
        if e.continuousDays >= Double(keep) {
            return "About \(StorageEstimate.size(need)), at \(StorageEstimate.size(e.continuousPerDay)) a day."
        }
        return "Room for about \(StorageEstimate.duration(days: e.continuousDays)) of these: the oldest goes sooner."
    }

    var eventsDetail: String? {
        guard let e = estimate else { return nil }
        return "About \(StorageEstimate.size(e.eventsReserved)) (estimated until detection runs)."
    }

    // MARK: - Space

    /// The limit slider runs from 10 GB to all the drive pond could use; its top end is "no limit".
    var limitRange: ClosedRange<Double> {
        guard let drive = outlook?.drive else { return 10 ... 1000 }
        let usable = (Double(drive.free) + (outlook?.used ?? 0)) / 1e9
        return 10 ... max(20, usable.rounded(.up))
    }

    var reserveRange: ClosedRange<Double> {
        guard let drive = outlook?.drive else { return 0 ... 200 }
        return 0 ... max(50, min(500, (Double(drive.total) / 1e9 * 0.2).rounded()))
    }

    @ViewBuilder
    func limitRow(drive: DriveFacts, estimate: StorageEstimate) -> some View {
        let value = limitGB
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Continuous recording may use", systemImage: "square.fill").labelStyle(Swatch(color: .accentColor))
                Spacer()
                if value != nil {
                    GBField(value: value ?? limitRange.upperBound, range: limitRange) { gb in
                        model.update { $0.retention.continuous.maxSizeGB = gb >= limitRange.upperBound ? nil : gb }
                    }
                }
                Text(value == nil ? "No limit" : "GB")
                    .foregroundStyle(value == nil ? .primary : .secondary)
            }
            Slider(value: Binding(get: { draftLimit ?? value ?? limitRange.upperBound }, set: { draftLimit = $0.rounded() }),
                   in: limitRange) { editing in
                if !editing, let draft = draftLimit {
                    model.update { $0.retention.continuous.maxSizeGB = draft >= limitRange.upperBound ? nil : draft }
                    draftLimit = nil
                }
            }
            Text(value == nil
                 ? "As much as the drive has, keeping the space below free: about \(StorageEstimate.duration(days: estimate.continuousDays))."
                 : "Up to \(StorageEstimate.size(value! * 1e9)): about \(StorageEstimate.duration(days: estimate.continuousDays)).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func reserveRow(drive: DriveFacts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Keep free", systemImage: "square.fill").labelStyle(Swatch(color: .yellow))
                Spacer()
                GBField(value: reserveGB, range: reserveRange) { gb in model.update { $0.retention.minFreeGB = gb } }
                Text("GB").foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { reserveGB }, set: { draftReserve = ($0 / 5).rounded() * 5 }), in: reserveRange) { editing in
                if !editing, let draft = draftReserve {
                    model.update { $0.retention.minFreeGB = draft }
                    draftReserve = nil
                }
            }
            Text("Room for the drive to breathe, and for anything else on it. When free space falls below this, the oldest continuous recording goes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    func segments(drive: DriveFacts, outlook: StorageOutlook, estimate: StorageEstimate) -> [StorageBar.Segment] {
        StorageBar.segments(drive: drive, used: outlook.used, estimate: estimate, keepDays: retention.continuous.days,
                            reserveGB: reserveGB)
    }
}

/// Days from a menu of common choices, or any number (Custom…), on one row: the menu, and in custom mode
/// the number with its arrows beside it.
struct DaysPicker: View {
    let title: String
    let days: Int
    let presets: [Int]
    let range: ClosedRange<Int>
    var detail: String?
    let set: (Int) -> Void
    @State private var custom = false

    var body: some View {
        let showingCustom = custom || !presets.contains(days)
        LabeledContent {
            HStack(spacing: 6) {
                if showingCustom {
                    TextField("Days", value: Binding(get: { days }, set: { if range.contains($0) { set($0) } }), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("", value: Binding(get: { days }, set: { set($0) }), in: range).labelsHidden()
                    Text(days == 1 ? "day" : "days").foregroundStyle(.secondary)
                }
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(Self.label(preset)) {
                            custom = false
                            set(preset)
                        }
                    }
                    Divider()
                    Button("Custom\u{2026}") { custom = true }
                } label: {
                    Text(showingCustom ? "Custom" : Self.label(days))
                }
                .fixedSize()
            }
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }

    static func label(_ days: Int) -> String {
        switch days {
        case 1: "1 day"
        case 7: "1 week"
        case 14: "2 weeks"
        case 365: "1 year"
        case 730: "2 years"
        default: "\(days) days"
        }
    }
}

/// An exact number of GB, typed or stepped.
struct GBField: View {
    let value: Double
    let range: ClosedRange<Double>
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextField("GB", value: Binding(get: { Int(value) }, set: { set(min(range.upperBound, max(range.lowerBound, Double($0)))) }),
                      format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Stepper("", value: Binding(get: { value }, set: { set($0) }), in: range, step: 5).labelsHidden()
        }
    }
}

/// The drive as a bar of what is on it, with a legend.
struct StorageBar: View {
    struct Segment: Identifiable {
        var name: String
        var bytes: Double
        var color: Color
        var id: String { name }
    }

    let segments: [Segment]

    /// The drive as it will be once recording has filled what it may: other files, event clips, continuous
    /// recording, the space kept free, and what is left. With `newCamera`, its share of continuous recording
    /// is a part of its own, named for it.
    static func segments(drive: DriveFacts, used: Double, estimate: StorageEstimate, keepDays: Int, reserveGB: Double,
                         newCamera: (name: String, rate: Double)? = nil) -> [Segment] {
        let total = Double(drive.total)
        let other = max(0, total - Double(drive.free) - used)
        let events = estimate.eventsReserved
        let continuous = min(estimate.continuousPerDay * Double(keepDays), estimate.continuousDays * estimate.continuousPerDay)
        let reserve = reserveGB * 1e9
        let left = max(0, total - other - events - continuous - reserve)
        let share = newCamera.map { continuous * $0.rate * 86400 / max(1, estimate.continuousPerDay) } ?? 0
        var out: [Segment] = [
            .init(name: "Other files", bytes: other, color: .gray),
            .init(name: "Event clips", bytes: events, color: .purple),
            .init(name: newCamera == nil ? "Continuous" : "Other cameras", bytes: continuous - share, color: .accentColor),
        ]
        if let newCamera { out.append(.init(name: newCamera.name, bytes: share, color: .teal)) }
        out += [
            .init(name: "Kept free", bytes: reserve, color: .yellow),
            .init(name: "Unused", bytes: left, color: .secondary.opacity(0.25)),
        ]
        return out
    }

    var body: some View {
        let total = max(1, segments.reduce(0) { $0 + $1.bytes })
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments.filter { $0.bytes > 0 }) { s in
                        Rectangle().fill(s.color).frame(width: max(2, geo.size.width * s.bytes / total))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .animation(.snappy(duration: 0.25), value: segments.map(\.bytes))
            }
            .frame(height: 18)
            HStack(spacing: 14) {
                ForEach(segments.filter { $0.bytes > 0 }) { s in
                    HStack(spacing: 5) {
                        Circle().fill(s.color).frame(width: 8, height: 8)
                        Text("\(s.name) \(StorageEstimate.size(s.bytes))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A label whose icon is a small colour swatch, tying a control to its part of the bar.
struct Swatch: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            configuration.title
        }
    }
}
