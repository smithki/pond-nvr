import Control
import SwiftUI

struct RecorderView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmUninstall = false
    @State private var log = ServiceLog()
    /// The tab's height: the log takes what the rest leaves, so the page fits without scrolling.
    @State private var tabHeight = 560.0

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    switch model.serviceState {
                    case _ where model.isRestartingRecorder:
                        // A label like the row's others (a spinner is taller, and nudged the page down and up).
                        Label {
                            Text("Restarting\u{2026}")
                        } icon: {
                            Image(systemName: "arrow.clockwise").symbolEffect(.rotate, options: .repeating)
                        }
                        .foregroundStyle(.secondary)
                    case .notInstalled:
                        Label("Not installed", systemImage: "circle.dashed").foregroundStyle(.secondary)
                    case let .running(pid):
                        if model.needsRestart {
                            Label("Recording with older settings", systemImage: "arrow.clockwise.circle.fill")
                                .foregroundStyle(.orange)
                                .help("Settings it works from changed since it started (process \(pid)). Restart it to use them.")
                        } else {
                            Label("Recording (process \(pid))", systemImage: "record.circle.fill").foregroundStyle(.green)
                        }
                    case let .stopped(why):
                        Label("Not running: \(why)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                HStack {
                    Spacer()
                    switch model.serviceState {
                    case .notInstalled:
                        Button(model.isChangingService ? "Starting\u{2026}" : "Start Recording") { model.installService() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.helperPath == nil)
                    default:
                        Button("Stop and Remove…") { confirmUninstall = true }
                        // The tab's own Restart: orange while the recorder runs with older settings, as the
                        // Restart Recorder buttons elsewhere are (so this tab needs none of its own).
                        Group {
                            let restart = Button(model.isChangingService ? "Restarting\u{2026}" : "Restart") { model.restartService() }
                                .disabled(model.isChangingService)
                            if model.needsRestart {
                                restart.buttonStyle(.borderedProminent).tint(.orange)
                            } else {
                                restart
                            }
                        }
                        .animation(.snappy(duration: 0.25), value: model.needsRestart)
                    }
                }
            } header: {
                Text("Background recording")
            } footer: {
                Text("The recorder runs in the background whenever you are logged in, and starts again if it stops. Closing this window does not stop it. The first time, macOS may ask whether it may find devices on your network (Allow) and use the camera passwords (Always Allow).")
                    .foregroundStyle(.secondary)
            }

            LogSection(log: log, height: max(140, tabHeight - 366))
        }
        .formStyle(.grouped)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { tabHeight = $0 }
        .task {
            while !Task.isCancelled {
                model.refreshService()
                log.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Stop recording?", isPresented: $confirmUninstall) {
            Button("Stop and Remove", role: .destructive) { model.uninstallService() }
        } message: {
            Text("The recorder stops and no longer starts at login. Recordings and settings stay.")
        }
    }
}
