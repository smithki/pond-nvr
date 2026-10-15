import Foundation
import NVRCore
import NVRMac
import Testing

// Uses its own Keychain service so it never touches real camera passwords.
@Suite(.serialized) struct KeychainCredentialStoreTests {
    let store = KeychainCredentialStore(service: "pond-tests-\(UUID().uuidString)")

    @Test func setReadUpdateRemove() throws {
        defer { try? store.removePassword(for: "porch") }
        #expect(try store.password(for: "porch") == nil)
        try store.setPassword("first p@ss \"quoted\"", for: "porch")
        #expect(try store.password(for: "porch") == "first p@ss \"quoted\"")
        try store.setPassword("second", for: "porch")
        #expect(try store.password(for: "porch") == "second")
        try store.removePassword(for: "porch")
        #expect(try store.password(for: "porch") == nil)
        try store.removePassword(for: "porch")   // removing again is fine
    }

    @Test func moveFollowsAnIdChange() throws {
        defer {
            try? store.removePassword(for: "cam-50-41")
            try? store.removePassword(for: "porch")
        }
        try store.setPassword("secret", for: "cam-50-41")
        try store.movePassword(from: "cam-50-41", to: "porch")
        #expect(try store.password(for: "porch") == "secret")
        #expect(try store.password(for: "cam-50-41") == nil)
    }
}
