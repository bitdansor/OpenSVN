import CryptoKit
import Foundation
import Testing
@testable import OpenSVNCore

// The free trust anchor: a digest list signed by a key this project owns. These
// tests cover the two things that must never be lenient — parsing the list, and
// deciding whether a signature is valid — plus the rule that a signature, once
// verified, still has to name *this* archive with the digest the feed reported.

@Suite("release manifest parsing")
struct UpdateManifestParsingTests {
    @Test("shasum output is read into a digest table")
    func plain() throws {
        let hex = String(repeating: "ab", count: 32)
        let manifest = try #require(UpdateManifest.parse(Data("\(hex)  app.zip\n".utf8)))
        #expect(manifest.digest(forAssetNamed: "app.zip") == hex)
    }

    @Test("the binary marker, comments and blank lines are tolerated")
    func markersAndComments() throws {
        let one = String(repeating: "11", count: 32)
        let two = String(repeating: "22", count: 32)
        let text = """
        # sha256 sums for v1.0.0

        \(one) *app.zip
        \(two)\tnotes.txt
        """
        let manifest = try #require(UpdateManifest.parse(Data(text.utf8)))
        #expect(manifest.digest(forAssetNamed: "app.zip") == one)
        #expect(manifest.digest(forAssetNamed: "notes.txt") == two)
    }

    @Test("uppercase digests are lowercased to the form the hasher produces")
    func uppercase() throws {
        let hex = String(repeating: "AB", count: 32).uppercased()
        let manifest = try #require(UpdateManifest.parse(Data("\(hex)  app.zip\n".utf8)))
        #expect(manifest.digest(forAssetNamed: "app.zip") == hex.lowercased())
    }

    @Test("a line without a usable digest is skipped, not guessed at")
    func malformedLines() {
        let text = """
        not-a-digest  app.zip
        \(String(repeating: "ab", count: 32))  
        \(String(repeating: "cd", count: 32))  good.zip
        """
        let manifest = UpdateManifest.parse(Data(text.utf8))
        #expect(manifest?.digests.count == 1)
        #expect(manifest?.digest(forAssetNamed: "good.zip") != nil)
    }

    @Test("an empty or non-UTF8 file is not a manifest")
    func rejects() {
        #expect(UpdateManifest.parse(Data()) == nil)
        #expect(UpdateManifest.parse(Data("# nothing here\n".utf8)) == nil)
        #expect(UpdateManifest.parse(Data([0xff, 0xfe, 0xfd])) == nil)
    }

    @Test("an unknown name is nil, never a neighbouring digest")
    func lookupMiss() throws {
        let hex = String(repeating: "ab", count: 32)
        let manifest = try #require(UpdateManifest.parse(Data("\(hex)  app.zip\n".utf8)))
        #expect(manifest.digest(forAssetNamed: "other.zip") == nil)
        // Case is the one difference that is safe to forgive; the bytes are not.
        #expect(manifest.digest(forAssetNamed: "APP.ZIP") == hex)
    }
}

@Suite("release manifest signatures")
struct UpdateSignatureTests {
    @Test("a signature from a trusted key verifies")
    func valid() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("payload".utf8)
        let signature = try key.signature(for: payload).base64EncodedString()
        let trusted = [key.publicKey.rawRepresentation.base64EncodedString()]
        #expect(UpdateSignatureVerifier.isValidSignature(
            signatureBase64: signature,
            manifest: payload,
            publicKeysBase64: trusted
        ))
    }

    @Test("changed bytes, another key, or a truncated signature all fail")
    func invalid() throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let payload = Data("payload".utf8)
        let signature = try key.signature(for: payload).base64EncodedString()
        let trusted = [key.publicKey.rawRepresentation.base64EncodedString()]

        // One byte different: the manifest was edited after signing.
        #expect(!UpdateSignatureVerifier.isValidSignature(
            signatureBase64: signature,
            manifest: Data("payloaD".utf8),
            publicKeysBase64: trusted
        ))
        // Right shape, wrong publisher.
        #expect(!UpdateSignatureVerifier.isValidSignature(
            signatureBase64: signature,
            manifest: payload,
            publicKeysBase64: [other.publicKey.rawRepresentation.base64EncodedString()]
        ))
        // 63 bytes cannot be an Ed25519 signature.
        #expect(!UpdateSignatureVerifier.isValidSignature(
            signatureBase64: Data(repeating: 0, count: 63).base64EncodedString(),
            manifest: payload,
            publicKeysBase64: trusted
        ))
        #expect(!UpdateSignatureVerifier.isValidSignature(
            signatureBase64: "not base64",
            manifest: payload,
            publicKeysBase64: trusted
        ))
        // No keys at all: nothing can verify, and that is not a pass.
        #expect(!UpdateSignatureVerifier.isValidSignature(
            signatureBase64: signature,
            manifest: payload,
            publicKeysBase64: []
        ))
    }

    @Test("garbage in the trusted list is skipped without crashing")
    func badKeys() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("payload".utf8)
        let signature = try key.signature(for: payload).base64EncodedString()
        let trusted = [
            "short",
            Data(repeating: 7, count: 32).base64EncodedString(),
            key.publicKey.rawRepresentation.base64EncodedString()
        ]
        #expect(UpdateSignatureVerifier.isValidSignature(
            signatureBase64: signature,
            manifest: payload,
            publicKeysBase64: trusted
        ))
    }

    @Test("a signature file with a trailing newline still verifies")
    func newline() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("payload".utf8)
        let signature = try key.signature(for: payload).base64EncodedString() + "\n"
        #expect(UpdateSignatureVerifier.isValidSignature(
            signatureBase64: signature,
            manifest: payload,
            publicKeysBase64: [key.publicKey.rawRepresentation.base64EncodedString()]
        ))
    }
}

@Suite("release manifest loading")
struct UpdateManifestLoaderTests {
    private static let archiveName = "OpenSVN-1.0.0-macos-arm64.zip"
    private static let archiveDigest = String(repeating: "9f", count: 32)

    private func loader(
        manifest: Data,
        signature: String,
        keys: [String]
    ) -> UpdateManifestLoader {
        UpdateManifestLoader(
            fetch: { url in
                url.lastPathComponent == "SHA256SUMS" ? manifest : Data(signature.utf8)
            },
            publicKeys: keys
        )
    }

    @Test("a verified manifest yields the archive's digest")
    func verified() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let text = "\(Self.archiveDigest)  \(Self.archiveName)\n"
        let manifest = Data(text.utf8)
        let signature = try key.signature(for: manifest).base64EncodedString() + "\n"
        let version = try #require(AppVersion("1.0.0"))
        let package = UpdatePackage(
            version: version,
            tag: "v1.0.0",
            archive: UpdateAsset(
                name: Self.archiveName,
                url: URL(string: "https://example.com/app.zip")!
            ),
            manifest: UpdateAsset(name: "SHA256SUMS", url: URL(string: "https://example.com/SHA256SUMS")!),
            manifestSignature: UpdateAsset(name: "SHA256SUMS.sig", url: URL(string: "https://example.com/SHA256SUMS.sig")!)
        )
        let digest = try await loader(
            manifest: manifest,
            signature: signature,
            keys: [key.publicKey.rawRepresentation.base64EncodedString()]
        ).verifiedDigest(for: package)
        #expect(digest == Self.archiveDigest)
    }

    @Test("a tampered manifest is refused before its digest is used")
    func tampered() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let signedText = "\(Self.archiveDigest)  \(Self.archiveName)\n"
        let manifest = Data(signedText.utf8)
        let signature = try key.signature(for: manifest).base64EncodedString()
        let version = try #require(AppVersion("1.0.0"))
        let package = UpdatePackage(
            version: version,
            tag: "v1.0.0",
            archive: UpdateAsset(name: Self.archiveName, url: URL(string: "https://example.com/app.zip")!),
            manifest: UpdateAsset(name: "SHA256SUMS", url: URL(string: "https://example.com/SHA256SUMS")!),
            manifestSignature: UpdateAsset(name: "SHA256SUMS.sig", url: URL(string: "https://example.com/SHA256SUMS.sig")!)
        )
        // Someone replaced the digest in the file but kept the signature.
        let edited = Data((String(repeating: "00", count: 32) + "  \(Self.archiveName)\n").utf8)
        let loader = UpdateManifestLoader(
            fetch: { url in url.lastPathComponent == "SHA256SUMS" ? edited : Data(signature.utf8) },
            publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()]
        )
        await #expect(throws: UpdateManifestError.signatureInvalid) {
            _ = try await loader.verifiedDigest(for: package)
        }
    }

    @Test("the signed digest has to name this archive")
    func notListed() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let version = try #require(AppVersion("1.0.0"))
        let manifest = Data(("\(Self.archiveDigest)  something-else.zip\n".utf8))
        let signature = try key.signature(for: manifest).base64EncodedString()
        let package = UpdatePackage(
            version: version,
            tag: "v1.0.0",
            archive: UpdateAsset(name: Self.archiveName, url: URL(string: "https://example.com/app.zip")!),
            manifest: UpdateAsset(name: "SHA256SUMS", url: URL(string: "https://example.com/SHA256SUMS")!),
            manifestSignature: UpdateAsset(name: "SHA256SUMS.sig", url: URL(string: "https://example.com/SHA256SUMS.sig")!)
        )
        let loader = UpdateManifestLoader(
            fetch: { url in url.lastPathComponent == "SHA256SUMS" ? manifest : Data(signature.utf8) },
            publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()]
        )
        await #expect(throws: UpdateManifestError.assetNotListed(Self.archiveName)) {
            _ = try await loader.verifiedDigest(for: package)
        }
    }

    @Test("a signed digest that disagrees with the feed is a refusal, not a choice")
    func conflict() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let version = try #require(AppVersion("1.0.0"))
        let manifest = Data(("\(Self.archiveDigest)  \(Self.archiveName)\n".utf8))
        let signature = try key.signature(for: manifest).base64EncodedString()
        // GitHub computed a different digest for the same upload. One of the two
        // is wrong, and there is no basis for deciding which.
        let package = UpdatePackage(
            version: version,
            tag: "v1.0.0",
            archive: UpdateAsset(
                name: Self.archiveName,
                url: URL(string: "https://example.com/app.zip")!,
                sha256: String(repeating: "00", count: 32)
            ),
            manifest: UpdateAsset(name: "SHA256SUMS", url: URL(string: "https://example.com/SHA256SUMS")!),
            manifestSignature: UpdateAsset(name: "SHA256SUMS.sig", url: URL(string: "https://example.com/SHA256SUMS.sig")!)
        )
        let loader = UpdateManifestLoader(
            fetch: { url in url.lastPathComponent == "SHA256SUMS" ? manifest : Data(signature.utf8) },
            publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()]
        )
        await #expect(throws: UpdateManifestError.self) {
            _ = try await loader.verifiedDigest(for: package)
        }
    }

    @Test("no trusted key and no manifest are distinct refusals")
    func missingPieces() async throws {
        let version = try #require(AppVersion("1.0.0"))
        let bare = UpdatePackage(
            version: version,
            tag: "v1.0.0",
            archive: UpdateAsset(name: Self.archiveName, url: URL(string: "https://example.com/app.zip")!)
        )
        await #expect(throws: UpdateManifestError.manifestMissing) {
            _ = try await UpdateManifestLoader(
                fetch: { _ in Data() },
                publicKeys: ["a"]
            ).verifiedDigest(for: bare)
        }

        let withManifest = UpdatePackage(
            version: version,
            tag: "v1.0.0",
            archive: UpdateAsset(name: Self.archiveName, url: URL(string: "https://example.com/app.zip")!),
            manifest: UpdateAsset(name: "SHA256SUMS", url: URL(string: "https://example.com/SHA256SUMS")!),
            manifestSignature: UpdateAsset(name: "SHA256SUMS.sig", url: URL(string: "https://example.com/SHA256SUMS.sig")!)
        )
        await #expect(throws: UpdateManifestError.noTrustedKey) {
            _ = try await UpdateManifestLoader(
                fetch: { _ in Data() },
                publicKeys: []
            ).verifiedDigest(for: withManifest)
        }
    }
}

@Suite("signed manifest release selection")
struct SignedManifestReleaseTests {
    private let json = """
    [{
      "tag_name": "v0.2.0",
      "html_url": "https://example.com/2",
      "prerelease": false,
      "draft": false,
      "assets": [
        {"name": "OpenSVN-0.2.0-macos-arm64.zip",
         "browser_download_url": "https://example.com/app.zip", "size": 8000},
        {"name": "SHA256SUMS",
         "browser_download_url": "https://example.com/SHA256SUMS", "size": 120},
        {"name": "SHA256SUMS.sig",
         "browser_download_url": "https://example.com/SHA256SUMS.sig", "size": 90}
      ]
    }]
    """

    @Test("a zip with no GitHub digest is installable when a signed manifest exists")
    func signedManifest() throws {
        let release = try #require(try GitHubReleaseFeed.parseReleases(Data(json.utf8)))
        let package = try #require(release.package)
        #expect(package.archive.sha256 == nil)
        #expect(package.hasSignedManifest)
        #expect(package.isInstallable)
    }

    @Test("a manifest without its signature proves nothing")
    func unsignedManifest() throws {
        // Same release, minus the `.sig` asset: the list is present but nothing
        // vouches for it, so it must not make the archive installable.
        let json = """
        [{
          "tag_name": "v0.2.0",
          "html_url": "https://example.com/2",
          "prerelease": false,
          "draft": false,
          "assets": [
            {"name": "OpenSVN-0.2.0-macos-arm64.zip",
             "browser_download_url": "https://example.com/app.zip", "size": 8000},
            {"name": "SHA256SUMS",
             "browser_download_url": "https://example.com/SHA256SUMS", "size": 120}
          ]
        }]
        """
        let release = try #require(try GitHubReleaseFeed.parseReleases(Data(json.utf8)))
        // No digest and no signature means nothing can check the archive, so it
        // is not even offered as an installable package — just manual download.
        #expect(release.archive == nil)
        #expect(release.package == nil)
    }
}
