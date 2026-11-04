// Which Ponds the window shows: all of them together (other Ponds' cameras live beside this Mac's, the rail in a
// section per Pond), or one. In the toolbar where the recorder's state is, and as it was while this Mac is the only
// Pond ("Recording"); with others, what's shown ("All Ponds", "Home", "Lake House"). Its menu chooses, and has the
// recorder's settings and remote access's.
import Devices
import NVRCore
import SwiftUI

struct PondSwitcher: View {
    @Environment(AppModel.self) private var model
    let openSettings: (SettingsTab) -> Void
    @State private var nudged = false

    /// What the mark says, first in its tooltip.
    var markMeaning: String {
        if case let .pond(id) = model.shownPonds, let pond = model.otherPonds.first(where: { $0.id == id }) {
            return model.isConnected(pond) ? "\(pond.name) is connected (\(model.connection(pond).lowercased()))."
                                           : "\(pond.name) isn\u{2019}t connected right now."
        }
        let name = model.thisPondName == "This Mac" ? "This Mac\u{2019}s" : "\(model.thisPondName)\u{2019}s"
        return switch model.serviceState {
        case _ where model.isRestartingRecorder: "\(name) recorder is restarting."
        case .running where model.needsRestart: "\(name) recorder is running with old settings: restart it to use the new ones."
        case .running: "Recording: \(name) recorder is running."
        case .stopped: "Not recording: \(name) recorder has stopped."
        case .notInstalled: "Not recording: \(name) recorder isn\u{2019}t installed."
        }
    }

    var body: some View {
        let switches = !model.otherPonds.isEmpty
        Menu {
            PondMenu(openSettings: openSettings)
        } label: {
            HStack(spacing: 6) {
                PondMark()
                    .symbolEffect(.bounce, value: model.shownPondsNudge)
                // With only this Mac, its recorder's state in words, as it always was; with others to choose from,
                // which Pond is shown (its state in the mark and the help).
                Text(switches ? model.shownName : model.recorderWords)
                    // Changed by something else (a camera of a Pond not shown chosen in Events): lit a moment. (The
                    // toolbar's glass can't be tinted or outlined, and what's drawn past the label is cut off: the
                    // label's own words are what can say so.)
                    .foregroundStyle(nudged ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            }
            .padding(.horizontal, 4)
            // Changed by something else (a camera of a Pond not shown chosen in Events): the button glows a moment, the
            // whole of it, then fades.
            .task(id: model.shownPondsNudge) {
                guard model.shownPondsNudge > 0 else { return }
                withAnimation(.easeIn(duration: 0.15)) { nudged = true }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 1)) { nudged = false }
            }
        }
        .menuIndicator(switches ? .visible : .hidden)
        .fixedSize()
        .help(markMeaning + (switches ? " Showing \(model.shownName). Click to show another Pond, or for the recorder\u{2019}s settings."
                                      : " Click for its settings."))
    }
}

/// The Ponds to show, and the recorder's settings: the toolbar's menu, and the camera rail's.
struct PondMenu: View {
    @Environment(AppModel.self) private var model
    let openSettings: (SettingsTab) -> Void

    var body: some View {
        if !model.otherPonds.isEmpty {
            Picker("Show", selection: Binding(get: { model.shownPonds }, set: { model.shownPonds = $0 })) {
                Label("All Ponds", systemImage: "square.grid.2x2").tag(ShownPonds.all)
                Label(model.thisPondName, systemImage: "desktopcomputer").tag(ShownPonds.this)
                ForEach(model.otherPonds, id: \.id) { pond in
                    Label {
                        Text(pond.name)
                        Text(model.connection(pond))
                    } icon: {
                        Image(systemName: "house")
                    }
                    .tag(ShownPonds.pond(pond.id))
                }
            }
            .pickerStyle(.inline)
        }
        Section(model.thisPondName) {
            Label(model.recorderWords, systemImage: "record.circle")
            if model.needsRestart, case .running = model.serviceState {
                Button("Restart Recorder", systemImage: "arrow.clockwise") { model.restartService() }
                    .disabled(model.isChangingService)
            }
            Button("Recorder Settings\u{2026}", systemImage: "gearshape") { openSettings(.recorder) }
        }
        Section {
            Button("Remote Access Settings\u{2026}", systemImage: "network") { openSettings(.remote) }
        }
    }
}

/// The shown Pond's state, as a mark: this Mac's recorder, or another's connection.
struct PondMark: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case let .pond(id) = model.shownPonds, let pond = model.otherPonds.first(where: { $0.id == id }) {
            Image(systemName: "house.fill").foregroundStyle(model.isConnected(pond) ? .green : .secondary)
        } else {
            switch model.serviceState {
            case _ where model.isRestartingRecorder:
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            case .running where model.needsRestart:
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            case .running:
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    // Recording now: a ring spreading from it now and then, faintly.
                    .background { RecordingRipple() }
            case .stopped:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .notInstalled:
                Image(systemName: "record.circle").foregroundStyle(.secondary)
            }
        }
    }
}

extension AppModel {
    /// This Pond's name, as the switcher shows it.
    var thisPondName: String { config?.name ?? DemoSession.scenario?.pondName ?? "This Mac" }

    var otherPonds: [ControlSocket.RemoteDevice] { remoteStatus?.devices ?? [] }

    /// What's shown, in words.
    var shownName: String {
        switch shownPonds {
        case .all: "All Ponds"
        case .this: thisPondName
        case let .pond(id): otherPonds.first { $0.id == id }?.name ?? "Another Pond"
        }
    }

    /// The cameras Live shows: this Mac's, and the other Ponds' (as cameras of their own: their streams through this
    /// Mac's service, their ids `camera@pond`), as chosen.
    var liveCameras: [Config.Camera] {
        cameraGroups.flatMap(\.cameras)
    }

    /// The same, a group per Pond (this Mac's first).
    var cameraGroups: [(pond: String?, name: String, cameras: [Config.Camera])] { cameraGroups(shownPonds) }

    /// Every Pond's cameras, a group each, shown or not.
    var allCameraGroups: [(pond: String?, name: String, cameras: [Config.Camera])] { cameraGroups(.all) }

    func cameraGroups(_ shown: ShownPonds) -> [(pond: String?, name: String, cameras: [Config.Camera])] {
        var groups: [(String?, String, [Config.Camera])] = []
        if shown.includes(nil) { groups.append((nil, thisPondName, config?.cameras ?? [])) }
        for pond in remotePonds where shown.includes(pond.id) {
            let order = remoteOrder[pond.id] ?? []
            let sorted = (pond.cameras ?? []).sorted { a, b in
                (order.firstIndex(of: a.id) ?? .max, (pond.cameras ?? []).firstIndex(of: a) ?? 0)
                    < (order.firstIndex(of: b.id) ?? .max, (pond.cameras ?? []).firstIndex(of: b) ?? 0)
            }
            groups.append((pond.id, pond.name, sorted.map { c in
                var camera = Config.Camera(id: c.id, name: c.name, main: c.main, sub: c.sub, username: "", kind: c.doorbell ? .doorbell : .camera)
                camera.device = Config.Device(manufacturer: "", model: c.model ?? "", isDoorbell: c.doorbell)
                camera.device?.controls = c.controls
                return camera
            }))
        }
        return groups
    }

    /// Which Pond a camera's at (nil: this Mac).
    nonisolated static func pond(of camera: String) -> String? { ControlSocket.RemotePond.split(camera)?.pond }

    /// Another Pond's camera moved to another's place in its order, as when dropped onto it (within one Pond only).
    func moveRemoteCamera(_ id: String, onto target: String) {
        guard let pond = Self.pond(of: id), Self.pond(of: target) == pond,
              var ids = cameraGroups.first(where: { $0.pond == pond })?.cameras.map(\.id),
              let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        remoteOrder[pond] = ids
    }

    /// The Pond a camera's at, when cameras of several are shown together (for its tile's name).
    func pondName(of camera: String) -> String? {
        guard stageMixesPonds else { return nil }
        guard let (_, pond) = ControlSocket.RemotePond.split(camera) else { return thisPondName }
        return remotePonds.first { $0.id == pond }?.name
    }

    func isConnected(_ pond: ControlSocket.RemoteDevice) -> Bool { remoteStatus?.connected.contains { $0.device == pond.id } == true }

    func connection(_ pond: ControlSocket.RemoteDevice) -> String {
        remoteStatus?.connected.first { $0.device == pond.id }.map { "Connected, \($0.how)" } ?? "Not connected"
    }

    var recorderWords: String {
        switch serviceState {
        case _ where isRestartingRecorder: "Restarting\u{2026}"
        case .running where needsRestart: "Restart Recorder"
        case .running: "Recording"
        case .stopped: "Recorder stopped"
        case .notInstalled: "Not recording"
        }
    }
}

/// Which Ponds the window shows.
enum ShownPonds: Hashable {
    case all, this
    case pond(String)

    /// Whether a Pond's shown (nil: this Mac).
    func includes(_ pond: String?) -> Bool {
        switch self {
        case .all: true
        case .this: pond == nil
        case let .pond(id): pond == id
        }
    }
}

/// Another Pond shown on its own, in a view that doesn't show other Ponds yet (the Timeline).
struct OtherPondView: View {
    @Environment(AppModel.self) private var model
    let name: String
    let what: String

    var body: some View {
        ContentUnavailableView {
            Label(name, systemImage: "house")
        } description: {
            Text("\(what) of other Ponds aren\u{2019}t shown yet. Live shows their cameras.")
        } actions: {
            Button("Show \(model.thisPondName)") { model.shownPonds = .this }
        }
    }
}

/// A Pond's section in the camera rail: its name, for another Pond whether it's connected (or why it can't be
/// reached), and a chevron that folds it away.
struct PondHeading: View {
    @Environment(AppModel.self) private var model
    let name: String
    /// Nil: this Mac.
    let pond: String?
    let count: Int
    @Binding var folded: Bool

    var body: some View {
        let other = pond.flatMap { id in model.remotePonds.first { $0.id == id } }
        Button {
            withAnimation(.snappy(duration: 0.25)) { folded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                Image(systemName: pond == nil ? "desktopcomputer" : "house.fill")
                    .foregroundStyle(pond == nil ? .secondary : other?.problem == nil ? Color.green : .orange)
                    .font(.caption)
                Text(name).font(.subheadline.weight(.semibold))
                if let problem = other?.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if folded {
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folded ? "Show \(name)\u{2019}s cameras" : "Fold \(name)\u{2019}s cameras away")
    }
}

/// A thin ring spreading out from the recording mark and fading, every couple of seconds: it's live.
struct RecordingRipple: View {
    static let period = 2.2

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
            // Out over the first two thirds of each period, then nothing until the next.
            let p = min(1, t / 0.66)
            Circle()
                .stroke(Color.red, lineWidth: 1.5)
                .scaleEffect(0.8 + 0.6 * p)
                .opacity(t < 0.66 ? 0.6 * (1 - p) : 0)
        }
        .allowsHitTesting(false)
    }
}
