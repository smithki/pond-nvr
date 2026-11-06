// The toolbar's state: whether all's well, and which Ponds the window shows. With only this Mac, its state in words
// ("Recording", "Side Gate not recorded", "3 need attention"); with other Ponds, the one shown ("All Ponds", "Home",
// "Lake House"), the state in its mark and a count. Clicked, an overview (OverviewPanel): what needs attention at
// each Pond, with its fix, the cameras kept private, and which Ponds to show.
import Devices
import PondCore
import SwiftUI

struct PondSwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var nudged = false

    /// What the button says, in its tooltip.
    var meaning: String {
        let count = model.attentionCount
        let state = count == 0 ? (model.isRecording ? "All\u{2019}s well." : model.recorderWords + ".")
            : count == 1 ? (model.attention.first?.title ?? "") + "."
            : "\(count) things need attention."
        return state + (model.otherPonds.isEmpty ? "" : " Showing \(model.shownName).") + " Click for an overview."
    }

    var body: some View {
        let switches = !model.otherPonds.isEmpty
        let count = model.attentionCount
        Button {
            withAnimation(.snappy(duration: 0.3)) {
                model.showingFoundCameras = false
                model.showingOverview.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                PondMark()
                    .symbolEffect(.bounce, value: model.shownPondsNudge)
                // With other Ponds, how many things need attention (any Pond's), beside the one shown.
                if switches, count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.18), in: Capsule())
                }
                Text(switches ? model.shownName : model.statusWords)
                    // Changed by something else (a camera of a Pond not shown chosen in Events): lit a moment. (The
                    // toolbar's glass can't be tinted or outlined, and what's drawn past the label is cut off: the
                    // label's own words are what can say so.)
                    .foregroundStyle(nudged ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            // Changed by something else: the button glows a moment, the whole of it, then fades.
            .task(id: model.shownPondsNudge) {
                guard model.shownPondsNudge > 0 else { return }
                withAnimation(.easeIn(duration: 0.15)) { nudged = true }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 1)) { nudged = false }
            }
        }
        // Its words changed at once, not morphed from the middle (which nudged the mark and the chevron about), and
        // the toolbar's glass takes the new width at once too, as Find Cameras' does.
        .transaction(value: "\(switches) \(count) \(model.shownName) \(model.statusWords)") { $0.animation = nil }
        .reportingMiddleFromLeading { if model.overviewButtonFromLeading != $0 { model.overviewButtonFromLeading = $0 } }
        .fixedSize()
        .help(meaning)
        .accessibilityLabel(switches ? "\(model.shownName), \(count) need attention" : model.statusWords)
    }
}

/// The state, as a mark: anything needing attention (any Pond's), else the shown Pond's: this Mac's recorder, or
/// another's connection.
struct PondMark: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.attentionCount > 0 {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if case let .pond(id) = model.shownPonds, let pond = model.otherPonds.first(where: { $0.id == id }) {
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

    /// This Mac's cameras kept private, by name.
    var privateHere: [String] { (config?.cameras ?? []).filter { isPrivate($0.id) }.map(\.name) }

    var recorderWords: String {
        switch serviceState {
        case _ where isRestartingRecorder: "Restarting\u{2026}"
        case .running where needsRestart: "Restart Recorder"
        // (A private mode forgotten is a gap in the recordings no one sees otherwise.)
        case .running: privateHere.isEmpty ? "Recording" : "Recording \u{00B7} \(privateHere.count) private"
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
        // Folded or opened at once (only the chevron turns): the rail's cameras moving to make room didn't animate well.
        Button {
            folded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .animation(.snappy(duration: 0.2), value: folded)
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
