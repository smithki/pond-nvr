// The Settings window (⌘,): a tab per kind of setting, in the window's toolbar as on any Mac app.
import AppKit
import PondCore
import SwiftUI
import Understanding
import Watch

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, cameras, storage, remote, advanced

    var id: String { rawValue }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralSettings() }
            Tab("Cameras", systemImage: "video", value: SettingsTab.cameras) { needsSettings { CamerasView() } }
            Tab("Storage", systemImage: "externaldrive", value: SettingsTab.storage) { needsSettings { StorageView() } }
            Tab("Remote Access", systemImage: "network", value: SettingsTab.remote) { needsSettings { RemoteAccessView() } }
            Tab("Advanced", systemImage: "gearshape.2", value: SettingsTab.advanced) { AdvancedSettings() }
        }
        // Tall enough that a camera's settings (a sheet as tall as this) fit unscrolled with their sections
        // closed.
        .frame(width: 640, height: 560)
        // Measured as Settings opens, so Storage has it before they are first shown.
        .task { await model.refreshStorageOutlook() }
        .alert("Not saved", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }

    @ViewBuilder
    func needsSettings(@ViewBuilder _ content: () -> some View) -> some View {
        if model.config == nil { SetupView() } else { content() }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Appearance.key) private var appearance = Appearance.dark

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
        .formStyle(.grouped)
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
        .formStyle(.grouped)
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

/// Descriptions and search: whether the Mac's own model is writing sentences (and if not, why), whether there's a
/// picture model, and how far the service has come through the events kept.
struct UnderstandingSection: View {
    @Environment(AppModel.self) private var model
    @State private var availability = Describer.availability
    @State private var progress: (events: Int, described: Int, embedded: Int)?

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
            LabeledContent("Pictures", value: SigLIP.builtIn == nil ? "No picture model in this copy of Pond" : "Matched to words by SigLIP 2")
            // Only while it's catching up (all done, it's nothing to read).
            if let progress, progress.events > 0, max(progress.described, progress.embedded) < progress.events {
                LabeledContent("Events understood") {
                    Text("\(max(progress.described, progress.embedded)) of \(progress.events)").monospacedDigit()
                }
            }
        } header: {
            Text("Descriptions and search")
        } footer: {
            Text("Each event\u{2019}s picture described and matched to words, to search events in plain words. On this Mac only, never in the cloud.")
                .foregroundStyle(.secondary)
        }
        .task {
            // (Kept up to date while it's shown: the service works through the events in the background.)
            while !Task.isCancelled {
                availability = Describer.availability
                if let path = model.config?.storage.databasePath {
                    progress = await Task.detached { EventStore(path: path, readOnly: true)?.understandingProgress() }.value
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
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
    @AppStorage(MenuBarItem.key) private var menuBarItem = true
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
