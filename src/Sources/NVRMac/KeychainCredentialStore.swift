// Camera passwords in the login Keychain: generic passwords with service "pond" (`Brand.keychainService`)
// and the camera id as the account. Visible in Keychain Access under "pond".
import Foundation
import NVRCore
import Security

public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = Brand.keychainService) {
        self.service = service
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public let action: String

        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain could not \(action): \(message)."
        }
    }

    private func query(_ cameraID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: cameraID]
    }

    public func password(for cameraID: String) throws -> String? {
        var q = query(cameraID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status, action: "read the password for \(cameraID)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether there is a password for the camera, without reading it: macOS asks for access only to read
    /// the secret, so this never prompts (the app checks this way; only pond reads passwords).
    public func hasPassword(for cameraID: String) -> Bool {
        var q = query(cameraID)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess
    }

    public func setPassword(_ password: String, for cameraID: String) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(cameraID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw KeychainError(status: status, action: "update the password for \(cameraID)")
        }
        var add = query(cameraID)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "\(service) camera \(cameraID)"
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added, action: "save the password for \(cameraID)") }
    }

    public func removePassword(for cameraID: String) throws {
        let status = SecItemDelete(query(cameraID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, action: "remove the password for \(cameraID)")
        }
    }
}
