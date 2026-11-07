// Settings › Storage, on one page: where recordings go and how long they're kept (StorageSpace), the space on their
// drive, a checklist for the drive folded into one row (not the startup disk, Spotlight off, a format that keeps a
// journal; open when something's wrong), and where the index goes.
import AppKit
import PondCore
import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) var model
    /// The folder being chosen, kept until the picker answers (its presentation is apart: closing it comes first).
    @State private var choosing: Target?
    @State private var picking = false
    @State private var turningOff = false
    @State private var spotlightProblem: String?
    /// While a slider is dragged: its value, shown live and saved when it is let go (StorageSpace).
    @State var draftLimit: Double?
    @State var draftReserve: Double?
    /// The checklist opened or closed by hand (nil: open only while something's wrong).
    @State private var checklistOpen: Bool?

    enum Target: Identifiable {
        case recordings, database
        var id: Self { self }
    }

    /// The last measurement, so the tab is laid out at once when it appears; measured again as it does.
    var outlook: StorageOutlook? { model.lastStorageOutlook }

    var body: some View {
        let storage = model.config?.storage
        let recordings = storage?.recordingsPath ?? ""
        let drive = outlook?.drive
        let troubled = drive.map { Self.problems($0) > 0 } ?? false
        Form {
            Section {
                // What's wrong with the drive first, when something is (open); all well, it waits at the bottom
                // (closed).
                if troubled, let drive { checklist(drive) }
                LocationRow(symbol: "externaldrive", path: recordings, status: .storage(StorageLocation.status(of: recordings)),
                            choose: { choose(.recordings) })
                    .help("Pond records only while this folder is there, so an unplugged drive never fills this Mac\u{2019}s disk.")
                keepRows
            } header: {
                Text("Recordings").restartRecorderButton()
            }
            spaceSection
            Section {
                if !troubled, let drive { checklist(drive) }
                LocationRow(symbol: "cylinder.split.1x2", path: storage?.databasePath ?? "",
                            caption: "The index: what was recorded when. Best on this Mac\u{2019}s own disk.", choose: { choose(.database) })
                if storage?.databasePath.hasPrefix("/Volumes/") == true {
                    Label("The index is on another drive. A NAS share is unreliable for it; this Mac\u{2019}s disk is safer.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .pageForm()
        .task(id: model.config) { await measure() }
        // Back from System Settings (Spotlight's Search Privacy, say): measured again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await measure() }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
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

    func choose(_ target: Target) {
        choosing = target
        picking = true
    }

    func measure() async {
        await model.refreshStorageOutlook()
    }

    /// How many of the drive's checks fail.
    static func problems(_ drive: DriveFacts) -> Int {
        let journalless = ["exfat", "fat", "ms-dos"].contains { drive.format.lowercased().contains($0) }
        return (drive.isStartupDisk ? 1 : 0) + (!drive.isStartupDisk && drive.spotlightIndexing == true ? 1 : 0) + (journalless ? 1 : 0)
    }

    /// The drive's checks, folded into one row (as the camera settings' folds: the whole row opens it, and the checks
    /// come in under it): what's wrong (open), or that all is well (closed).
    @ViewBuilder
    func checklist(_ drive: DriveFacts) -> some View {
        let startupDisk = drive.isStartupDisk
        let indexed = startupDisk ? false : drive.spotlightIndexing
        let journalless = ["exfat", "fat", "ms-dos"].contains { drive.format.lowercased().contains($0) }
        let problems = Self.problems(drive)
        let open = checklistOpen ?? (problems > 0)
        Button {
            withAnimation(.snappy(duration: 0.3)) { checklistOpen = !open }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12)
                CheckRow(ok: problems == 0,
                         title: problems == 0 ? "The drive suits recording" : problems == 1 ? "1 thing to check on the drive" : "\(problems) things to check on the drive",
                         detail: problems == 0 && !open ? Self.summary(drive) : nil)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "open" : "closed")
        if open {
            Group {
                CheckRow(ok: !startupDisk,
                         title: startupDisk ? "On this Mac\u{2019}s startup disk" : "On \(drive.name), \(drive.isInternal ? "an internal" : "an external") drive",
                         detail: startupDisk ? "Recordings take space from everything else on this Mac. A drive of their own is better." : nil)
                if !startupDisk {
                    switch indexed {
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
                if journalless {
                    CheckRow(ok: false, title: "Formatted as \(drive.format)",
                             detail: "\(drive.format) keeps no journal, so a drive unplugged without ejecting can lose its latest recordings. APFS is safer for a drive used only for recordings.")
                } else if !drive.format.isEmpty {
                    CheckRow(ok: true, title: "Formatted as \(drive.format)")
                }
            }
            .padding(.leading, FoldRow.indent)
        }
    }

    /// The drive in a few words, all well.
    static func summary(_ drive: DriveFacts) -> String {
        var words = ["\(drive.name), \(drive.isInternal ? "internal" : "external")"]
        if !drive.format.isEmpty { words.append(drive.format) }
        if drive.spotlightIndexing == false { words.append("not indexed by Spotlight") }
        return words.joined(separator: " \u{00B7} ")
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
    /// What it is, under its path (when it has no state to show there).
    var caption: String?
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
                    if let caption { Text(caption).font(.callout).foregroundStyle(.secondary) }
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
