// Camera passwords. The app keeps them in the Keychain (KeychainCredentialStore, in PondMac); the settings
// file has only usernames. Keyed by camera id.
import Foundation

public protocol CredentialStore: Sendable {
    func password(for cameraID: String) throws -> String?
    func setPassword(_ password: String, for cameraID: String) throws
    func removePassword(for cameraID: String) throws
}

extension CredentialStore {
    /// Moves a password when a camera's id changes. Does nothing if there is none.
    public func movePassword(from oldID: String, to newID: String) throws {
        guard oldID != newID, let password = try password(for: oldID) else { return }
        try setPassword(password, for: newID)
        try removePassword(for: oldID)
    }
}

/// For tests and previews.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var passwords: [String: String]

    public init(_ passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    public func password(for cameraID: String) -> String? { passwords[cameraID] }
    public func setPassword(_ password: String, for cameraID: String) { passwords[cameraID] = password }
    public func removePassword(for cameraID: String) { passwords[cameraID] = nil }
}

/// Secrets in a file (readable by this user only), by service and account: demo mode's, kept in its folder, so a
/// demo never touches the Keychain.
public final class FileCredentialStore: CredentialStore, @unchecked Sendable {
    public let path: String
    public let service: String
    private static let lock = NSLock()

    public init(path: String, service: String) {
        self.path = path
        self.service = service
    }

    private func read() -> [String: [String: String]] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    private func change(_ change: (inout [String: String]) -> Void) throws {
        try Self.lock.withLock {
            var all = read()
            change(&all[service, default: [:]])
            try JSONEncoder().encode(all).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    public func password(for account: String) -> String? { Self.lock.withLock { read()[service]?[account] } }
    public func setPassword(_ password: String, for account: String) throws { try change { $0[account] = password } }
    public func removePassword(for account: String) throws { try change { $0[account] = nil } }
}
