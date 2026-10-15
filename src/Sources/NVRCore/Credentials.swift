// Camera passwords. The app keeps them in the Keychain (KeychainCredentialStore, in NVRMac); the settings
// file has only usernames. Keyed by camera id.

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
