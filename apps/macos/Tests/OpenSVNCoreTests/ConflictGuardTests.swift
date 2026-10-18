import Foundation
import Testing
@testable import OpenSVNCore

/// Guards are only worth having if a wrong `--accept` is actually recoverable,
/// so these tests check the files on disk, not just the return value.
@Suite("conflict guard")
struct ConflictGuardTests {

    private struct Fixture {
        let root: URL
        let workingCopy: URL
        let file: URL
        let guardInstance: ConflictGuard
    }

    private func makeFixture() throws -> Fixture {
        let root = try TestEnvironment.makeTemporaryDirectory("conflict-guard")
        let workingCopy = root.appendingPathComponent("wc", isDirectory: true)
        let source = workingCopy.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        // A real `.svn` makes the backup folder name stable and realistic.
        try FileManager.default.createDirectory(
            at: workingCopy.appendingPathComponent(".svn", isDirectory: true),
            withIntermediateDirectories: true
        )
        let file = source.appendingPathComponent("README.md")
        try "<<<<<<< .mine\nlocal\n=======\nserver\n>>>>>>> .r2\n"
            .write(to: file, atomically: true, encoding: .utf8)
        return Fixture(
            root: root,
            workingCopy: workingCopy,
            file: file,
            guardInstance: ConflictGuard(root: root.appendingPathComponent("backups", isDirectory: true))
        )
    }

    @Test("backs up the working file and every conflict copy beside it")
    func backsUpArtifacts() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try "local\n".write(
            to: fixture.workingCopy.appendingPathComponent("src/README.md.mine"),
            atomically: true,
            encoding: .utf8
        )
        try "server\n".write(
            to: fixture.workingCopy.appendingPathComponent("src/README.md.r2"),
            atomically: true,
            encoding: .utf8
        )
        // Not a conflict artifact; must be left alone.
        try "unrelated\n".write(
            to: fixture.workingCopy.appendingPathComponent("src/README.md.rsync-temp"),
            atomically: true,
            encoding: .utf8
        )

        let maybeBackup = try fixture.guardInstance.backup(paths: [fixture.file], reason: "resolve-working")
        let backup = try #require(maybeBackup)

        #expect(backup.entries.count == 3)
        #expect(backup.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.backupPath) })
        #expect(backup.directory.path.hasPrefix(fixture.root.path))

        // The original is untouched: a backup must never move or delete it.
        let original = try String(contentsOf: fixture.file, encoding: .utf8)
        #expect(original.contains("<<<<<<<"))
    }

    @Test("returns nil when the file has no conflict copies")
    func noArtifactsMeansNoEmptyDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let missing = fixture.workingCopy.appendingPathComponent("src/absent.txt")
        let result = try fixture.guardInstance.backup(paths: [missing], reason: "resolve-working")
        #expect(result == nil)
    }

    @Test("fails loudly instead of resolving without a backup")
    func unwritableBackupRootThrows() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // A regular file where the backup directory should be: creating the
        // directory has to fail, and the caller must see SVN-0303.
        let blocker = fixture.root.appendingPathComponent("blocked")
        try "not a directory\n".write(to: blocker, atomically: true, encoding: .utf8)
        let guardInstance = ConflictGuard(root: blocker)

        #expect(throws: SVNError.self) {
            try guardInstance.backup(paths: [fixture.file], reason: "resolve-theirs-full")
        }
        do {
            _ = try guardInstance.backup(paths: [fixture.file], reason: "resolve-theirs-full")
        } catch let error as SVNError {
            #expect(error.code == .backupFailed)
            #expect(error.code.identifier == "SVN-0303")
        }
    }

    @Test("detects leftover markers, ignores a bare =======")
    func scansForMarkers() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let scan = fixture.guardInstance.scan(path: fixture.file)
        guard case .unresolved(let markers) = scan.result else {
            Issue.record("expected unresolved markers, got \(scan.result)")
            return
        }
        #expect(markers == [1, 5])

        // reStructuredText uses a line of `=` as an underline; it is not a
        // conflict marker and reporting it would train users to ignore the warning.
        let clean = fixture.workingCopy.appendingPathComponent("src/doc.rst")
        try "Title\n=======\n\ntext\n".write(to: clean, atomically: true, encoding: .utf8)
        #expect(fixture.guardInstance.scan(path: clean).result == .clean)
    }

    @Test("skips binary and unreadable files instead of guessing")
    func skipsNonText() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let binary = fixture.workingCopy.appendingPathComponent("src/blob.bin")
        try Data([0x00, 0x01, 0x02, 0xff]).write(to: binary)
        guard case .skipped = fixture.guardInstance.scan(path: binary).result else {
            Issue.record("binary file should be skipped")
            return
        }

        let missing = fixture.workingCopy.appendingPathComponent("src/gone.txt")
        guard case .skipped = fixture.guardInstance.scan(path: missing).result else {
            Issue.record("missing file should be skipped")
            return
        }
    }

    @Test("keeps the newest backups and drops the rest")
    func prunesOldBackups() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<4 {
            _ = try fixture.guardInstance.backup(
                paths: [fixture.file],
                reason: "run-\(index)",
                now: base.addingTimeInterval(Double(index))
            )
        }
        let group = try #require(
            (try? FileManager.default.contentsOfDirectory(
                at: fixture.guardInstance.root,
                includingPropertiesForKeys: nil
            ))?.first
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: group.path).count == 4)

        let removed = fixture.guardInstance.prune(keepingPerWorkingCopy: 2)
        #expect(removed == 2)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: group.path).sorted()
        #expect(remaining.count == 2)
        #expect(remaining.last?.contains("run-3") == true)
    }

    @Test("recognises conflict suffixes but not lookalikes")
    func suffixRules() {
        #expect(ConflictGuard.isConflictSuffix("mine"))
        #expect(ConflictGuard.isConflictSuffix("r1"))
        #expect(ConflictGuard.isConflictSuffix("r1234"))
        #expect(ConflictGuard.isConflictSuffix("working"))
        #expect(!ConflictGuard.isConflictSuffix("r"))
        #expect(!ConflictGuard.isConflictSuffix("rsync-temp"))
        #expect(!ConflictGuard.isConflictSuffix("md"))
    }
}
