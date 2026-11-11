// Updates of Pond itself, by Sparkle (docs/release.md, Updates): it asks pond.camera's appcast (Info.plist's SUFeedURL)
// for a newer version, offers it with its notes, and installs it only if it's signed with Pond's update key
// (SUPublicEDKey) and with the same Developer ID as this copy. Nothing about the Mac is sent with a check
// (SUEnableSystemProfiling off). Check for Updates… is in the Pond menu; checking by itself, in Settings › Advanced.
//
// Not in a demo, and not in a copy of Pond without the feed and key in its Info.plist (one run from swift build).
// After an update, the recorder is restarted on the new copy (restartRecorderIfOutOfDate).
import AppKit
import Combine
import Darwin
import PondCore
import Sparkle
import SwiftUI

@MainActor
final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    /// Whether this copy of Pond can be updated: a whole app, with its feed and key, and not a demo.
    let available: Bool
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private var watching: AnyCancellable?

    private override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        available = !AppDefaults.isDemo && Bundle.main.bundlePath.hasSuffix(".app")
            && !((info["SUFeedURL"] as? String) ?? "").isEmpty && !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
        super.init()
        guard available else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        watching = controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] can in self?.canCheck = can }
    }

    func check() {
        controller?.checkForUpdates(nil)
    }

    /// Whether it checks by itself (daily), Sparkle's own setting.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// When it last checked, if it has.
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}

extension AppModel {
    /// The recorder still running the pond this app was before an update (or a make app): restarted on this one's.
    /// Once a launch, when the service is first seen running: its program is this app's own pond, and that file is
    /// newer than the process.
    func restartRecorderIfOutOfDate() {
        guard !checkedRecorderCopy, case let .running(pid) = serviceState, let helperPath, let pid = Int32(pid) else { return }
        checkedRecorderCopy = true
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return }
        let program = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let running = URL(fileURLWithPath: program).resolvingSymlinksInPath().path
        guard running == URL(fileURLWithPath: helperPath).resolvingSymlinksInPath().path else { return }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return }
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
        let replaced = (try? FileManager.default.attributesOfItem(atPath: helperPath)[.modificationDate] as? Date) ?? .distantPast
        if replaced > started.addingTimeInterval(1) { restartService() }
    }
}

/// Check for Updates…, ready when Sparkle is (not while it's checking or installing).
struct CheckForUpdatesButton: View {
    @ObservedObject var updates: Updates

    var body: some View {
        Button("Check for Updates\u{2026}") { updates.check() }
            .disabled(!updates.canCheck)
    }
}

/// Settings › Advanced: whether Pond checks for new versions of itself, and Check Now.
struct UpdatesSection: View {
    @ObservedObject var updates = Updates.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { updates.checksAutomatically }, set: { updates.checksAutomatically = $0 })) {
                Text("Check for updates automatically")
                Text(updates.lastCheck.map { "Pond asks pond.camera daily for a new version and offers it with what\u{2019}s new. Last checked \(SearchModelRow.day($0, capital: false))." }
                     ?? "Pond asks pond.camera daily for a new version and offers it with what\u{2019}s new.")
            }
            LabeledContent("A new version of Pond") {
                Button("Check Now") { updates.check() }.disabled(!updates.canCheck)
            }
        } header: {
            Text("Updates")
        }
    }
}
