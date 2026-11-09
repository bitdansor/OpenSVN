import Foundation

/// Keys that may sign a release manifest.
///
/// This is the free half of the update trust model. A Developer ID certificate
/// costs money every year and only proves that Apple once verified a name; what
/// the updater actually needs is proof that *this project* published the bytes,
/// verified offline. An Ed25519 key does that for nothing, and it can be kept
/// off the machines that build the app.
///
/// Generate with `swift scripts/update-signing-key.swift generate`, paste the
/// printed public key here, and put the private half into the
/// `UPDATE_SIGNING_KEY` CI secret. The keys live in the binary on purpose: a key
/// fetched over the network would be signed by the thing it is meant to verify.
public enum UpdateSigningKey {
    /// A list, not a single key, because rotation needs an overlap: ship a build
    /// that trusts the old and the new key, publish with the new one, and only
    /// then drop the old entry.
    public static let trustedPublicKeysBase64: [String] = [
        "DdsWtGmQ6wZOXZwJrbb37EV28DR5Skr274hF85ERGb4="
    ]

    /// Whether this build can verify a manifest at all. `false` is a normal
    /// state for a fork that has not generated a key, and the UI says so instead
    /// of pretending the release cannot be trusted for some other reason.
    public static var isConfigured: Bool {
        !trustedPublicKeysBase64.isEmpty
    }
}
