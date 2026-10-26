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
}

extension SVNError {
    /// Convenience for assertions.
    var isCancellation: Bool {
        if case .cancelled = code { return true }
        if case .timeout = code { return true }
        return false
    }
}
