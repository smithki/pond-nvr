// The Settings window (⌘,): a tab per kind of setting, in the window's toolbar as on any Mac app.
import AppKit
import NVRCore
import SwiftUI
import Understanding
import Watch

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, cameras, doctor, storage, retention, remote, recorder

    var id: String { rawValue }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralSettings() }
            Tab("Cameras", systemImage: "video", value: SettingsTab.cameras) { needsSettings { CamerasView() } }
            Tab("Doctor", systemImage: "stethoscope", value: SettingsTab.doctor) { needsSettings { DoctorView() } }
            Tab("Storage", systemImage: "externaldrive", value: SettingsTab.storage) { needsSettings { StorageView() } }
            Tab("Retention", systemImage: "clock.arrow.circlepath", value: SettingsTab.retention) {
                needsSettings { RetentionView() }
            }
            Tab("Remote Access", systemImage: "network", value: SettingsTab.remote) { needsSettings { RemoteAccessView() } }
            Tab("Recorder", systemImage: "record.circle", value: SettingsTab.recorder) { needsSettings { RecorderView() } }
        }
        // Tall enough that a camera's settings (a sheet as tall as this) fit unscrolled with their sections
        // closed.
        .frame(width: 640, height: 560)
        // Measured as Settings opens, so Storage and Retention have it before they are first shown.
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
            } footer: {
                Text("How this Pond is shown beside others you\u{2019}ve paired with it, and the name devices pairing with it see.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Dark by default: video is easier to watch on a dark surround.").foregroundStyle(.secondary)
            }
            Section {
                LocationRow(symbol: "doc.text", path: model.store.path)
            } header: {
                Text("Settings file")
            } footer: {
                Text("Shared by the app and the pond command. Change it with POND_CONFIG or --config.").foregroundStyle(.secondary)
            }
            UnderstandingSection()
            Section {
                LabeledContent("Version", value: Brand.version)
            }
        }
        .formStyle(.grouped)
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
            if let progress, progress.events > 0 {
                LabeledContent("Events understood") {
                    Text("\(max(progress.described, progress.embedded)) of \(progress.events)").monospacedDigit()
                }
            }
        } header: {
            Text("Descriptions and search")
        } footer: {
            Text("Each event\u{2019}s picture is described in a sentence and matched to words, for searching events in plain words. On this Mac only: never in the cloud. Events from before are done too, in the background.")
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
        TextField("Name", text: $text, prompt: Text(Host.current().localizedName ?? "This Mac"))
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
