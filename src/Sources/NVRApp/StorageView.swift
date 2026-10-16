import AppKit
import NVRCore
import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var choosing: Target?
    @State private var turningOff = false
    @State private var spotlightProblem: String?

    enum Target: Identifiable {
        case recordings, database
        var id: Self { self }
    }

    /// The last measurement, so the tab is laid out at once when it appears; measured again as it does.
    var outlook: StorageOutlook? { model.lastStorageOutlook }

    var body: some View {
        let storage = model.config?.storage
        let recordings = storage?.recordingsPath ?? ""
        Form {
            Section {
                LocationRow(symbol: "externaldrive", path: recordings, status: .storage(StorageLocation.status(of: recordings)),
                            choose: { choosing = .recordings })
                if let estimate = outlook?.estimate { lasting(estimate) }
            } header: {
                Text("Recordings").restartRecorderButton()
            } footer: {
                Text("Continuous recording, and event clips and snapshots in a folder of their own beside it. Pond records only while this folder is there, so an unplugged drive never fills this Mac\u{2019}s disk.")
                    .foregroundStyle(.secondary)
            }

            if let outlook, let drive = outlook.drive { checklist(drive, outlook: outlook) }

            Section {
                LocationRow(symbol: "cylinder.split.1x2", path: storage?.databasePath ?? "", choose: { choosing = .database })
                if storage?.databasePath.hasPrefix("/Volumes/") == true {
                    Label("The index is on another drive. A NAS share is unreliable for it; this Mac\u{2019}s disk is safer.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Index")
            } footer: {
                Text("What was recorded when, for the timeline. Small; best on this Mac\u{2019}s own disk.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: model.config) { await measure() }
        .fileImporter(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                      allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result, let target = choosing else { return }
            switch target {
            case .recordings: model.chooseFolder(url, forEvents: false)
            case .database: model.chooseDatabaseFolder(url)
            }
            choosing = nil
        }
        .alert("Spotlight", isPresented: Binding(get: { spotlightProblem != nil }, set: { if !$0 { spotlightProblem = nil } })) {
            Button("OK") { spotlightProblem = nil }
        } message: {
            Text(spotlightProblem ?? "")
        }
    }

    func measure() async {
        await model.refreshStorageOutlook()
    }

    /// How long the folder lasts, and from what.
    @ViewBuilder
    func lasting(_ e: StorageEstimate) -> some View {
        let cameras = model.config?.cameras.count ?? 0
        let measured = switch e.source {
        case .recorded: "as recorded"
        case .checked: "as measured when last checked"
        case .assumed: "assumed until the camera\u{2019}s first check or recording"
        }
        LabeledContent {
            Text(StorageEstimate.duration(days: e.continuousDays)).font(.title3.weight(.semibold))
        } label: {
            Text("Holds about")
            Text("of continuous recording for \(cameras) camera\(cameras == 1 ? "" : "s") at \(StorageEstimate.size(e.continuousPerDay)) a day (\(measured)), with \(StorageEstimate.size(e.eventsReserved)) set aside for \(model.config?.retention.events.days ?? 0) days of event clips and snapshots (estimated, until detection runs).")
        }
    }

    @ViewBuilder
    func checklist(_ drive: DriveFacts, outlook: StorageOutlook) -> some View {
        Section("Checklist") {
            CheckRow(ok: !drive.isStartupDisk,
                     title: drive.isStartupDisk ? "On this Mac\u{2019}s startup disk" : "On \(drive.name), \(drive.isInternal ? "an internal" : "an external") drive",
                     detail: drive.isStartupDisk ? "Recordings take space from everything else on this Mac. A drive of their own is better." : nil)
            if !drive.isStartupDisk {
                switch drive.spotlightIndexing {
                case false?:
                    CheckRow(ok: true, title: "Spotlight doesn\u{2019}t index it")
                case true?:
                    CheckRow(ok: false, title: "Spotlight indexes it",
                             detail: "Spotlight reads every new recording to index it, which adds work for the drive and the Mac and finds nothing useful in video.") {
                        Button(turningOff ? "Turning Off\u{2026}" : "Turn Off\u{2026}") { turnOffSpotlight(drive.volume) }
                            .disabled(turningOff)
                            .help("Turns Spotlight off for \(drive.name). macOS asks for an administrator\u{2019}s password.")
                    }
                case nil:
                    CheckRow(ok: nil, title: "Spotlight", detail: "Pond couldn\u{2019}t tell whether Spotlight indexes this drive.")
                }
            }
            if ["exfat", "fat", "ms-dos"].contains(where: { drive.format.lowercased().contains($0) }) {
                CheckRow(ok: false, title: "Formatted as \(drive.format)",
                         detail: "\(drive.format) keeps no journal, so a drive unplugged without ejecting can lose its latest recordings. APFS is safer for a drive used only for recordings.")
            } else if !drive.format.isEmpty {
                CheckRow(ok: true, title: "Formatted as \(drive.format)")
            }
            if let e = outlook.estimate {
                let fits = e.continuousDays >= Double(outlook.keepDays)
                CheckRow(ok: fits,
                         title: fits ? "Holds the \(outlook.keepDays) days you keep" : "Holds about \(StorageEstimate.duration(days: e.continuousDays)) of the \(outlook.keepDays) days you keep",
                         detail: fits ? nil : "The oldest recording is deleted sooner to make room. A bigger drive, or fewer days in Retention, would match.")
            }
        }
    }

    func turnOffSpotlight(_ volume: String) {
        turningOff = true
        Task {
            let problem = await Task.detached { DriveFacts.turnOffSpotlight(volume) }.value
            turningOff = false
            spotlightProblem = problem
            await measure()
        }
    }
}

/// A checklist line: a mark (green tick, orange warning, or grey for unknown), what it is, why it matters
/// when it is not right, and an action if there is one.
struct CheckRow<Action: View>: View {
    let ok: Bool?
    let title: String
    var detail: String?
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "exclamationmark.triangle.fill" : "questionmark.circle")
                .foregroundStyle(ok == true ? .green : ok == false ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            action()
        }
    }
}

extension CheckRow where Action == EmptyView {
    init(ok: Bool?, title: String, detail: String? = nil) {
        self.init(ok: ok, title: title, detail: detail) { EmptyView() }
    }
}

/// A file or folder, the same everywhere in Settings: an icon, the path (with ~ for the home folder), its
/// state if it has one, and its buttons: Show in Finder, and Choose… where it can be changed.
struct LocationRow: View {
    let symbol: String
    let path: String
    var status: Status?
    var choose: (() -> Void)?

    enum Status {
        case ready(String)
        case problem(String)

        static func storage(_ s: StorageLocation.Status) -> Status {
            if s.isReady { return .ready("Ready") }
            return .problem(s.description.prefix(1).uppercased() + s.description.dropFirst())
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .textSelection(.enabled)
                    .truncationMode(.middle)
                    .lineLimit(1)
                switch status {
                case let .ready(text)?:
                    Label(text, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                case let .problem(text)?:
                    Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                case nil:
                    EmptyView()
                }
            }
            Spacer()
            Button {
                // A file not made yet (the index before the first recording): its folder.
                let url = URL(fileURLWithPath: path)
                let shown = FileManager.default.fileExists(atPath: path) ? url : url.deletingLastPathComponent()
                NSWorkspace.shared.activateFileViewerSelecting([shown])
            } label: {
                Image(systemName: "finder")
            }
            .help("Show in Finder")
            .disabled(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
            if let choose { Button("Choose\u{2026}", action: choose) }
        }
    }
}
