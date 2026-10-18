import Foundation
import Testing
@testable import OpenSVNCore

@Suite("SVNDiscovery")
struct DiscoveryTests {
    @Test("an explicit path is the only candidate")
    func explicitCandidate() {
        let discovery = SVNDiscovery(explicitExecutablePath: "/custom/bin/svn", environment: [:])
        #expect(discovery.candidates().count == 1)
        #expect(discovery.candidates()[0].source == .explicit)
        #expect(discovery.candidates()[0].path == "/custom/bin/svn")
    }

    @Test("bundled runtime wins over PATH, which wins over well-known locations")
    func candidateOrder() {
        let bundled = URL(fileURLWithPath: "/Applications/OpenSVN.app/Contents/Resources/svn/bin/svn")
        let discovery = SVNDiscovery(
            bundledCandidates: [bundled],
            environment: ["PATH": "/custom/bin:/usr/bin"]
        )
        let candidates = discovery.candidates()
        #expect(candidates.first?.source == .bundled)
        #expect(candidates.first?.path == bundled.path)
        #expect(candidates.contains { $0.path == "/custom/bin/svn" && $0.source == .searchPath })
        #expect(candidates.contains { $0.path == "/opt/homebrew/bin/svn" && $0.source == .wellKnownLocation })
        #expect(Set(candidates.map(\.path)).count == candidates.count)
    }

    @Test("resolves the developer's real svn and validates its version", .enabled(if: TestEnvironment.svnExecutable != nil))
    func resolveRealSVN() async throws {
        let installation = try await SVNDiscovery(environment: ProcessInfo.processInfo.environment).resolve()
        #expect(installation.version >= SVNDiscovery().minimumVersion)
        #expect(FileManager.default.isExecutableFile(atPath: installation.executableURL.path))
    }

    @Test("an invalid explicit path fails loudly instead of falling back")
    func invalidExplicitPath() async {
        let discovery = SVNDiscovery(explicitExecutablePath: "/nonexistent/svn", environment: ProcessInfo.processInfo.environment)
        do {
            _ = try await discovery.resolve()
            Issue.record("expected svnNotFound")
        } catch let error as SVNError {
            #expect(error.code == .svnNotFound)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("an unsupported version is rejected with the found version")
    func unsupportedVersion() async throws {
        let directory = try TestEnvironment.makeTemporaryDirectory("fake-svn")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = try TestEnvironment.makeExecutableScript(
            in: directory,
            name: "svn",
            contents: "#!/bin/sh\necho 1.5.0\n"
        )
        let discovery = SVNDiscovery(explicitExecutablePath: fake.path, environment: [:])
        do {
            _ = try await discovery.resolve()
            Issue.record("expected unsupportedVersion")
        } catch let error as SVNError {
            if case .unsupportedVersion(let found, let minimum) = error.code {
                #expect(found == "1.5.0")
                #expect(minimum == "1.10.0")
            } else {
                Issue.record("wrong code: \(error.code)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("version parsing accepts verbose output and rejects junk")
    func versionParsing() {
        #expect(SVNVersion("1.14.5") == SVNVersion(major: 1, minor: 14, patch: 5))
        #expect(SVNVersion("svn, version 1.14.5 (r1886195)") == SVNVersion(major: 1, minor: 14, patch: 5))
        #expect(SVNVersion("no version here") == nil)
        #expect(SVNVersion(major: 1, minor: 9, patch: 0) < SVNVersion(major: 1, minor: 10, patch: 0))
    }
}

@Suite("error mapping")
struct ErrorMappingTests {
    private func result(stderr: String, exitCode: Int32 = 1) -> SVNProcessResult {
        SVNProcessResult(exitCode: exitCode, standardOutput: "", standardError: stderr, duration: 0.1)
    }

    @Test("working copy lock maps to SVN-0004 with a Cleanup hint")
    func locked() throws {
        let error = try #require(SVNErrorMapper.error(from: result(
            stderr: "svn: E155004: Run 'svn cleanup' to remove locks (type 'svn help cleanup' for details)\n"
        )))
        #expect(error.code == .workingCopyLocked)
        #expect(error.code.identifier == "SVN-0004")
        #expect(error.svnCode == "E155004")
        #expect(error.code.remediation?.contains("Cleanup") == true)
    }

    @Test("authentication failures are recognised")
    func authentication() throws {
        let error = try #require(SVNErrorMapper.error(from: result(
            stderr: "svn: E170001: Authorization failed\n"
        )))
        #expect(error.code == .authorizationFailed)
        #expect(error.code.isAuthenticationRelated)

        let anonymous = try #require(SVNErrorMapper.error(from: result(
            stderr: "svn: E215004: No more credentials or we tried too many times.\n"
        )))
        #expect(anonymous.code == .authenticationRequired)
        #expect(anonymous.svnCode == "E215004")
    }

    @Test("out-of-date and conflict states are distinct")
    func states() throws {
        let outOfDate = try #require(SVNErrorMapper.error(from: result(
            stderr: "svn: E160028: File 'a' is out of date; try updating\n"
        )))
        #expect(outOfDate.code == .outOfDate)

        let conflict = try #require(SVNErrorMapper.error(from: result(
            stderr: "svn: E155015: Aborting commit: 'a' remains in conflict\n"
        )))
        #expect(conflict.code == .conflictRemains)
    }

    @Test("unknown failures keep the exit code and redact the diagnostic")
    func unknown() throws {
        let error = try #require(SVNErrorMapper.error(from: result(
            stderr: "svn: E999999: Something odd with password=hunter2\n",
            exitCode: 2
        )))
        if case .commandFailed(let code) = error.code {
            #expect(code == 2)
        } else {
            Issue.record("expected commandFailed, got \(error.code)")
        }
        #expect(error.diagnosticOutput?.contains("hunter2") == false)
    }

    @Test("success yields no error")
    func success() {
        #expect(SVNErrorMapper.error(from: SVNProcessResult(exitCode: 0, standardOutput: "", standardError: "", duration: 0)) == nil)
    }
}

@Suite("redaction and credentials")
struct RedactionTests {
    @Test("URL userinfo is stripped")
    func urlUserinfo() {
        let redacted = LogRedactor.redact("checkout https://alice:s3cret@example.com/repo/trunk")
        #expect(!redacted.contains("s3cret"))
        #expect(!redacted.contains("alice"))
        #expect(redacted.contains("https://***@example.com/repo/trunk"))
    }

    @Test("password arguments and key/value forms are masked")
    func passwordArguments() {
        let text = "svn --username bob --password hunter2 commit\npassword=hunter2&token=abc123"
        let redacted = LogRedactor.redact(text)
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("abc123"))
    }

    @Test("known secrets are removed even when no pattern matches")
    func explicitSecrets() {
        let redacted = LogRedactor.redact("error near 中文密码 with token", secrets: ["中文密码"])
        #expect(!redacted.contains("中文密码"))
    }

    @Test("sanitized URLs keep host and path")
    func sanitizedURL() {
        #expect(LogRedactor.sanitizedURL("svn+ssh://user:pw@host/repo") == "svn+ssh://host/repo")
    }

    @Test("credential descriptions never include the password")
    func credentialDescription() {
        let credential = SVNCredential(username: "bob", password: "hunter2")
        #expect(credential.description.contains("bob"))
        #expect(!credential.description.contains("hunter2"))
        #expect(!credential.debugDescription.contains("hunter2"))
    }

    @Test("credential scope is derived from the URL, not from file URLs")
    func credentialScope() {
        #expect(CredentialScope(repositoryURL: "https://example.com/repo")?.host == "example.com")
        #expect(CredentialScope(repositoryURL: "file:///tmp/repo") == nil)
        #expect(CredentialScope(repositoryURL: "not a url") == nil)
    }

    @Test("in-memory store round-trips and clears")
    func inMemoryStore() throws {
        let store = InMemoryCredentialStore()
        let scope = CredentialScope(host: "example.com")
        #expect(try store.credential(for: scope) == nil)
        try store.save(SVNCredential(username: "bob", password: "pw"), for: scope)
        #expect(try store.credential(for: scope)?.username == "bob")
        try store.remove(for: scope)
        #expect(try store.credential(for: scope) == nil)
    }
}
