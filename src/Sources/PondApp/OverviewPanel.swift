// The overview, from the toolbar's state: whether all's well, and if not what, at each Pond, each with its fix
// (the doctor, restarting the recorder, its settings); the cameras kept private, each to make public again; the
// cameras that need attention, to show alone in the rail; and which Ponds the window shows. A card like Find
// Cameras', its arrow under the button.
import Devices
import PondCore
import SwiftUI

struct OverviewPanel: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    let openSettings: (SettingsTab) -> Void

    /// A section per Pond: this Mac's first.
    var sections: [(pond: String?, name: String)] {
        [(nil, model.thisPondName)] + model.otherPonds.map { ($0.id, $0.name) }
    }

    var headline: String {
        let count = model.attentionCount
        if count > 0 { return count == 1 ? "1 thing needs attention" : "\(count) things need attention" }
        return model.isRecording || model.config?.cameras.isEmpty == true ? "All\u{2019}s well" : model.recorderWords
    }

    var body: some View {
        let multi = !model.otherPonds.isEmpty
        VStack(alignment: .leading, spacing: 14) {
            // Which Ponds the window shows, first: what the button's words say. One click, across the card; a pop-up
            // only when there are too many to fit.
            if multi {
                let shown = Binding(get: { model.shownPonds }, set: { model.shownPonds = $0 })
                // Up to three other Ponds, segments across the card (a long name cut short, whole in its tooltip); more,
                // and they'd be too thin to read: a pop-up the card's width.
                if choices.count <= 4 {
                    CapsuleSegments(selection: shown, options: choices.map(\.value), fills: true) { value in
                        choices.first { $0.value == value }?.name ?? ""
                    }
                } else {
                    Picker("Show", selection: shown) { pondChoices }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 10) {
                PondMark().font(.title2)
                Text(headline).font(.headline)
                Spacer(minLength: 0)
            }
            ForEach(sections, id: \.name) { section in
                VStack(alignment: .leading, spacing: 8) {
                    if multi {
                        Text(section.name.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    let items = model.attention.filter { $0.pond == section.pond }
                    if !items.contains(where: { $0.level >= .warning }) {
                        AttentionRow(item: allWell(section.pond), act: act)
                    }
                    ForEach(items) { AttentionRow(item: $0, act: act) }
                }
            }
            // The cameras that need attention, alone in the rail.
            let cameras = model.attentionCameras
            if !cameras.isEmpty {
                Button {
                    model.mode = .live
                    model.railNeedsAttention = true
                    model.stagingNeedsAttention += 1
                    UserDefaults.standard.set(true, forKey: LiveView.railKey)
                    close()
                } label: {
                    Label(cameras.count == 1 ? "Show This Camera" : "Show These \(cameras.count) Cameras",
                          systemImage: "line.3.horizontal.decrease")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            Divider()
            HStack(spacing: 8) {
                Button("Recorder\u{2026}") { open(.recorder) }
                if multi { Button("Remote Access\u{2026}") { open(.remote) } }
                Spacer(minLength: 0)
                Button("Open the Doctor\u{2026}") { model.doctorCamera = nil; open(.doctor) }
            }
            .controlSize(.small)
        }
        .padding(18)
        .padding(.top, 6)
    }

    /// The choices of what to show: every Pond together, or one.
    var choices: [(name: String, value: ShownPonds)] {
        [("All Ponds", .all)] + sections.map { ($0.name, $0.pond.map(ShownPonds.pond) ?? .this) }
    }

    @ViewBuilder var pondChoices: some View {
        Text("All Ponds").tag(ShownPonds.all)
        ForEach(sections, id: \.name) { section in
            Text(section.name).tag(section.pond.map(ShownPonds.pond) ?? .this)
        }
    }

    /// A Pond with nothing wrong: what it's doing.
    func allWell(_ pond: String?) -> Attention {
        guard let pond, let device = model.otherPonds.first(where: { $0.id == pond }) else {
            let count = (model.config?.cameras ?? []).filter { !model.isPrivate($0.id) }.count
            let recording = model.isRecording || model.isRestartingRecorder
            return Attention(id: "well", level: .info, symbol: recording ? "checkmark.circle.fill" : "record.circle",
                             title: !recording ? model.recorderWords
                                 : count == 1 ? "Recording its camera" : "Recording all \(count) cameras",
                             short: "", detail: nil, fix: nil)
        }
        // (Not connected just now isn't all well, nor yet gone quiet: that's said once it has lasted.)
        return Attention(id: "well \(pond)", level: .info, pond: pond,
                         symbol: model.isConnected(device) ? "checkmark.circle.fill" : "circle.dashed",
                         title: model.connection(device), short: "", detail: nil, fix: nil)
    }

    func open(_ tab: SettingsTab) {
        close()
        openSettings(tab)
    }

    func act(_ fix: Attention.Fix) {
        switch fix {
        case let .doctor(camera):
            model.doctorCamera = camera
            open(.doctor)
        case .recorderSettings: open(.recorder)
        case .restartRecorder: _ = model.restartService()
        case .storageSettings: open(.storage)
        case .remoteSettings: open(.remote)
        case .privacy: break
        }
    }
}

/// One thing in the overview: its mark, what it is and more, and its fix.
struct AttentionRow: View {
    @Environment(AppModel.self) private var model
    let item: Attention
    let act: (Attention.Fix) -> Void

    var colour: Color {
        switch item.level {
        case .problem: .orange
        case .warning: .yellow
        case .info: item.symbol == "eye.slash" ? .indigo : item.symbol.hasPrefix("checkmark") ? .green : .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: item.symbol)
                .foregroundStyle(colour)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(item.level >= .warning ? .medium : .regular))
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            switch item.fix {
            case let .privacy(camera)?:
                Toggle("Private", isOn: Binding(get: { model.isPrivate(camera) },
                                                set: { on in Task { await model.setPrivacy(camera, on) } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Private: not recorded, shown live or in the Home app")
            case let fix?:
                Button(Self.words(fix)) { act(fix) }
                    .controlSize(.small)
                    .disabled(fix == .restartRecorder && model.isChangingService)
            case nil:
                EmptyView()
            }
        }
    }

    static func words(_ fix: Attention.Fix) -> String {
        switch fix {
        case .doctor: "Doctor"
        case .restartRecorder: "Restart"
        case .recorderSettings, .storageSettings, .remoteSettings: "Settings"
        case .privacy: ""
        }
    }
}

