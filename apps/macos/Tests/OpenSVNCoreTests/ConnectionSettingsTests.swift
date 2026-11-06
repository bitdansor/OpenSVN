import Foundation
import Testing
@testable import OpenSVNCore

/// Connection settings: argument generation, fail-closed parsing, the svn
/// version gate, one-shot consumption, proxy validation, [groups]/secret
/// handling and the servers-file backup.
///
/// Every test uses an isolated `UserDefaults` suite and a temporary directory;
/// nothing here reads the network or the real `~/.subversion`.
@Suite("connection settings")
struct ConnectionSettingsTests {

    /// The project's verified baseline (specifications/compatibility.md).
    private static let supportedVersion = SVNVersion(major: 1, minor: 14, patch: 5)

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "opensvn.tests.connection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    /// A directory that is never created: pure logic tests must not touch disk.
    private func nonExistentDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-nofile-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(
        _ defaults: UserDefaults,
        directory: URL? = nil
    ) -> SVNConnectionSettingsStore {
        SVNConnectionSettingsStore(
            defaults: defaults,
            subversionDirectory: directory ?? nonExistentDirectory()
        )
    }

    // MARK: - Argument generation

    @Test("default policy is strict and emits no trust flags")
    func defaultPolicyIsStrict() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = makeStore(defaults)

        #expect(store.persistentPolicy == .strict)
        #expect(store.hasPendingOneShotTrust == false)
        #expect(store.resolveSVNTrustArguments(svnVersion: Self.supportedVersion) == [])
        #expect(
            SVNConnectionSettingsStore.svnArguments(for: .strict, svnVersion: Self.supportedVersion)
                == []
        )
    }

    @Test("specified failures produce --trust-server-cert-failures in a stable order")
    func specifiedFailuresArguments() {
        #expect(
            SVNConnectionSettingsStore.svnArguments(
                for: .specifiedFailures([.unknownCA]),
                svnVersion: Self.supportedVersion
            ) == ["--trust-server-cert-failures", "unknown-ca"]
        )
        let multiple: Set<ServerCertificateFailure> = [.other, .unknownCA, .cnMismatch]
        #expect(
            SVNConnectionSettingsStore.svnArguments(
                for: .specifiedFailures(multiple),
                svnVersion: Self.supportedVersion
            ) == ["--trust-server-cert-failures", "unknown-ca,cn-mismatch,other"]
        )
    }

    @Test("trust-all names every failure explicitly")
    func trustAllArguments() {
        #expect(
            SVNConnectionSettingsStore.svnArguments(
                for: .trustAllCertificates,
                svnVersion: Self.supportedVersion
            ) == [
                "--trust-server-cert-failures",
                "unknown-ca,cn-mismatch,expired,not-yet-valid,other"
            ]
        )
    }

    @Test("an empty failure set fails closed instead of emitting a malformed flag")
    func emptyFailureSetFailsClosed() {
        #expect(
            SVNConnectionSettingsStore.svnArguments(
                for: .specifiedFailures([]),
                svnVersion: Self.supportedVersion
            ) == []
        )
    }

    @Test("older svn never receives the trust flag")
    func versionGateBlocksOlderSVN() {
        let old = SVNVersion(major: 1, minor: 13, patch: 9)
        let minimum = SVNConnectionSettingsStore.trustFailuresMinimumVersion
        #expect(
            SVNConnectionSettingsStore.svnArguments(for: .trustAllCertificates, svnVersion: old)
                == []
        )
        #expect(
            SVNConnectionSettingsStore.svnArguments(
                for: .specifiedFailures([.unknownCA]),
                svnVersion: old
            ) == []
        )
        #expect(
            SVNConnectionSettingsStore.svnArguments(for: .trustAllCertificates, svnVersion: minimum)
                .count == 2
        )

        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = makeStore(defaults)
        store.persistentPolicy = .trustAllCertificates
        #expect(store.resolveSVNTrustArguments(svnVersion: old) == [])
    }

    // MARK: - Rejecting illegal values

    @Test("unknown failure tokens are dropped, not handed to svn")
    func unknownFailureTokensIgnored() {
        #expect(
            SVNConnectionSettingsStore.parseFailures("unknown-ca,BOGUS, cn-mismatch ,")
                == [.unknownCA, .cnMismatch]
        )
        #expect(SVNConnectionSettingsStore.parseFailures("bogus") == [])
        #expect(SVNConnectionSettingsStore.parseFailures("") == [])
        #expect(SVNConnectionSettingsStore.csv(for: [.other, .expired]) == "expired,other")
    }

    @Test("corrupt persisted values fall back to strict")
    func corruptPersistedValuesFailClosed() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = makeStore(defaults)

        defaults.set("garbage", forKey: SVNConnectionSettingsStore.trustModeKey)
        defaults.set("unknown-ca,EVIL", forKey: SVNConnectionSettingsStore.trustFailuresKey)
        #expect(store.persistentPolicy == .strict)

        defaults.set("specified", forKey: SVNConnectionSettingsStore.trustModeKey)
        defaults.set("EVIL,also-bad", forKey: SVNConnectionSettingsStore.trustFailuresKey)
        #expect(store.persistentPolicy == .strict)
        #expect(store.resolveSVNTrustArguments(svnVersion: Self.supportedVersion) == [])
    }

    @Test("proxy validation rejects newlines and out-of-range ports")
    func proxyValidationRejectsUnsafeValues() {
        #expect(throws: ConnectionSettingsError.self) {
            try ProxySettings(host: "proxy\nhttp-proxy-host = evil").validated()
        }
        #expect(throws: ConnectionSettingsError.self) {
            try ProxySettings(host: "p", exceptions: "a\nb").validated()
        }
        #expect(throws: ConnectionSettingsError.self) {
            try ProxySettings(host: "p", port: 0).validated()
        }
        #expect(throws: ConnectionSettingsError.self) {
            try ProxySettings(host: "p", port: 70_000).validated()
        }

        let valid = try? ProxySettings(host: "  proxy.example.com  ", port: 8080).validated()
        #expect(valid?.host == "proxy.example.com")
        #expect(valid?.port == 8080)
    }

    // MARK: - Persistence & one-shot semantics

    @Test("persistent policy survives a reload")
    func persistenceRoundTrip() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = nonExistentDirectory()
        let store = SVNConnectionSettingsStore(defaults: defaults, subversionDirectory: directory)
        store.persistentPolicy = .specifiedFailures([.unknownCA, .expired])

        let reloaded = SVNConnectionSettingsStore(defaults: defaults, subversionDirectory: directory)
        #expect(reloaded.persistentPolicy == .specifiedFailures([.unknownCA, .expired]))
        #expect(
            reloaded.resolveSVNTrustArguments(svnVersion: Self.supportedVersion)
                == ["--trust-server-cert-failures", "unknown-ca,expired"]
        )
    }

    @Test("a one-shot trust widening is consumed exactly once")
    func oneShotConsumedExactlyOnce() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = makeStore(defaults)

        store.persistentPolicy = .strict
        store.armOneShotTrust(.specifiedFailures([.cnMismatch]))
        #expect(store.hasPendingOneShotTrust)
        #expect(
            store.resolveSVNTrustArguments(svnVersion: Self.supportedVersion)
                == ["--trust-server-cert-failures", "cn-mismatch"]
        )
        #expect(store.hasPendingOneShotTrust == false)
        // Consumed: the standing (strict) policy is back in effect.
        #expect(store.resolveSVNTrustArguments(svnVersion: Self.supportedVersion) == [])
    }

    @Test("a one-shot request overrides, then restores, the standing policy")
    func oneShotOverridesPersistent() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = makeStore(defaults)

        store.persistentPolicy = .trustAllCertificates
        store.armOneShotTrust(.specifiedFailures([.expired]))
        #expect(
            store.resolveSVNTrustArguments(svnVersion: Self.supportedVersion)
                == ["--trust-server-cert-failures", "expired"]
        )
        #expect(
            store.resolveSVNTrustArguments(svnVersion: Self.supportedVersion)
                == ["--trust-server-cert-failures", "unknown-ca,cn-mismatch,expired,not-yet-valid,other"]
        )
    }

    // MARK: - servers file parsing: [groups] and secrets

    @Test("[groups] is read-only and password values are redacted")
    func groupsAndSecretsParsing() {
        let text = """
        [global]
        http-proxy-host = proxy.example.com
        http-proxy-password = s3cr3t
        ssl-client-cert-password = another-secret
        http-auth-types = basic;digest

        [groups]
        internal = *.internal.example.com
        external = *.example.org
        """
        let config = ServersConfig.parse(text, fileExists: true)

        #expect(config.groupEntries["internal"] == "*.internal.example.com")
        #expect(config.groupEntries["external"] == "*.example.org")
        #expect(config.proxy.host == "proxy.example.com")
        #expect(config.displayEntries["http-auth-types"] == "basic;digest")
        #expect(config.globalEntries["http-proxy-password"] == "••••••")
        #expect(config.displayEntries["http-proxy-password"] == "••••••")
        #expect(config.displayEntries["ssl-client-cert-password"] == "••••••")
        // rawText keeps the original bytes for a later write, but is never
        // displayed or logged by the UI.
        #expect(config.rawText == text)
    }

    // MARK: - servers file text transform

    @Test("editing proxy fields preserves comments, other keys and other sections")
    func applyingUpdatesOnlyProxyKeys() throws {
        let text = """
        ### Subversion servers
        [global]
        # http-proxy-host = old.example.com
        # http-proxy-port = 3128
        http-timeout = 60
        # http-auth-types = basic;digest

        [groups]
        group1 = *.example.com
        """
        let result = try SVNConnectionSettingsStore.applying(
            proxy: ProxySettings(
                host: "new.proxy",
                port: 8080,
                username: "alice",
                exceptions: "localhost,*.internal"
            ),
            to: text
        )

        #expect(result.contains("http-proxy-host = new.proxy"))
        #expect(!result.contains("old.example.com"))
        #expect(result.contains("http-proxy-port = 8080"))
        #expect(result.contains("http-proxy-username = alice"))
        #expect(result.contains("http-proxy-exceptions = localhost,*.internal"))
        #expect(result.contains("http-timeout = 60"))
        #expect(result.contains("# http-auth-types = basic;digest"))
        #expect(result.contains("[groups]"))
        #expect(result.contains("group1 = *.example.com"))
    }

    @Test("a missing [global] section is created before other sections")
    func applyingCreatesGlobalSection() throws {
        let text = "[groups]\ngroup1 = *.example.com\n"
        let result = try SVNConnectionSettingsStore.applying(
            proxy: ProxySettings(host: "p", port: 3128),
            to: text
        )
        #expect(result.contains("[global]"))
        #expect(result.contains("http-proxy-host = p"))
        #expect(result.contains("[groups]"))
        let global = try #require(result.range(of: "[global]"))
        let groups = try #require(result.range(of: "[groups]"))
        #expect(global.lowerBound < groups.lowerBound)
    }

    @Test("empty values comment a key out rather than deleting it")
    func applyingCommentsOutDisabledValues() throws {
        let text = "[global]\nhttp-proxy-host = old\nhttp-proxy-port = 3128\n"
        let result = try SVNConnectionSettingsStore.applying(
            proxy: ProxySettings(host: "", port: nil),
            to: text
        )
        #expect(result.contains("# http-proxy-host = "))
        #expect(result.contains("# http-proxy-port = "))
        #expect(!result.contains("http-proxy-host = old"))
    }

    // MARK: - Backup behaviour

    @Test("the existing servers file is backed up byte-for-byte before rewrite")
    func serversFileReadAndBackup() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = try TestEnvironment.makeTemporaryDirectory("connection-settings-backup")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("servers")
        let original = """
        [global]
        http-proxy-host = old.example.com
        http-proxy-port = 3128
        http-timeout = 60

        [groups]
        group1 = *.example.com
        """
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = SVNConnectionSettingsStore(defaults: defaults, subversionDirectory: directory)
        let config = try store.readServersConfig()
        #expect(config.fileExists)
        #expect(config.proxy.host == "old.example.com")
        #expect(config.proxy.port == 3128)
        #expect(config.globalEntries["http-timeout"] == "60")
        #expect(config.groupEntries["group1"] == "*.example.com")

        let backup = try store.writeProxySettings(
            ProxySettings(host: "new.proxy", port: 8080)
        )
        let backupURL = try #require(backup)
        #expect(backupURL.lastPathComponent.contains("opensvn-backup"))
        let backupText = try String(contentsOf: backupURL, encoding: .utf8)
        #expect(backupText == original)

        let updated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(updated.contains("http-proxy-host = new.proxy"))
        #expect(updated.contains("http-timeout = 60"))
    }

    @Test("rewriting proxy fields leaves an existing password line intact")
    func passwordLineSurvivesRewrite() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = try TestEnvironment.makeTemporaryDirectory("connection-settings-password")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("servers")
        let original = """
        [global]
        http-proxy-host = old.example.com
        http-proxy-password = s3cr3t

        [groups]
        internal = *.internal.example.com
        """
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = SVNConnectionSettingsStore(defaults: defaults, subversionDirectory: directory)
        _ = try store.writeProxySettings(ProxySettings(host: "new.proxy", port: 8080))

        let updated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(updated.contains("http-proxy-password = s3cr3t"))
        #expect(updated.contains("http-proxy-host = new.proxy"))
        #expect(updated.contains("internal = *.internal.example.com"))
        // The cleartext secret never enters our parsed settings storage.
        let reread = try store.readServersConfig()
        #expect(reread.globalEntries["http-proxy-password"] == "••••••")
    }

    @Test("no backup is made when the file is absent, and a new file is created")
    func newServersFileNeedsNoBackup() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = try TestEnvironment.makeTemporaryDirectory("connection-settings-new")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SVNConnectionSettingsStore(defaults: defaults, subversionDirectory: directory)

        let emptyConfig = try store.readServersConfig()
        #expect(emptyConfig.fileExists == false)
        #expect(emptyConfig.globalEntries.isEmpty)
        #expect(emptyConfig.groupEntries.isEmpty)
        let noBackup = try store.backupServersFile()
        #expect(noBackup == nil)

        let result = try store.writeProxySettings(ProxySettings(host: "p", port: 8080))
        #expect(result == nil)
        #expect(FileManager.default.fileExists(atPath: store.serversFileURL.path))
        let written = try String(contentsOf: store.serversFileURL, encoding: .utf8)
        #expect(written.contains("[global]"))
        #expect(written.contains("http-proxy-host = p"))
    }
}
