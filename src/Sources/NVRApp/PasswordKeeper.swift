// Camera passwords, as the app handles them: only pond (the command line tool, which is also the background
// service) reads or writes them in the Keychain, so the Keychain knows one program and never asks the user
// to let another in. The app saves, moves and removes them by running pond, the password on its standard
// input (never in its arguments), and tells whether one is there without reading it. Checks of a saved
// camera run in pond too (`pond camera test ID --json`); live view comes through the service.
import Foundation
import Ingest
import NVRCore
import NVRMac

protocol PasswordKeeper: Sendable {
    func save(_ password: String, for id: String) throws
    func remove(for id: String) throws
    func move(from id: String, to newID: String) throws
    /// Whether there is one, without reading it.
    func has(_ id: String) -> Bool
    /// The camera checked with its saved password (and these settings, which may not be saved yet), by pond;
    /// nil if pond couldn't be run.
    func check(_ camera: Config.Camera, seconds: Double) -> Result<ProbeReport, RTSPError>?
    /// Has pond ask a saved camera what it is, keeping the answer in the settings.
    /// Asks the camera what it is (and keeps it), through `provider` if given ("reolink", "onvif").
    func identify(_ id: String, provider: String?)
}

struct KeeperError: Error, CustomStringConvertible {
    var description: String
}

/// The real one: runs the pond inside the app.
struct HelperPasswordKeeper: PasswordKeeper {
    let helper: String?
    let configPath: String

    func save(_ password: String, for id: String) throws {
        try run(["camera", "password", id, "--password-stdin", "--no-test"], input: password)
    }

    func remove(for id: String) throws {
        try run(["camera", "password", id, "--remove"])
    }

    func move(from id: String, to newID: String) throws {
        try run(["camera", "password", id, "--move-to", newID])
    }

    func has(_ id: String) -> Bool {
        KeychainCredentialStore().hasPassword(for: id)
    }

    func check(_ camera: Config.Camera, seconds: Double) -> Result<ProbeReport, RTSPError>? {
        guard let output = try? run(["camera", "test", camera.id, "--seconds", String(Int(seconds)), "--json",
                                     "--main", camera.main, "--sub", camera.sub, "--username", camera.username]),
              let outcome = try? JSONDecoder().decode(ProbeOutcome.self, from: Data(output.utf8)) else { return nil }
        return outcome.result
    }

    func identify(_ id: String, provider: String?) {
        _ = try? run(["camera", "identify", id] + (provider.map { ["--provider", $0] } ?? []))
    }

    /// Runs pond with these arguments (and the settings file the app uses); its output, or its error in words.
    @discardableResult
    func run(_ arguments: [String], input: String? = nil) throws -> String {
        guard let helper else { throw KeeperError(description: "Pond\u{2019}s command line tool is missing from the app.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["--config", configPath] + arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw KeeperError(description: text.hasPrefix("✗ ") ? String(text.dropFirst(2)) : text)
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// For tests: a store of its own, and a stand-in check.
struct StorePasswordKeeper: PasswordKeeper {
    let store: CredentialStore
    var probe: @Sendable (Config.Camera) -> Result<ProbeReport, RTSPError>? = { _ in nil }

    func save(_ password: String, for id: String) throws { try store.setPassword(password, for: id) }
    func remove(for id: String) throws { try store.removePassword(for: id) }
    func move(from id: String, to newID: String) throws { try store.movePassword(from: id, to: newID) }
    func has(_ id: String) -> Bool { ((try? store.password(for: id)) ?? nil) != nil }
    func check(_ camera: Config.Camera, seconds: Double) -> Result<ProbeReport, RTSPError>? { probe(camera) }
    func identify(_ id: String, provider: String?) {}
}
