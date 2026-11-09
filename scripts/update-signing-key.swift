#!/usr/bin/env swift

// The project's own signing key for release manifests.
//
// Apple's Developer ID is one way to prove who published a build; a keypair the
// project owns is another, and it costs nothing. What the updater needs is not
// Apple's opinion of the publisher, it is a signature it can verify offline
// against a key that ships inside the app.
//
//   swift scripts/update-signing-key.swift generate
//   swift scripts/update-signing-key.swift public-key
//   swift scripts/update-signing-key.swift sign dist/SHA256SUMS
//
// The private key is a 32-byte Ed25519 seed, base64-encoded, one line. Keep it
// out of the repository (`.secrets/` is ignored) and put the same string into
// the `UPDATE_SIGNING_KEY` secret for CI. Losing it is survivable but not free:
// a new key means shipping one build that trusts both, then dropping the old.

import CryptoKit
import Foundation

let keyPath = ".secrets/update-signing-key"

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    print(message)
}

func readKey(at path: String) -> Curve25519.Signing.PrivateKey {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        die("cannot read \(path); run `swift scripts/update-signing-key.swift generate` first")
    }
    guard let bytes = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          bytes.count == 32 else {
        die("\(path) does not hold a base64-encoded 32-byte Ed25519 seed")
    }
    do {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    } catch {
        die("\(path) is not a usable Ed25519 key: \(error)")
    }
}

/// `--key <path>` overrides the default location, which CI does not use: there
/// the secret is written to a temporary file by the workflow.
func overrideKeyPath() -> String {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--key"), index + 1 < arguments.count else {
        return keyPath
    }
    return arguments[index + 1]
}

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "help"

switch command {
case "generate":
    let path = overrideKeyPath()
    let manager = FileManager.default
    if manager.fileExists(atPath: path) && !arguments.contains("--force") {
        die("\(path) already exists; pass --force to replace it (the old key can no longer sign)")
    }
    try? manager.createDirectory(
        at: URL(fileURLWithPath: path).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let key = Curve25519.Signing.PrivateKey()
    let encoded = key.rawRepresentation.base64EncodedString() + "\n"
    guard manager.createFile(atPath: path, contents: Data(encoded.utf8), attributes: [
        .posixPermissions: 0o600
    ]) else {
        die("cannot write \(path)")
    }
    note("private key: \(path) (chmod 600, ignored by git)")
    note("public key:  \(key.publicKey.rawRepresentation.base64EncodedString())")
    note("")
    note("Put the public key into apps/macos/Sources/OpenSVNCore/Support/UpdateSigningKey.swift,")
    note("and the private key (the file's single line) into the UPDATE_SIGNING_KEY secret.")

case "public-key":
    let key = readKey(at: overrideKeyPath())
    note(key.publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count > 2, !arguments[2].hasPrefix("--") else {
        die("usage: swift scripts/update-signing-key.swift sign <file> [--key <path>]")
    }
    let target = URL(fileURLWithPath: arguments[2])
    guard let payload = try? Data(contentsOf: target) else {
        die("cannot read \(target.path)")
    }
    let key = readKey(at: overrideKeyPath())
    let signature = try key.signature(for: payload)
    let output = URL(fileURLWithPath: target.path + ".sig")
    guard (try? Data((signature.base64EncodedString() + "\n").utf8).write(to: output)) != nil else {
        die("cannot write \(output.path)")
    }
    note("signed \(target.path) -> \(output.path)")

case "verify":
    guard arguments.count > 2 else { die("usage: … verify <file> [--key <path>]") }
    let target = URL(fileURLWithPath: arguments[2])
    guard let payload = try? Data(contentsOf: target),
          let raw = try? String(contentsOfFile: target.path + ".sig", encoding: .utf8),
          let signature = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        die("cannot read \(target.path) and its .sig")
    }
    let key = readKey(at: overrideKeyPath())
    if key.publicKey.isValidSignature(signature, for: payload) {
        note("signature is valid")
    } else {
        die("signature does not match \(target.path)")
    }

default:
    note("""
    usage: swift scripts/update-signing-key.swift <command> [arguments]

      generate [--key <path>] [--force]   create a keypair; prints the public key
      public-key [--key <path>]           print the public key for the baked-in list
      sign <file> [--key <path>]          write <file>.sig (base64 Ed25519)
      verify <file> [--key <path>]        check <file> against <file>.sig
    """)
}
