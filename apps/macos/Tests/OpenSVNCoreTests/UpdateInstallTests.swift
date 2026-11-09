import Foundation
import Testing
@testable import OpenSVNCore

// The automatic update path is mostly refusals: a digest that does not match, a
// signature from another team, a bundle whose version is not the announced one.
// These tests pin those refusals. Nothing here replaces a real application: the
// swap script is generated and inspected, never run.

@Suite("update asset digests")
struct UpdateAssetDigestTests {
    @Test("a sha256 digest is read and lowercased")
    func sha256() {
        let hex = String(repeating: "a1", count: 32)
        #expect(UpdateAsset.parseDigest("sha256:\(hex)") == hex)
        #expect(UpdateAsset.parseDigest("SHA256:\(hex.uppercased())") == hex)
    }

    @Test("an algorithm this code cannot compute is not a digest")
    func otherAlgorithms() {
        let hex = String(repeating: "b2", count: 32)
        #expect(UpdateAsset.parseDigest("sha512:\(hex)") == nil)
        #expect(UpdateAsset.parseDigest("md5:\(hex)") == nil)
    }

    @Test("a missing or malformed digest is nil, not an empty string")
    func rejects() {
        #expect(UpdateAsset.parseDigest(nil) == nil)
        #expect(UpdateAsset.parseDigest("") == nil)
        #expect(UpdateAsset.parseDigest("sha256:") == nil)
        #expect(UpdateAsset.parseDigest("sha256:abc") == nil)
        #expect(UpdateAsset.parseDigest("sha256:\(String(repeating: "z", count: 64))") == nil)
        #expect(UpdateAsset.parseDigest("no-colon") == nil)
    }
}

@Suite("update package selection")
struct UpdatePackageSelectionTests {
    private let releaseWithDigest = """
    [{
      "tag_name": "v0.2.0",
      "html_url": "https://example.com/2",
      "prerelease": false,
      "draft": false,
      "assets": [
        {"name": "OpenSVN-0.2.0.dmg", "browser_download_url": "https://example.com/a.dmg", "size": 9000},
        {"name": "OpenSVN-0.2.0.zip", "browser_download_url": "https://example.com/a.zip",
         "size": 8000, "digest": "sha256:\(String(repeating: "cd", count: 32))"}
      ]
    }]
    """

    @Test("a zip with a digest becomes an installable package")
    func installable() throws {
        let release = try #require(try GitHubReleaseFeed.parseReleases(Data(releaseWithDigest.utf8)))
        #expect(release.downloadURL?.lastPathComponent == "a.dmg")
        let package = try #require(release.package)
        #expect(package.archive.name == "OpenSVN-0.2.0.zip")
        #expect(package.archive.byteCount == 8000)
        #expect(package.isInstallable)
        #expect(package.version == AppVersion("0.2.0"))
    }

    @Test("a zip without a digest is a manual download, not an automatic one")
    func unverifiableZip() throws {
        let json = """
        [{"tag_name": "v0.2.0", "html_url": "https://example.com/2", "prerelease": false, "draft": false,
          "assets": [{"name": "OpenSVN-0.2.0.zip", "browser_download_url": "https://example.com/a.zip"}]}]
        """
        let release = try #require(try GitHubReleaseFeed.parseReleases(Data(json.utf8)))
        #expect(release.package == nil)
        // The manual URL is unaffected: a release with no digest is still a
        // legitimate thing to download by hand.
        #expect(release.downloadURL?.lastPathComponent == "a.zip")
    }

    @Test("a tag that is not a version cannot be installed even with a digest")
    func nonVersionTag() throws {
        let json = """
        [{"tag_name": "nightly", "html_url": "https://example.com/n", "prerelease": false, "draft": false,
          "assets": [{"name": "nightly.zip", "browser_download_url": "https://example.com/n.zip",
                      "digest": "sha256:\(String(repeating: "ef", count: 32))"}]}]
        """
        let release = try #require(try GitHubReleaseFeed.parseReleases(Data(json.utf8)))
        #expect(release.package == nil)
    }
}

@Suite("file digests")
struct UpdateFileDigestTests {
    @Test("SHA-256 matches the known value for a small file")
    func knownValue() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try UpdateDigest.sha256(of: file)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("a file larger than one chunk is hashed completely")
    func multiChunk() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        // 3 MiB of a repeating byte: crosses the 1 MiB read boundary twice.
        let size = 3 * 1024 * 1024
        try Data(repeating: 0x41, count: size).write(to: file)
        let digest = try UpdateDigest.sha256(of: file)
        #expect(digest.count == 64)
        #expect(digest == (try UpdateDigest.sha256(of: file)))
    }
}

@Suite("update helper script")
struct UpdateHelperScriptTests {
    private let source = URL(fileURLWithPath: "/tmp/staging/OpenSVN.app")
    private let destination = URL(fileURLWithPath: "/Applications/OpenSVN.app")

    private func script(relaunch: Bool = true) -> String {
        UpdateInstaller.helperScript(
            pid: 4242,
            source: source,
            destination: destination,
            backup: destination.appendingPathExtension("previous"),
            relaunch: relaunch
        )
    }

    @Test("waits for the old process before touching the bundle")
    func waitsForExit() throws {
        let text = script()
        let wait = try #require(text.range(of: "kill -0 \"$pid\""))
        let copy = try #require(text.range(of: "/usr/bin/ditto"))
        #expect(wait.lowerBound < copy.lowerBound)
        #expect(text.contains("pid=4242"))
    }

    @Test("moves the old bundle aside instead of deleting it first")
    func keepsBackup() {
        let text = script()
        #expect(text.contains("/bin/mv \"$dst\" \"$backup\""))
        // The backup has to exist before the final move, and is only removed
        // after the relaunch attempt.
        #expect(text.contains("*.previous"))
        #expect(text.contains("/usr/bin/xattr -dr com.apple.quarantine"))
    }

    @Test("the relaunch flag is what the caller asked for")
    func relaunchFlag() {
        #expect(script(relaunch: true).contains("relaunch=1"))
        #expect(script(relaunch: false).contains("relaunch=0"))
    }

    @Test("paths are single-quoted so a space cannot split an argument")
    func quoting() {
        let spaced = UpdateInstaller.helperScript(
            pid: 1,
            source: URL(fileURLWithPath: "/tmp/an app/OpenSVN.app"),
            destination: destination,
            backup: destination.appendingPathExtension("previous"),
            relaunch: false
        )
        #expect(spaced.contains("src='/tmp/an app/OpenSVN.app'"))
    }

    @Test("an apostrophe in a path cannot escape the quotes")
    func apostrophe() {
        #expect(UpdateInstaller.quote("/tmp/o'brien") == "'/tmp/o'\\''brien'")
    }
}

@Suite("update installer verification")
struct UpdateInstallerVerificationTests {
    /// Answers the two `codesign` invocations by kind: verification and dump.
    private struct StubRunner: CommandRunning {
        var verifyStatus: Int32 = 0
        var dump: String = "TeamIdentifier=TEAM123456\n"

        func run(executable: URL, arguments: [String]) async throws -> CommandResult {
            if arguments.contains("--verify") {
                return CommandResult(status: verifyStatus, output: verifyStatus == 0 ? "" : "invalid signature")
            }
            return CommandResult(status: 0, output: dump)
        }
    }

    private func makeBundle(
        in root: URL,
        name: String = "OpenSVN.app",
        identifier: String = "cn.opensvn.app",
        version: String = "0.2.0"
    ) throws -> URL {
        let bundle = root.appendingPathComponent(name, isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(identifier)</string>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        return bundle
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a Developer ID team is read from the signature")
    func teamRead() async throws {
        let installer = UpdateInstaller(runner: StubRunner())
        let team = try await installer.teamIdentifier(of: URL(fileURLWithPath: "/Applications/OpenSVN.app"))
        #expect(team == "TEAM123456")
    }

    @Test("ad-hoc is reported as no team, not as an error")
    func adHocTeam() async throws {
        let installer = UpdateInstaller(runner: StubRunner(dump: "Signature=adhoc\nTeamIdentifier=not set\n"))
        let team = try await installer.teamIdentifier(of: URL(fileURLWithPath: "/Applications/OpenSVN.app"))
        #expect(team == nil)
    }

    @Test("a matching signature, identifier and version pass")
    func accepts() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let installer = UpdateInstaller(runner: StubRunner())
        try await installer.verify(stagedBundle: bundle, version: AppVersion("0.2.0")!, team: "TEAM123456")
    }

    @Test("an invalid signature is refused before anything else is read")
    func invalidSignature() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let installer = UpdateInstaller(runner: StubRunner(verifyStatus: 1))
        await #expect(throws: UpdateInstallError.self) {
            try await installer.verify(stagedBundle: bundle, version: AppVersion("0.2.0")!, team: "TEAM123456")
        }
    }

    @Test("an ad-hoc update bundle is refused: there is no publisher to compare")
    func adHocRefused() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let installer = UpdateInstaller(runner: StubRunner(dump: "TeamIdentifier=not set\n"))
        await #expect(throws: UpdateInstallError.self) {
            try await installer.verify(stagedBundle: bundle, version: AppVersion("0.2.0")!, team: "TEAM123456")
        }
    }

    @Test("another team's signature is refused")
    func otherTeam() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let installer = UpdateInstaller(runner: StubRunner(dump: "TeamIdentifier=OTHERTEAM\n"))
        await #expect(throws: UpdateInstallError.teamIdentifierMismatch(expected: "TEAM123456", found: "OTHERTEAM")) {
            try await installer.verify(stagedBundle: bundle, version: AppVersion("0.2.0")!, team: "TEAM123456")
        }
    }

    @Test("a bundle for another application is refused")
    func wrongIdentifier() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root, identifier: "com.example.other")
        let installer = UpdateInstaller(runner: StubRunner())
        await #expect(throws: UpdateInstallError.self) {
            try await installer.verify(stagedBundle: bundle, version: AppVersion("0.2.0")!, team: "TEAM123456")
        }
    }

    @Test("a bundle whose version is not the announced one is refused")
    func wrongVersion() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root, version: "0.1.0")
        let installer = UpdateInstaller(runner: StubRunner())
        await #expect(throws: UpdateInstallError.self) {
            try await installer.verify(stagedBundle: bundle, version: AppVersion("0.2.0")!, team: "TEAM123456")
        }
    }

    @Test("a non-app path is refused without running codesign")
    func notAnApp() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = UpdateInstaller(runner: StubRunner())
        await #expect(throws: UpdateInstallError.notAnAppBundle(root.appendingPathComponent("notes.txt").path)) {
            try await installer.verify(
                stagedBundle: root.appendingPathComponent("notes.txt"),
                version: AppVersion("0.2.0")!,
                team: "TEAM123456"
            )
        }
    }
}

@Suite("update installation preconditions")
struct UpdateInstallationTests {
    @Test("an unwritable destination is reported before a script is written")
    func unwritable() throws {
        let installer = UpdateInstaller()
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-helper-\(UUID().uuidString).sh")
        #expect(throws: UpdateInstallError.self) {
            try installer.writeHelper(
                stagedBundle: URL(fileURLWithPath: "/tmp/x/OpenSVN.app"),
                destination: URL(fileURLWithPath: "/does-not-exist-\(UUID().uuidString)/OpenSVN.app"),
                helper: helper,
                relaunch: true
            )
        }
    }

    @Test("the helper is written executable, with the backup beside the destination")
    func writesHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = root.appendingPathComponent("staged/OpenSVN.app", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("Applications/OpenSVN.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let helper = root.appendingPathComponent("updates/install.sh")

        let script = try UpdateInstaller().writeHelper(
            stagedBundle: staged,
            destination: destination,
            helper: helper,
            relaunch: false
        )

        #expect(FileManager.default.fileExists(atPath: helper.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: helper.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o755)
        #expect(script.contains("dst='\(destination.path)'"))
        #expect(script.contains("backup='\(destination.path).previous'"))
    }

    @Test("staging lives under the version, so two attempts cannot collide")
    func stagingPath() {
        let updates = URL(fileURLWithPath: "/tmp/updates")
        let path = UpdateInstaller.stagingDirectory(for: AppVersion("0.2.0")!, in: updates)
        #expect(path.path == "/tmp/updates/0.2.0")
    }
}

@Suite("update archive unpacking")
struct UpdateUnpackTests {
    private func makeApp(in root: URL) throws -> URL {
        let app = root.appendingPathComponent("OpenSVN.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: contents.appendingPathComponent("OpenSVN"))
        return app
    }

    private func zip(_ source: URL, to destination: URL) async throws {
        let result = try await SystemCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", source.path, destination.path]
        )
        #expect(result.status == 0)
    }

    @Test("a zip holding one app yields that app")
    func singleBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeApp(in: root)
        let archive = root.appendingPathComponent("update.zip")
        try await zip(app, to: archive)

        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        let found = try await UpdateInstaller().unpack(archive: archive, into: expanded)
        #expect(found.lastPathComponent == "OpenSVN.app")
    }

    @Test("an archive with no app is refused")
    func noBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: payload.appendingPathComponent("README.txt"))
        let archive = root.appendingPathComponent("update.zip")
        try await zip(payload, to: archive)

        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        await #expect(throws: UpdateInstallError.self) {
            try await UpdateInstaller().unpack(archive: archive, into: expanded)
        }
    }
}
