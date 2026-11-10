// The Settings window's pages for this Pond as a whole (SettingsWindow): General and Advanced (Storage and Remote
// Access have files of their own).
import AppKit
import PondCore
import SwiftUI
import Understanding
import Watch

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Appearance.key, store: AppDefaults.store) private var appearance = Appearance.dark

    var body: some View {
        Form {
            Section {
                PondNameField()
                Picker(selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Appearance")
                    Text("Dark by default: video is easier to watch on a dark surround.")
                }
            }
            MenuBarSection()
            UnderstandingSection()
        }
        .pageForm()
    }
}

/// Advanced: beta and test features, and the app itself (its version, its settings file).
struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.config != nil { AdvancedSection() }
            // (In a demo, its toolbar's menu switches between them.)
            if DemoSession.scenario == nil {
                Section {
                    LabeledContent("Demo") {
                        Menu("Open the Demo\u{2026}") {
                            ForEach(Demo.scenarios, id: \.name) { scenario in
                                Button {
                                    DemoSession.open(scenario)
                                } label: {
                                    Text(scenario.title)
                                    Text(scenario.about)
                                }
                            }
                        }
                        .fixedSize()
                    }
                } footer: {
                    Text("Made-up cameras, recorded, watched and found in like real ones, in a copy of Pond of its own: your settings, recordings and recorder aren\u{2019}t touched.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Version", value: Brand.version)
                LocationRow(symbol: "doc.text", path: model.store.path)
            } header: {
                Text("About Pond")
            } footer: {
                Text("The settings file is shared by the app and the pond command. Change it with POND_CONFIG or --config.")
                    .foregroundStyle(.secondary)
            }
        }
        .pageForm()
    }
}

/// Advanced: beta and test features (off by default): what's tried before everyone has it, and test scenes kept from
/// this Pond's events for checking a new version (`pond advanced scenes`), with the room they take and their deleting.
struct AdvancedSection: View {
    @Environment(AppModel.self) private var model
    @State private var size: (scenes: Int, bytes: Int64)?
    @State private var confirmDelete = false

    var library: SceneLibrary? { model.config.map { SceneLibrary(beside: $0.storage.databasePath) } }

    static func title(_ feature: Config.TestFeature) -> String {
        switch feature {
        case .testScenes: "Keep test scenes"
        }
    }

    static func about(_ feature: Config.TestFeature) -> String {
        switch feature {
        case .testScenes:
            "For checking a new version against your own events: the clips of events you say weren\u{2019}t anything or were, and a few you keep, beside Pond\u{2019}s database (on this Mac only, and kept past event retention)."
        }
    }

    var body: some View {
        Section {
            let unlocked = model.config?.testFeatures == true
            Toggle(isOn: Binding(get: { unlocked },
                                 set: { on in _ = model.update(affectsRecorder: false) { $0.testFeatures = on ? true : nil } })) {
                Text("Beta and test features")
                Text("Try features before they\u{2019}re finished. Turn each one on below.")
            }
            // Each feature, dimmed and out of reach while they're all off.
            ForEach(Config.TestFeature.allCases, id: \.self) { feature in
                Toggle(isOn: Binding(get: { model.config?.testFeaturesOn?.contains(feature.rawValue) == true },
                                     set: { on in _ = model.update(affectsRecorder: false) { config in
                                         var ids = (config.testFeaturesOn ?? []).filter { $0 != feature.rawValue }
                                         if on { ids.append(feature.rawValue) }
                                         config.testFeaturesOn = ids.isEmpty ? nil : ids
                                     } })) {
                    Text(Self.title(feature))
                    Text(Self.about(feature))
                }
                .padding(.leading, 16)
                .disabled(!unlocked)
                .opacity(unlocked ? 1 : 0.45)
                .animation(.default, value: unlocked)
            }
            if let size, size.scenes > 0 {
                LabeledContent {
                    Button("Delete Test Scenes\u{2026}") { confirmDelete = true }
                } label: {
                    Text("Test scenes")
                    Text("\(size.scenes) kept, \(ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)). Checked with pond advanced scenes.")
                }
            }
        }
        .task(id: model.config?.has(.testScenes)) {
            guard let library else { return }
            size = await Task.detached { library.size() }.value
        }
        .confirmationDialog("Delete the test scenes?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                library?.removeAll()
                size = nil
            }
        } message: {
            Text("Their clips are deleted. What Pond learnt from what you said of events is kept.")
        }
    }
}

/// Descriptions and search: whether the Mac's own model is writing sentences (and if not, why), which version of the
/// picture model search uses (downloading it, or a new one, as it goes), and how far the service has come through the
/// events kept.
struct UnderstandingSection: View {
    @Environment(AppModel.self) private var model
    @State private var availability = Describer.availability
    @State private var progress: (events: Int, described: Int, embedded: Int)?
    @State private var status: SearchModelStatus?
    @State private var asked = false
    @State private var unreachable = false

    var body: some View {
        Section {
            LabeledContent("Descriptions") {
                HStack(spacing: 8) {
                    Text(Self.words(availability)).foregroundStyle(availability == .available ? .primary : .secondary)
                    if availability == .turnedOff {
                        Button("Open Settings\u{2026}") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                        }
                    }
                }
            }
            SearchModelRow(status: status, unreachable: unreachable, checking: asked) {
                asked = true
                unreachable = !(await model.checkSearchModel())
                // (What it finds is in the status file, read below; the button's ready again once it's read it.)
                try? await Task.sleep(for: .seconds(1.5))
                asked = false
            }
            // Only while it's catching up (all done, it's nothing to read): after a new version's downloaded, embedding
            // every event again by it.
            if let progress, progress.events > 0, max(progress.described, progress.embedded) < progress.events {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: Double(max(progress.described, progress.embedded)), total: Double(progress.events))
                            .frame(width: 220)
                        Text("\(max(progress.described, progress.embedded)) of \(progress.events)").monospacedDigit()
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Events understood")
                    if let name = status?.current?.name, progress.embedded < progress.events, status?.lastUpdate != nil {
                        Text("Pictures matched again by \(name), newest first. Search finds them all meanwhile.")
                    }
                }
            }
            if model.config != nil {
                Toggle(isOn: Binding(get: { model.config?.searchModelUpdates != false },
                                     set: { on in model.update(affectsRecorder: false) { $0.searchModelUpdates = on ? nil : false } })) {
                    Text("Download picture model updates")
                    Text("Pond asks pond.camera once a week and downloads a new version when there is one, signed by Pond. Nothing about you or your cameras is sent.")
                }
            }
        } header: {
            Text("Descriptions and search")
        } footer: {
            Text("Each event\u{2019}s picture described and matched to words, to search events in plain words. On this Mac only, never in the cloud.")
                .foregroundStyle(.secondary)
        }
        .task {
            // (Kept up to date while it's shown: the service downloads and works through the events in the background.)
            var tick = 0
            while !Task.isCancelled {
                status = model.readSearchModelStatus()
                if tick % 5 == 0 {
                    availability = Describer.availability
                    if let path = model.config?.storage.databasePath {
                        let name = status?.current?.name
                        progress = model.demoSearchModelStatus != nil ? Self.demoProgress
                            : await Task.detached { EventStore(path: path, readOnly: true)?.understandingProgress(embedder: name) }.value
                    }
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// A demo's made-up catching up, when its search model status is one that's just been updated.
    static var demoProgress: (events: Int, described: Int, embedded: Int)? {
        DemoSearchModel.state == .indexing ? (12_480, 12_480, 3_412) : nil
    }

    static func words(_ availability: Describer.Availability) -> String {
        switch availability {
        case .available: "By Apple Intelligence, on this Mac"
        case .turnedOff: "Off: Apple Intelligence is turned off"
        case .notReady: "Waiting: Apple Intelligence is still getting ready"
        case .notEligible: "Not on this Mac: it can\u{2019}t run Apple Intelligence"
        case .unavailable: "Not available now"
        }
    }
}

/// Search's picture model: which version is in use, or how its download's going, when pond.camera was last asked
/// and what's gone wrong, if anything; and Check for Updates.
struct SearchModelRow: View {
    let status: SearchModelStatus?
    let unreachable: Bool
    let checking: Bool
    let check: () async -> Void

    // One line on the right at any width (the version, or its download's bar, and the button); what's said of it,
    // which can be long, under the label, where it wraps.
    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                switch status?.activity {
                case let .downloading(_, _, received, total)?:
                    ProgressView(value: Double(received), total: Double(max(total, 1))).frame(width: 140)
                case .installing?:
                    ProgressView().progressViewStyle(.linear).frame(width: 140)
                default:
                    Text(status?.current?.name ?? "Not downloaded yet").lineLimit(1)
                        .foregroundStyle(status?.current == nil ? .secondary : .primary)
                }
                Button("Check for Updates") { Task { await check() } }
                    .disabled(checking || status?.activity != nil)
            }
            .fixedSize()
        } label: {
            Text("Picture model")
            if let problem = problemText {
                Text(problem).foregroundStyle(.orange)
            } else if let line = detail {
                Text(line)
            }
        }
    }

    /// "Updated Nov 12 · Last checked today", or as much of it as there is.
    var detail: String? {
        guard let status else { return nil }
        switch status.activity {
        case let .downloading(_, name, received, total)?:
            return "Downloading \(name) \u{00B7} \(Self.megabytes(received)) of \(Self.megabytes(total))"
        case let .installing(_, name)?:
            return "Checking \(name) and putting it in place\u{2026}"
        default: break
        }
        if status.activity == .checking || checking { return "Checking pond.camera\u{2026}" }
        var parts: [String] = []
        if status.current?.id == "built-in" { parts.append("Built into this copy of Pond") }
        if let updated = status.lastUpdate { parts.append("Updated \(Self.day(updated, capital: false))") }
        if let checked = status.lastCheck {
            parts.append(status.lastCheckAnswered == false ? "Last tried \(Self.day(checked, capital: false))"
                                                            : "Last checked \(Self.day(checked, capital: false))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    var problemText: String? {
        if unreachable { return "The recorder isn\u{2019}t running, so it can\u{2019}t check now." }
        switch status?.problem {
        case .offline?: return "Couldn\u{2019}t reach pond.camera. Pond tries again later."
        case .badManifest?: return "pond.camera\u{2019}s answer wasn\u{2019}t understood. Pond tries again later."
        case .unsigned?: return "No version on pond.camera is signed by Pond, so none was downloaded."
        case .wrongFile?: return "The download wasn\u{2019}t the file Pond expected, so it was thrown away. Pond tries again later."
        case .noRoom?: return "There isn\u{2019}t room on this Mac for it (it needs about 700 MB free)."
        case .unpacking?: return "The download couldn\u{2019}t be unpacked. Pond tries again later."
        case nil: return nil
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    /// "today", "yesterday", or the date.
    static func day(_ date: Date, capital: Bool) -> String {
        let calendar = Calendar.current
        let word = calendar.isDateInToday(date) ? "today" : calendar.isDateInYesterday(date) ? "yesterday"
            : date.formatted(.dateTime.month(.abbreviated).day())
        return capital ? word.prefix(1).uppercased() + word.dropFirst() : word
    }
}

/// This Pond's name, kept as it's typed (when typing stops).
struct PondNameField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        TextField(text: $text, prompt: Text(Host.current().localizedName ?? "This Mac")) {
            Text("Name")
            Text("How this Pond is shown to others paired with it.")
        }
            .onAppear { text = model.config?.name ?? "" }
            .onSubmit(save)
            .task(id: text) {
                try? await Task.sleep(for: .seconds(0.8))
                if !Task.isCancelled { save() }
            }
    }

    func save() {
        let name = text.trimmingCharacters(in: .whitespaces)
        if (model.config?.name ?? "") != name { model.update(affectsRecorder: false) { $0.name = name.isEmpty ? nil : name } }
    }
}

/// The menu bar item, and opening at login: what keeps Pond watching the recorder with its window closed.
struct MenuBarSection: View {
    @AppStorage(MenuBarItem.key, store: AppDefaults.store) private var menuBarItem = true
    @State private var atLogin = OpenAtLogin.isOn
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle(isOn: $menuBarItem) {
                Text("Show in the menu bar")
                Text("Recording and each camera\u{2019}s privacy; it keeps running there with its window closed.")
            }
            Toggle(isOn: Binding(get: { atLogin }, set: { on in
                problem = OpenAtLogin.set(on)
                atLogin = OpenAtLogin.isOn
            })) {
                Text("Open at login")
                Text("After a restart (a power cut, say), you\u{2019}re told if Pond isn\u{2019}t recording.")
            }
            // (Not the demo's copy of Pond: the real one is what opens at login.)
            .disabled(DemoSession.scenario != nil)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            Text("Watching the recorder")
        }
    }
}
