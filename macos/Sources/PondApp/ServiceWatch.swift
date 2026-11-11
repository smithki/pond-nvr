// The service, watched: whether Pond is recording, checked every half minute for as long as the app runs (its window
// open or not: with the menu bar item, closing the window leaves the app running; with Open at Login, it starts after
// a restart). When it stops (the recorder not installed or not running, its drive gone, or cameras that should be
// recording writing nothing), a notification says what's wrong and the fix; when it's fixed, the notification goes.
// A Mac that restarts unattended (a power cut, a panic) is the case: otherwise nobody knows until someone looks.
import AppKit
import Devices
import Foundation
import PondCore
import UserNotifications

@MainActor
@Observable
final class ServiceWatch {
    enum Problem: Equatable {
        case notInstalled
        case stopped(String)
        /// The recordings folder isn't there (a drive unplugged, a share unmounted): what it is now.
        case storage(String)
        /// Running, but these cameras (names) have written nothing for a while.
        case notRecording([String])

        var title: String {
            switch self {
            case .notInstalled: "Pond isn\u{2019}t recording"
            case .stopped: "Pond\u{2019}s recorder stopped"
            case .storage: "Pond can\u{2019}t record: its drive isn\u{2019}t there"
            case let .notRecording(names): names.count == 1 ? "\(names[0]) isn\u{2019}t being recorded" : "\(names.count) cameras aren\u{2019}t being recorded"
            }
        }

        var detail: String {
            switch self {
            case .notInstalled: "Its recorder isn\u{2019}t started. Open Pond and click Start in the overview (the toolbar\u{2019}s state)."
            case let .stopped(why): "It isn\u{2019}t running (\(why)). Open Pond to start it again."
            case let .storage(path): "The recordings folder \(path) isn\u{2019}t available. Plug the drive in (or mount the share); recording starts again by itself."
            case let .notRecording(names):
                "Nothing recorded for a few minutes from \(ListFormatter.localizedString(byJoining: names)). The doctor says why."
            }
        }

        /// Where it's looked into: the doctor's cameras, or its recorder page.
        var settingsPage: SettingsPage { if case .notRecording = self { .cameras } else { .recorder } }
    }

    /// What's wrong now, if anything.
    private(set) var problem: Problem?
    /// Other Ponds paired with this one that have gone quiet (by id): not recording, or not connected at all.
    private(set) var otherPonds: [String: Quiet] = [:]
    /// When each other Pond was first found not connected (it counts once that's lasted a check more).
    private var absentSince: [String: Date] = [:]

    /// Another Pond gone quiet, as said.
    struct Quiet: Equatable {
        var name: String
        var title: String
        var detail: String
    }
    private var told: Problem?
    private var task: Task<Void, Never>?
    static let notification = "pond.service"
    /// Notifications, in the app (not elsewhere, as in tests: outside an app bundle the centre throws).
    static var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }
    /// Nothing written for this long, while recording should be, counts as not recording.
    nonisolated static let staleAfter: TimeInterval = 3 * 60

    func start(_ model: AppModel) {
        guard task == nil else { return }
        Self.center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        task = Task { [weak self, weak model] in
            // (A moment first: at login the service may still be starting.)
            try? await Task.sleep(for: .seconds(20))
            var round = 0
            while !Task.isCancelled, let self, let model {
                model.refreshService()
                let now = await Self.check(model)
                self.update(now)
                // The other Ponds every five minutes (each asked over a session of its own, closed after).
                if round % 10 == 0, !model.otherPonds.isEmpty,
                   let found = await model.controlClient.ask(.init(camera: "", action: "remote.health"), timeout: 60).pondHealth {
                    self.update(others: found)
                }
                round += 1
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// What's wrong, as far as the app can tell: nothing while there's nothing to record.
    static func check(_ model: AppModel) async -> Problem? {
        guard let config = model.config, !config.cameras.isEmpty else { return nil }
        switch model.serviceState {
        case .notInstalled: return .notInstalled
        case let .stopped(why): return .stopped(why)
        case .running: break
        }
        let root = config.storage.recordingsPath
        guard StorageLocation.status(of: root).isReady else { return .storage((root as NSString).abbreviatingWithTildeInPath) }
        // Only cameras that should be recording, the service past its first minutes.
        guard let started = model.serviceStarted, Date().timeIntervalSince(started) > staleAfter else { return nil }
        let watched = config.cameras.filter { !model.isPrivate($0.id) }
        let silent = await Task.detached {
            watched.filter { camera in
                (latestWrite(root: root, camera: camera.id).map { Date().timeIntervalSince($0) > staleAfter }) ?? true
            }.map(\.name)
        }.value
        return silent.isEmpty ? nil : .notRecording(silent)
    }

    /// When a camera's recordings were last written to: its latest day's folders' newest file.
    nonisolated static func latestWrite(root: String, camera: String) -> Date? {
        let folder = "\(root)/continuous/\(camera)"
        let fm = FileManager.default
        guard let day = (try? fm.contentsOfDirectory(atPath: folder))?.filter({ !$0.hasPrefix(".") }).max() else { return nil }
        let dayFolder = "\(folder)/\(day)"
        return (try? fm.contentsOfDirectory(atPath: dayFolder))?
            .compactMap { (try? fm.attributesOfItem(atPath: "\(dayFolder)/\($0)"))?[.modificationDate] as? Date }
            .max()
    }

    /// The other Ponds as they answered: each told once when it goes quiet (or differently), its notification taken
    /// away once it's recording again. Not connected counts after two checks running (a blip isn't news); can't be
    /// reached though connected (no path) isn't "quiet", and isn't told.
    func update(others found: [ControlSocket.PondHealth]) {
        var now: [String: Quiet] = [:]
        for pond in found {
            if pond.absent {
                let since = absentSince[pond.id] ?? Date()
                absentSince[pond.id] = since
                if Date().timeIntervalSince(since) > 60 {
                    now[pond.id] = Quiet(name: pond.name, title: "\(pond.name) has gone quiet",
                                         detail: "It hasn\u{2019}t been connected since \(since.formatted(date: .omitted, time: .shortened)): its Mac may be off, or its internet down.")
                }
                continue
            }
            absentSince[pond.id] = nil
            guard pond.recording != nil, !pond.problems.isEmpty else { continue }
            let title = pond.recording == 0 ? "\(pond.name) isn\u{2019}t recording" : "\(pond.name): not every camera is being recorded"
            now[pond.id] = Quiet(name: pond.name, title: title, detail: pond.problems.joined(separator: "; ").prefix(1).uppercased()
                                 + pond.problems.joined(separator: "; ").dropFirst() + ".")
        }
        let center = Self.center
        for (id, quiet) in now where otherPonds[id] != quiet {
            let content = UNMutableNotificationContent()
            content.title = (DemoSession.scenario == nil ? "" : "Demo: ") + quiet.title
            content.body = quiet.detail
            content.sound = .default
            center?.add(UNNotificationRequest(identifier: "\(Self.notification).\(id)", content: content, trigger: nil))
        }
        let fixed = otherPonds.keys.filter { now[$0] == nil }.map { "\(Self.notification).\($0)" }
        if !fixed.isEmpty { center?.removeDeliveredNotifications(withIdentifiers: fixed) }
        otherPonds = now
    }

    /// Told once when something goes wrong (or goes wrong differently); the notification taken away once it's fixed.
    func update(_ now: Problem?) {
        problem = now
        guard now != told else { return }
        told = now
        let center = Self.center
        guard let now else {
            center?.removeDeliveredNotifications(withIdentifiers: [Self.notification])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = (DemoSession.scenario == nil ? "" : "Demo: ") + now.title
        content.body = now.detail
        content.sound = .default
        content.userInfo = ["doctor": now.settingsPage == .recorder ? "recorder" : "cameras"]
        center?.add(UNNotificationRequest(identifier: Self.notification, content: content, trigger: nil))
    }
}
