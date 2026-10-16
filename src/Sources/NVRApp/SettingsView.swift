// The Settings window (⌘,): a tab per kind of setting, in the window's toolbar as on any Mac app.
import AppKit
import NVRCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, cameras, storage, retention, recorder

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
            Tab("Retention", systemImage: "clock.arrow.circlepath", value: SettingsTab.retention) {
                needsSettings { RetentionView() }
            }
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
            Section {
                LabeledContent("Version", value: Brand.version)
            }
        }
        .formStyle(.grouped)
    }
}
