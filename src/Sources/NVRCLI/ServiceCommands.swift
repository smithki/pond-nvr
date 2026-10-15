// pond service ...: the login service, through ServiceControl.
import Control
import Foundation
import NVRCore

extension CLI {
    func serviceCommand(_ args: inout Args) throws {
        let action = args.next()
        try args.done()
        switch action {
        case "install": try serviceInstall()
        case "uninstall": try serviceUninstall()
        case "restart": try serviceRestart()
        case nil, "status": serviceStatus()
        case let other?: throw UsageError("Unknown service command \(other). See: pond help")
        }
    }

    func serviceInstall() throws {
        guard let launchd else {
            console.err("✗ The login service needs macOS.")
            throw Failure()
        }
        // The service runs this same program, so it must stay where it is.
        let program = (executablePath as NSString).resolvingSymlinksInPath
        if program.contains("/dist/") || program.contains("/.build/") {
            console.err("! \(program) is a build output that the next build replaces. Install pond first (make install, which puts it in /usr/local/bin), then run: /usr/local/bin/pond service install")
        }
        // Check what `pond run` would check, so the service does not start only to fail.
        let config = try load()
        let problems = config.problems()
        guard problems.isEmpty, !config.cameras.isEmpty else {
            for p in problems { console.err("✗ \(p)") }
            if config.cameras.isEmpty { console.err("✗ There are no cameras. Add one with: pond camera add ID --host HOST") }
            throw Failure()
        }
        let configArgument = store.path == ConfigStore.defaultPath ? nil : store.path
        do {
            try ServiceControl(launchd: launchd).install(program: program, configPath: configArgument)
        } catch {
            console.err("✗ \(error)")
            throw Failure()
        }
        console.out("✓ \(LaunchAgent.plistPath)")
        console.out("✓ started; it starts again at every login, and if it stops")
        console.out("The log is \(LaunchAgent.logPath). If macOS asks whether pond may use the camera passwords in your Keychain, choose Always Allow.")
    }

    func serviceUninstall() throws {
        guard let launchd else {
            console.err("✗ The login service needs macOS.")
            throw Failure()
        }
        do {
            try ServiceControl(launchd: launchd).uninstall()
        } catch {
            console.err("✗ \(error)")
            throw Failure()
        }
        console.out("The login service is stopped and removed. Recordings and settings are untouched.")
    }

    func serviceRestart() throws {
        guard let launchd else {
            console.err("✗ The login service needs macOS.")
            throw Failure()
        }
        guard launchd.describe(label: LaunchAgent.label) != nil else {
            console.err("✗ The login service is not installed. Install it with: pond service install")
            throw Failure()
        }
        do {
            try ServiceControl(launchd: launchd).restart()
        } catch {
            console.err("✗ \(error)")
            throw Failure()
        }
        console.out("The login service restarted.")
    }

    func serviceStatus() {
        guard let launchd else {
            console.out("The login service is not installed. Install it with: pond service install")
            return
        }
        switch ServiceControl(launchd: launchd).state {
        case .notInstalled:
            console.out("The login service is not installed. Install it with: pond service install")
            return
        case let .running(pid):
            console.out("✓ running (process \(pid))")
        case let .stopped(why):
            console.err("! not running (\(why))")
        }
        let tail = ServiceControl.logTail()
        if !tail.isEmpty {
            console.out("Last lines of \(LaunchAgent.logPath):")
            for line in tail { console.out("  " + line) }
        }
    }
}
