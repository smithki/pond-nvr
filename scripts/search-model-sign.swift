// Signs a published version of search's model for pond.camera's manifest, with the model signing key (Ed25519):
// Pond accepts a version only if its entry's signature verifies with the public key it carries
// (docs/search.md, Published versions; docs/ci-security.md). What's signed is the entry's fields, one per line in
// this order, so no JSON formatting can change it:
//
//   pond search model
//   id: siglip2-v1
//   name: SigLIP 2 base
//   format: 1
//   minimumApp: 0.2.0
//   size: 401234567
//   sha256: …
//
//   swift scripts/search-model-sign.swift new-key        a new key: the private key (base64) on stdout, for a
//                                                         password manager; its public key on stderr, for Pond
//   swift scripts/search-model-sign.swift sign ENTRY      the signature (base64) of ENTRY (a JSON file of those
//                                                         fields), with the key in MODEL_SIGNING_KEY (base64)
//   swift scripts/search-model-sign.swift verify ENTRY PUBLIC SIGNATURE
import CryptoKit
import Foundation

struct Entry: Decodable {
    let id: String, name: String, format: Int, minimumApp: String, size: Int, sha256: String

    var signed: Data {
        Data(["pond search model", "id: \(id)", "name: \(name)", "format: \(format)", "minimumApp: \(minimumApp)",
              "size: \(size)", "sha256: \(sha256)"].joined(separator: "\n").utf8)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

func entry(_ path: String) -> Entry {
    guard let data = FileManager.default.contents(atPath: path) else { fail("Can't read \(path).") }
    do { return try JSONDecoder().decode(Entry.self, from: data) } catch { fail("\(path) isn't an entry: \(error)") }
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "new-key":
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString(), terminator: "")
    FileHandle.standardError.write(Data("public key: \(key.publicKey.rawRepresentation.base64EncodedString())\n".utf8))
case "sign" where arguments.count == 2:
    guard let encoded = ProcessInfo.processInfo.environment["MODEL_SIGNING_KEY"], !encoded.isEmpty else {
        fail("MODEL_SIGNING_KEY isn't set.")
    }
    guard let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("MODEL_SIGNING_KEY isn't an Ed25519 private key in base64.")
    }
    print(try key.signature(for: entry(arguments.last!).signed).base64EncodedString())
case "verify" where arguments.count == 4:
    let parts = Array(arguments)
    guard let raw = Data(base64Encoded: parts[2]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let signature = Data(base64Encoded: parts[3]) else { fail("A public key and a signature, in base64.") }
    guard key.isValidSignature(signature, for: entry(parts[1]).signed) else { fail("The signature doesn't verify.") }
    print("✓ verified")
default:
    fail("usage: search-model-sign.swift new-key | sign ENTRY | verify ENTRY PUBLIC SIGNATURE")
}
