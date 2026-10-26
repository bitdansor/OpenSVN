import Foundation
import Testing
@testable import OpenSVNCore

/// Lock handling, from parsing svn's human-readable output down to the
/// distinction the UI depends on: a lock we hold versus one someone else holds.
@Suite("locks")
struct LockTests {

    // MARK: - Output parsing

    @Test("lock output names each path and the owner")
    func lockOutput() {
        let stdout = """
        'src/a.swift' locked by user 'fixture'.
        'docs/说明文档.md' locked by user 'fixture'.
        """
        #expect(LockOutputParser.lockedPaths(in: stdout) == ["src/a.swift", "docs/说明文档.md"])
        #expect(LockOutputParser.owner(in: stdout) == "fixture")
        #expect(LockOutputParser.unlockedPaths(in: stdout).isEmpty)
    }

    @Test("unlock output is a different sentence and must not be read as a lock")
    func unlockOutput() {
        let stdout = """
        'src/a.swift' unlocked.
        """
        #expect(LockOutputParser.unlockedPaths(in: stdout) == ["src/a.swift"])
        #expect(LockOutputParser.lockedPaths(in: stdout).isEmpty)
        #expect(LockOutputParser.owner(in: stdout) == nil)
    }

    @Test("a path containing an apostrophe or a newline-tolerant suffix still parses")
    func awkwardPaths() {
        // svn quotes with single quotes and does not escape them; the greedy
        // match keeps "it's" in the path instead of stopping at the first quote.
        let stdout = "'docs/it's here.txt' locked by user 'bob'.\n"
        #expect(LockOutputParser.lockedPaths(in: stdout) == ["docs/it's here.txt"])
        // Unknown wording must not produce fake paths.
        #expect(LockOutputParser.lockedPaths(in: "Locked: a.txt").isEmpty)
    }

    // MARK: - Snapshot

    @Test("a remote lock and an own lock are told apart")
    func ownVersusForeign() throws {
        let status = try SVNXMLParser.parseStatus(TestEnvironment.fixture("svn-status-remote-lock.xml"))
        let snapshot = LockSnapshot.from(status: status)

        #expect(snapshot.count == 2)
        #expect(snapshot.lock(for: "/tmp/wc/docs/both.txt")?.owner == "mine")
        #expect(snapshot.isOwnLock(for: "/tmp/wc/docs/both.txt"))

        #expect(snapshot.lock(for: "/tmp/wc/docs/other.txt")?.owner == "alice")
        #expect(snapshot.isOwnLock(for: "/tmp/wc/docs/other.txt") == false)

        #expect(snapshot.lock(for: "/tmp/wc/docs/free.txt") == nil)
        #expect(snapshot.isOwnLock(for: "/tmp/wc/docs/free.txt") == false)
    }

    @Test("only a foreign lock has to be forced")
    func foreignLocks() throws {
        let status = try SVNXMLParser.parseStatus(TestEnvironment.fixture("svn-status-remote-lock.xml"))
        let snapshot = LockSnapshot.from(status: status)
        let candidates = ["/tmp/wc/docs/both.txt", "/tmp/wc/docs/other.txt", "/tmp/wc/docs/free.txt"]
        #expect(snapshot.foreignLocks(among: candidates) == ["/tmp/wc/docs/other.txt"])
    }

    @Test("repos-status locks land in remoteLock, never in repositoryLock")
    func parserKeepsLocksApart() throws {
        let status = try SVNXMLParser.parseStatus(TestEnvironment.fixture("svn-status-remote-lock.xml"))
        let other = try #require(status.entries.first { $0.path.hasSuffix("other.txt") })
        #expect(other.repositoryLock == nil)
        #expect(other.remoteLock?.owner == "alice")
        #expect(other.effectiveLock?.owner == "alice")

        let both = try #require(status.entries.first { $0.path.hasSuffix("both.txt") })
        #expect(both.repositoryLock?.owner == "mine")
        #expect(both.remoteLock?.owner == "mine")
        #expect(both.effectiveLock?.owner == "mine")
    }

    @Test("a path reported relative to the target still matches an absolute lookup")
    func suffixMatching() {
        let snapshot = LockSnapshot(
            locks: ["docs/a.txt": RepositoryLock(owner: "alice")],
            ownPaths: []
        )
        #expect(snapshot.lock(for: "/tmp/wc/docs/a.txt")?.owner == "alice")
        #expect(snapshot.foreignLocks(among: ["/tmp/wc/docs/a.txt"]) == ["/tmp/wc/docs/a.txt"])
    }

    // MARK: - Error mapping

    @Test("lock conflicts map to their own codes, not to a generic failure")
    func mapping() {
        let held = SVNErrorMapper.error(
            exitCode: 1,
            standardError: """
            svn: warning: W160035: Path '/a.txt' is already locked by user 'alice' in filesystem 'abc'
            svn: E200009: One or more locks could not be obtained
            """
        )
        #expect(held.code == .pathLocked)
        #expect(held.code.severity == .needsUserAction)

        let gone = SVNErrorMapper.error(
            exitCode: 1,
            standardError: "svn: E195013: '/tmp/wc/a.txt' is not locked in this working copy"
        )
        #expect(gone.code == .notLocked)
        #expect(gone.code.severity == .recoverable)

        let stolen = SVNErrorMapper.error(
            exitCode: 1,
            standardError: "svn: warning: W160040: No lock on path '/a.txt' in filesystem 'abc'"
        )
        #expect(stolen.code == .notLocked)
    }

    @Test("a held lock is never reported as a working-copy lock")
    func lockedIsNotCleanup() {
        let error = SVNErrorMapper.error(
            exitCode: 1,
            standardError: "svn: warning: W160035: Path '/a.txt' is already locked by user 'x'"
        )
        #expect(error.code != .workingCopyLocked)
        #expect(error.code.remediation?.contains("清理") != true)
    }
}
