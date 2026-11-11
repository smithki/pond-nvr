// Checks a disk image's Sparkle signature against Pond's update key's public half (macos/app/Info.plist's SUPublicEDKey),
// as every copy of Pond will before installing it: make release runs it, so a release signed with a key Pond doesn't
// trust (a mixed-up key in the Keychain or in CI) never goes out. Sparkle's signature is Ed25519's, of the whole file.
//
//   swift scripts/sparkle-verify.swift FILE SIGNATURE PUBLIC-KEY
import CryptoKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: sparkle-verify.swift FILE SIGNATURE PUBLIC-KEY\n".utf8))
    exit(2)
}
let parts = Array(arguments)
guard let data = FileManager.default.contents(atPath: parts[0]),
      let signature = Data(base64Encoded: parts[1]),
      let raw = Data(base64Encoded: parts[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
    FileHandle.standardError.write(Data("✗ A readable file, and a signature and public key in base64.\n".utf8))
    exit(1)
}
guard key.isValidSignature(signature, for: data) else {
    FileHandle.standardError.write(Data("✗ \(parts[0])'s Sparkle signature doesn't verify with the public key.\n".utf8))
    exit(1)
}
print("✓ verified")
