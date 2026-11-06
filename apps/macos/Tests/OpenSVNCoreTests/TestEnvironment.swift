import Foundation
import OpenSVNCore

/// Shared helpers for the core test target.
enum TestEnvironment {
    /// Repo root, derived from the source file location so tests work from any
    /// working directory (swift test, Xcode, CI).
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static let fixtureDirectory: URL = repoRoot.appendingPathComponent("testdata", isDirectory: true)

    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory.appendingPathComponent(name))
    }

    static func fixturePath(_ name: String) -> String {
        fixtureDirectory.appendingPathComponent(name).path
    }

    /// PATH-based lookup of the developer's svn, used by integration tests.
    static let svnExecutable: URL? = {
        let candidates = [
            "/opt/homebrew/bin/svn",
            "/usr/local/bin/svn",
            "/usr/bin/svn"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()

    static let svnadminExecutable: URL? = {
        let candidates = [
            "/opt/homebrew/bin/svnadmin",
            "/usr/local/bin/svnadmin",
            "/usr/bin/svnadmin"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()

    static var integrationPrerequisitesMet: Bool {
        svnExecutable != nil && svnadminExecutable != nil
    }

    static func makeTemporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes an executable shell script, used to fake `svn` versions.
    static func makeExecutableScript(in directory: URL, name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A fake `svn` that logs its argv and answers `info` / `status` with canned
    /// XML, so a service-level guard can be exercised without a real working copy.
    ///
    /// The subcommand is found by skipping global options rather than assuming
    /// `$1`: the service hoists `--non-interactive` and friends in front of the
    /// subcommand, and a fake that read `$1` would answer the wrong question.
    @MainActor
    static func makeScriptedService(
        infoXML: String,
        statusXML: String
    ) throws -> (service: SVNService, argsFile: URL, root: URL) {
        let root = try makeTemporaryDirectory("scripted")
        let argsFile = root.appendingPathComponent("args.txt")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" >> '\(argsFile.path)'
        CMD=""
        for a in "$@"; do
          case "$a" in
            --non-interactive|--no-auth-cache|--username|--password-from-stdin) continue;;
            --*) continue;;
            *) CMD="$a"; break;;
          esac
        done
        case "$CMD" in
        info)
        cat <<'OPEN_SVN_XML'
        \(infoXML)
        OPEN_SVN_XML
        ;;
        status)
        cat <<'OPEN_SVN_XML'
        \(statusXML)
        OPEN_SVN_XML
        ;;
        esac
        exit 0
        """
        let svn = try makeExecutableScript(in: root, name: "svn", contents: script)
        let service = SVNService(configuration: SVNServiceConfiguration(
            installation: SVNInstallation(
                executableURL: svn,
                version: SVNVersion(major: 1, minor: 15, patch: 0),
                source: .explicit
            ),
            credentialStore: InMemoryCredentialStore(),
            environment: [:],
            timeout: 30,
            journal: nil
        ))
        return (service, argsFile, root)
    }
}

extension SVNError {
    /// Convenience for assertions.
    var isCancellation: Bool {
        if case .cancelled = code { return true }
        if case .timeout = code { return true }
        return false
    }
}
