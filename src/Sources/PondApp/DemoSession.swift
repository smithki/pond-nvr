// The app in demo mode (`--demo [NAME]`): the scenario's world made (by `pond demo prepare`, which also pairs its
// Ponds), its settings used instead of the real ones, and its services run as the app's own child processes (its
// `pond run`, each other Pond's, and the signaling service between them) in place of the login service. The app's
// service controls work on those (DemoLaunchd stands in for launchd), so a demo can't touch the real service, and
// they stop when the app quits.
import Control
import Demo
import Devices
import Foundation
import PondCore
import SwiftUI

@MainActor
enum DemoSession {
    /// The scenario asked for at launch, made ready; nil when the app isn't in demo mode.
    static let scenario: Demo.Scenario? = {
        guard CommandLine.arguments.contains("--demo") else { return nil }
        let name = launchArgument("--demo").flatMap { $0.hasPrefix("-") ? nil : $0 } ?? Demo.Scenario.home.name
        guard let scenario = Demo.scenario(named: name), let pond = Bundle.main.path(forAuxiliaryExecutable: Brand.command) else { return nil }
        // Made (or kept as it was), and its Ponds paired.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pond)
        process.arguments = ["demo", "prepare", scenario.name]
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        Demo.adopt(configPath: Demo.configPath(scenario.name))
        // Its cameras' streams and make here too, for Add Camera's check of one found on its network (the service
        // has its own).
        DemoWorld.start(scenario, folder: nil)
        DemoStream.register()
        DemoProvider.register()
        return scenario
    }()

    /// The cameras on its network not set up yet, as discovery finds them.
    static var found: [FoundCamera] {
        guard let scenario else { return [] }
        return scenario.found.map { c in
            FoundCamera(host: c.host(in: scenario.name), name: c.name, hardware: c.model, maker: c.manufacturer,
                        mac: "demo:\(scenario.name):\(c.id)")
        }
    }

    static var configPath: String? { scenario.map { Demo.configPath($0.name) } }

    /// The service controls for the demo's own processes.
    static var serviceControl: ServiceControl? {
        scenario.map { ServiceControl(launchd: DemoLaunchd.shared(for: $0), plistPath: Demo.folder($0.name) + "/service.plist") }
    }

    /// Its processes stopped (the app is quitting).
    static func stop() { DemoLaunchd.current?.bootoutAll() }

    /// Another copy of the app opened in a scenario (from the real one: Settings › General), beside this one.
    static func open(_ scenario: Demo.Scenario) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath, "--args", "--demo", scenario.name]
        try? process.run()
    }

    /// The app opened again in another scenario (this one's services stopped as it quits).
    static func switchTo(_ next: Demo.Scenario) {
        guard next.name != scenario?.name, let app = Bundle.main.executablePath else { return }
        let process = Process()
        // A moment after this one's gone, so its services have let go of their ports.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 2; exec \"$0\" --demo \"$1\"", app, next.name]
        guard (try? process.run()) != nil else { return }
        AppDelegate.quit()
    }
}

/// launchd, as far as the app asks of it, for a demo: its processes started, stopped and described.
final class DemoLaunchd: Launchd, @unchecked Sendable {
    nonisolated(unsafe) static var current: DemoLaunchd?

    let scenario: Demo.Scenario
    let pond: String
    let signal: String?
    private let lock = NSLock()
    private var running: [String: Process] = [:]

    static func shared(for scenario: Demo.Scenario) -> DemoLaunchd {
        if let current, current.scenario == scenario { return current }
        let made = DemoLaunchd(scenario: scenario)
        current = made
        return made
    }

    init(scenario: Demo.Scenario) {
        self.scenario = scenario
        pond = Bundle.main.path(forAuxiliaryExecutable: Brand.command) ?? Brand.command
        signal = Bundle.main.path(forAuxiliaryExecutable: "pond-signal")
        Self.stopLeftovers(scenario)
        // Started with the app, as the login service would be already.
        startAll()
    }

    /// The processes a demo runs: by name, its program and arguments.
    var processes: [(name: String, program: String, arguments: [String])] {
        var out: [(String, String, [String])] = []
        if scenario.signaling != nil, let signal {
            out.append(("signal", signal, ["--port", "\(Demo.signalingPort)", "--stun", "\(Demo.signalingPort + 1)"]))
        }
        func run(_ pond: String?) -> [String] {
            let folder = Demo.folder(scenario.name, pond: pond)
            return ["run", "--config", folder + "/config.json", "--log", folder + "/" + Brand.logName]
        }
        out.append(("main", pond, run(nil)))
        // An unreachable Pond isn't running at all.
        if scenario.link != .unreachable {
            for other in scenario.ponds { out.append((other.name, pond, run(other.name))) }
        }
        return out
    }

    private static func pidsPath(_ scenario: Demo.Scenario) -> String { Demo.folder(scenario.name) + "/pids.json" }

    /// Processes left by a demo app that didn't quit cleanly, stopped.
    private static func stopLeftovers(_ scenario: Demo.Scenario) {
        guard let data = FileManager.default.contents(atPath: pidsPath(scenario)),
              let pids = try? JSONDecoder().decode([Int32].self, from: data) else { return }
        for pid in pids { kill(pid, SIGTERM) }
        // Gone before new ones start (10 s at most): one still stopping would take its sockets with it as it went,
        // the new one's by then.
        let deadline = Date().addingTimeInterval(10)
        while pids.contains(where: { kill($0, 0) == 0 }), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        try? FileManager.default.removeItem(atPath: pidsPath(scenario))
    }

    private func savePids() {
        let pids = lock.withLock { running.values.map(\.processIdentifier) }
        try? JSONEncoder().encode(pids).write(to: URL(fileURLWithPath: Self.pidsPath(scenario)))
    }

    func startAll() {
        for (name, program, arguments) in processes where lock.withLock({ running[name]?.isRunning != true }) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            lock.withLock { running[name] = process }
        }
        savePids()
    }

    func bootoutAll() {
        let all = lock.withLock { () -> [Process] in
            defer { running = [:] }
            return Array(running.values)
        }
        for process in all where process.isRunning { process.terminate() }
        for process in all { process.waitUntilExit() }
        try? FileManager.default.removeItem(atPath: Self.pidsPath(scenario))
    }

    // MARK: Launchd

    func bootstrap(plist: String) throws { startAll() }

    func bootout(label: String) throws { bootoutAll() }

    func kickstart(label: String) throws {
        bootoutAll()
        startAll()
    }

    func describe(label: String) -> String? {
        guard let main = lock.withLock({ running["main"] }) else { return nil }
        return main.isRunning ? "state = running\npid = \(main.processIdentifier)"
                              : "state = not running\nlast exit code = \(main.terminationStatus)"
    }
}

/// The toolbar's mark for demo mode: the scenario, and the others to switch to (the app opens again in that one, its
/// services with it).
struct DemoMenu: View {
    let current: Demo.Scenario

    var body: some View {
        Menu {
            Picker("Demo mode: made-up cameras, apart from your real setup",
                   selection: Binding(get: { current.name }, set: { name in Demo.scenario(named: name).map(DemoSession.switchTo) })) {
                ForEach(Demo.scenarios, id: \.name) { scenario in
                    Text(scenario.title).tag(scenario.name)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Demo: \(current.title)", systemImage: "theatermasks")
                .labelStyle(.titleAndIcon)
        }
        .tint(.orange)
        .help("Demo mode: \(current.about) Your real settings and recordings aren\u{2019}t touched.")
    }
}
