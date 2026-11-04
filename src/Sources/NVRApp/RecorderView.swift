import Control
import Ingest
import SwiftUI

struct RecorderView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmUninstall = false
    @State private var log = ServiceLog()
    /// The tab's height: the log takes what the rest leaves, so the page fits without scrolling.
    @State private var tabHeight = 560.0
    /// The media engine's budget, as the service has it.
    @State private var media: MediaBudget.Report?

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
                if case .running = model.serviceState, let media { MediaEngineRow(report: media) }
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

            LogSection(log: log, height: max(140, tabHeight - (media == nil ? 366 : 394)))
        }
        .formStyle(.grouped)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { tabHeight = $0 }
        .task {
            while !Task.isCancelled {
                model.refreshService()
                log.refresh()
                media = await model.controlClient.ask(.init(camera: "", action: "media.budget"), timeout: 3).media
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

/// How full the media engine is (Pond's video decoding and encoding, against what the chip can do), by what's using
/// it, and what's been shed to make room (detection on keyframes, recordings from the sub-stream).
struct MediaEngineRow: View {
    let report: MediaBudget.Report

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                ProgressView(value: min(1, report.used / max(1, report.capacity)))
                    .frame(width: 120)
                    .tint(report.percent > 100 ? .orange : report.shed.isEmpty ? .accentColor : .yellow)
                Text("\(report.percent)%").monospacedDigit().foregroundStyle(.secondary)
            }
        } label: {
            Text("Media engine")
            Text(words)
        }
        .help("Video decoded and encoded by Pond, against what this Mac\u{2019}s media engine can do. When it\u{2019}s full, the least important gives way first: closer looks close, then detection looks at keyframes only, then new HomeKit recordings are made from the sub-stream.")
    }

    var words: String {
        let parts = report.kinds.map { "\($0.kind.words) \($0.count)" }.joined(separator: ", ")
        let using = parts.isEmpty ? "Nothing decoding now" : parts.prefix(1).uppercased() + parts.dropFirst()
        return report.shed.isEmpty ? using : "\(using). To make room: \(report.shed.joined(separator: ", "))"
    }
}
