// The login service: `pond run` as a launchd agent (camera.pond.recorder) in the logged-in user's session, which is
// where the login Keychain with the camera passwords is available. It starts at login, and launchd starts
// it again if it exits.
import Foundation
import NVRCore

/// What `pond service` needs from launchd; tests replace it.
public protocol Launchd: Sendable {
    /// Loads and starts the agent from its plist.
    func bootstrap(plist: String) throws
    /// Stops and unloads it. Not an error if it was not loaded.
    func bootout(label: String) throws
    /// Restarts a loaded agent.
    func kickstart(label: String) throws
    /// launchd's description of the agent, or nil if it is not loaded.
    func describe(label: String) -> String?
}

public struct LaunchdError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public struct RealLaunchd: Launchd, Sendable {
    public init() {}

    var domain: String { "gui/\(getuid())" }

    @discardableResult
    func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public func bootstrap(plist: String) throws {
        let r = launchctl(["bootstrap", domain, plist])
        guard r.status == 0 else { throw LaunchdError(message: "launchctl bootstrap failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func bootout(label: String) throws {
        guard describe(label: label) != nil else { return }
        let r = launchctl(["bootout", "\(domain)/\(label)"])
        guard r.status == 0 else { throw LaunchdError(message: "launchctl bootout failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func kickstart(label: String) throws {
        let r = launchctl(["kickstart", "-k", "\(domain)/\(label)"])
        guard r.status == 0 else { throw LaunchdError(message: "launchctl kickstart failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public func describe(label: String) -> String? {
        let r = launchctl(["print", "\(domain)/\(label)"])
        return r.status == 0 ? r.output : nil
    }
}

public enum LaunchAgent {
    public static let label = Brand.serviceLabel

    public static var plistPath: String { NSString(string: "~/Library/LaunchAgents/\(label).plist").expandingTildeInPath }
    /// The service's log (a demo's own, in its folder).
    public static var logPath: String {
        Demo.folder.map { ($0 as NSString).appendingPathComponent(Brand.logName) }
            ?? NSString(string: Brand.logFolder + "/" + Brand.logName).expandingTildeInPath
    }
    /// What the process itself prints outside the log (a crash, for example).
    public static var outputPath: String { NSString(string: Brand.logFolder + "/" + Brand.outputLogName).expandingTildeInPath }

    public static func plist(program: String, configPath: String?) -> String {
        var arguments = [program, "run", "--log", logPath]
        if let configPath { arguments += ["--config", configPath] }
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \(arguments.map { "\t\t<string>\(escape($0))</string>" }.joined(separator: "\n"))
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>ThrottleInterval</key>
        \t<integer>10</integer>
        \t<key>ProcessType</key>
        \t<string>Standard</string>
        \t<key>StandardOutPath</key>
        \t<string>\(escape(outputPath))</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(escape(outputPath))</string>
        </dict>
        </plist>

        """
    }

    /// The facts `pond service status` shows, from `launchctl print`.
    public static func summary(_ description: String) -> (state: String?, pid: String?, lastExit: String?) {
        func value(_ key: String) -> String? {
            for line in description.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(key + " = ") { return String(t.dropFirst(key.count + 3)) }
            }
            return nil
        }
        return (value("state"), value("pid"), value("last exit code"))
    }
}


/// Installing, restarting and removing the login service; used by `pond service` and the app.
public struct ServiceControl: Sendable {
    public let launchd: Launchd
    /// Where the agent's plist goes: the real one in ~/Library/LaunchAgents, or a test's own (a test with a stand-in
    /// launchd must never write or remove the real file: the installed service would be gone at the next login).
    public let plistPath: String

    public init(launchd: Launchd, plistPath: String = LaunchAgent.plistPath) {
        self.launchd = launchd
        self.plistPath = plistPath
    }

    public enum State: Equatable, Sendable {
        case notInstalled
        case running(pid: String)
        case stopped(String)
    }

    public var state: State {
        guard let description = launchd.describe(label: LaunchAgent.label) else { return .notInstalled }
        let s = LaunchAgent.summary(description)
        if s.state == "running", let pid = s.pid { return .running(pid: pid) }
        return .stopped([s.state ?? "unknown state", s.lastExit.map { "last exit: \($0)" }].compactMap { $0 }.joined(separator: ", "))
    }

    /// Writes the agent's plist for `program` and (re)starts it.
    public func install(program: String, configPath: String?) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (LaunchAgent.logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try launchd.bootout(label: LaunchAgent.label)   // an older version, if any
        try Data(LaunchAgent.plist(program: program, configPath: configPath).utf8)
            .write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        // launchd stops the old one in the background, and refuses to load the new one until it has
        // ("Bootstrap failed: 5: Input/output error"): wait for it, and try once more if it still refuses.
        waitUntilUnloaded(seconds: 10)
        do {
            try launchd.bootstrap(plist: plistPath)
        } catch {
            Thread.sleep(forTimeInterval: 2)
            try launchd.bootstrap(plist: plistPath)
        }
    }

    private func waitUntilUnloaded(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while launchd.describe(label: LaunchAgent.label) != nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    public func uninstall() throws {
        try launchd.bootout(label: LaunchAgent.label)
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
    }

    public func restart() throws {
        try launchd.kickstart(label: LaunchAgent.label)
    }

    /// The last `count` lines of the service's log.
    public static func logTail(_ count: Int = 10) -> [String] {
        // Only the end of the file is read.
        guard let handle = FileHandle(forReadingAtPath: LaunchAgent.logPath) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 64 * 1024 ? size - 64 * 1024 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n").suffix(count).map(String.init)
    }
}
