import Foundation
import Testing
@testable import OpenSVNCore

/// End-to-end tests against a real repository and a real working copy.
///
/// These are the closest thing to the "two working copies complete a sync loop"
/// acceptance criterion for stage 3. They create everything in a temp directory
/// and never touch the developer's repositories.
@Suite("service integration", .enabled(if: TestEnvironment.integrationPrerequisitesMet))
struct ServiceIntegrationTests {

    private struct Fixture {
        let root: URL
        let repository: URL
        let workingCopy: URL
        let service: SVNService
        let installation: SVNInstallation
    }

    private func makeFixture() async throws -> Fixture {
        let svn = try #require(TestEnvironment.svnExecutable)
        let svnadmin = try #require(TestEnvironment.svnadminExecutable)
        let root = try TestEnvironment.makeTemporaryDirectory("integration")
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        let seed = root.appendingPathComponent("seed", isDirectory: true)
        let workingCopy = root.appendingPathComponent("wc", isDirectory: true)

        try FileManager.default.createDirectory(at: seed.appendingPathComponent("trunk/src"), withIntermediateDirectories: true)
        try "# demo\n".write(to: seed.appendingPathComponent("trunk/README.md"), atomically: true, encoding: .utf8)
        try "func main() {}\n".write(to: seed.appendingPathComponent("trunk/src/main.swift"), atomically: true, encoding: .utf8)
        try "你好\n".write(to: seed.appendingPathComponent("trunk/src/中文 文件.txt"), atomically: true, encoding: .utf8)

        let admin = SVNProcessRunner(executableURL: svnadmin, defaultTimeout: 60)
        let create = try await admin.run(SVNInvocation(executableURL: svnadmin, arguments: ["create", repository.path]))
        #expect(create.isSuccess)

        let repoURL = "file://\(repository.path)"
        let runner = SVNProcessRunner(executableURL: svn, defaultTimeout: 60)
        let imported = try await runner.run(SVNInvocation(
            executableURL: svn,
            arguments: ["import", seed.path, repoURL, "-m", "import fixture", "--no-auth-cache"]
        ))
        #expect(imported.isSuccess, "import failed: \(imported.standardError)")

        let installation = try await SVNDiscovery(explicitExecutablePath: svn.path, environment: ProcessInfo.processInfo.environment).resolve()
        let service = SVNService(
            configuration: SVNServiceConfiguration(
                installation: installation,
                credentialStore: InMemoryCredentialStore(),
                environment: ProcessInfo.processInfo.environment,
                timeout: 60,
                // Keep test backups inside the fixture, never in
                // ~/Library/Application Support/OpenSVN.
                conflictBackupRoot: root.appendingPathComponent("backups", isDirectory: true)
            )
        )
        return Fixture(root: root, repository: repository, workingCopy: workingCopy, service: service, installation: installation)
    }

    @Test("checkout → modify → diff → commit → update")
    func roundTrip() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = fixture.service

        // 1. Clean checkout.
        try await service.checkout(
            url: "file://\(fixture.repository.path)/trunk",
            to: fixture.workingCopy
        )
        var status = try await service.status(at: fixture.workingCopy)
        #expect(status.entries.isEmpty)

        let info = try await service.info(at: fixture.workingCopy.path)
        #expect(info.primary?.url.hasSuffix("/trunk") == true)
        #expect(info.primary?.revision == 1)
        #expect(info.primary?.workingCopyRoot?.hasSuffix("/wc") == true)

        // 2. Modify + add a new file with a non-ASCII name.
        let readme = fixture.workingCopy.appendingPathComponent("README.md")
        try "# demo\nmore text\n".write(to: readme, atomically: true, encoding: .utf8)
        let added = fixture.workingCopy.appendingPathComponent("src/新增.txt")
        try "新增内容\n".write(to: added, atomically: true, encoding: .utf8)
        try await service.add([added])

        status = try await service.status(at: fixture.workingCopy)
        let modifiedEntry = try #require(status.entries.first { $0.path.hasSuffix("README.md") })
        #expect(modifiedEntry.item == .modified)
        let addedEntry = try #require(status.entries.first { $0.path.hasSuffix("新增.txt") })
        #expect(addedEntry.item == .added)

        // 3. Local diff.
        let diff = try await service.diffWorkingCopy(at: readme)
        #expect(diff.text.contains("+more text"))
        #expect(!diff.isTruncated)

        // 4. Commit message validation is enforced by the service.
        do {
            _ = try await service.commit([readme, added], message: "   ")
            Issue.record("expected invalidInvocation")
        } catch let error as SVNError {
            #expect(error.code == .invalidInvocation)
        }

        let commit = try await service.commit([readme, added], message: "第二轮：修改 README 并新增文件")
        #expect(commit.revision == 2)

        // 5. Status is clean again and update reports the new revision.
        status = try await service.status(at: fixture.workingCopy)
        #expect(status.changed.isEmpty)
        let update = try await service.update(at: fixture.workingCopy)
        #expect(update.toRevision == 2)

        // 6. History includes both revisions, newest first.
        let log = try await service.log(at: fixture.workingCopy.path, limit: 10)
        #expect(log.entries.count == 2)
        #expect(log.entries.first?.revision == 2)
        #expect(log.entries.first?.message.contains("第二轮") == true)
        #expect(log.entries.first?.changedPaths.isEmpty == false)
    }

    @Test("destructive operations require confirmation at the service layer")
    func destructiveConfirmation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = fixture.service

        try await service.checkout(url: "file://\(fixture.repository.path)/trunk", to: fixture.workingCopy)
        let readme = fixture.workingCopy.appendingPathComponent("README.md")
        try "# changed\n".write(to: readme, atomically: true, encoding: .utf8)

        do {
            _ = try await service.commit([readme], message: "should not happen")
        } catch {
            Issue.record("commit should be allowed: \(error)")
        }

        // Fresh modification, then attempt revert without confirmation.
        try "# changed again\n".write(to: readme, atomically: true, encoding: .utf8)
        do {
            try await service.revert([readme], confirmed: false)
            Issue.record("expected confirmationRequired")
        } catch let error as SVNError {
            #expect(error.code == .confirmationRequired)
        }
        let preview = try await service.previewRevert([readme])
        #expect(preview.risk == .high)
        #expect(preview.discardedPaths.count == 1)

        // Confirmed revert discards the local change.
        try await service.revert([readme], confirmed: true)
        let status = try await service.status(at: fixture.workingCopy)
        #expect(status.changed.isEmpty)

        // Delete without confirmation is refused too.
        do {
            try await service.delete([readme], confirmed: false)
            Issue.record("expected confirmationRequired")
        } catch let error as SVNError {
            #expect(error.code == .confirmationRequired)
        }
    }

    @Test("cleanup is safe on a healthy working copy")
    func cleanup() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.service.checkout(url: "file://\(fixture.repository.path)/trunk", to: fixture.workingCopy)
        try await fixture.service.cleanup(at: fixture.workingCopy)
        let status = try await fixture.service.status(at: fixture.workingCopy)
        #expect(status.entries.isEmpty)
    }

    @Test("resolve refuses destructive strategies without confirmation")
    func resolveConfirmation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.service.checkout(url: "file://\(fixture.repository.path)/trunk", to: fixture.workingCopy)
        let readme = fixture.workingCopy.appendingPathComponent("README.md")

        do {
            try await fixture.service.resolve([readme], strategy: .theirsFull, confirmed: false)
            Issue.record("expected confirmationRequired")
        } catch let error as SVNError {
            #expect(error.code == .confirmationRequired)
        }

        // `working` is non-destructive and therefore allowed without the flag.
        // It is a no-op on a file without conflicts, which is exactly the point:
        // the guard is about data loss, not about svn's own checks.
        try await fixture.service.resolve([readme], strategy: .working, confirmed: false)
    }

    @Test("resolve copies the conflicted file aside before overwriting it")
    func resolveTakesBackup() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = fixture.service
        let repoURL = "file://\(fixture.repository.path)/trunk"
        try await service.checkout(url: repoURL, to: fixture.workingCopy)

        // Another working copy pushes a change to the same file...
        let other = fixture.root.appendingPathComponent("wc-other", isDirectory: true)
        try await service.checkout(url: repoURL, to: other)
        let otherReadme = other.appendingPathComponent("README.md")
        try "# from the server\n".write(to: otherReadme, atomically: true, encoding: .utf8)
        _ = try await service.commit([otherReadme], message: "server side")

        // ...while this one has an uncommitted edit.
        let readme = fixture.workingCopy.appendingPathComponent("README.md")
        try "# local edit\n".write(to: readme, atomically: true, encoding: .utf8)
        _ = try await service.update(at: fixture.workingCopy)

        let status = try await service.status(at: fixture.workingCopy)
        #expect(status.conflicted.contains { $0.path.hasSuffix("README.md") })

        // `theirs-full` destroys the local edit; the backup must be the copy
        // that still has it.
        let outcome = try await service.resolve([readme], strategy: .theirsFull, confirmed: true)
        let backup = try #require(outcome.backup)
        let saved = try #require(
            backup.entries.first { $0.sourcePath == readme.standardizedFileURL.path }
        )
        let savedText = try String(contentsOfFile: saved.backupPath, encoding: .utf8)
        #expect(savedText.contains("local edit"))

        let resolved = try String(contentsOf: readme, encoding: .utf8)
        #expect(resolved.contains("from the server"))
        #expect(outcome.pathsWithResidualMarkers.isEmpty)
    }

    @Test("three-way merge: decide per region, write, then mark resolved")
    func mergeEditorRoundTrip() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = fixture.service
        let repoURL = "file://\(fixture.repository.path)/trunk"
        try await service.checkout(url: repoURL, to: fixture.workingCopy)

        // Build a conflict with two separate regions, so the test has to make
        // more than one decision.
        let readme = fixture.workingCopy.appendingPathComponent("README.md")
        try "line1\nline2\nline3\nline4\nline5\n".write(to: readme, atomically: true, encoding: .utf8)
        _ = try await service.commit([readme], message: "baseline for merge")

        let other = fixture.root.appendingPathComponent("wc-other", isDirectory: true)
        try await service.checkout(url: repoURL, to: other)
        let otherReadme = other.appendingPathComponent("README.md")
        try "line1\nSERVER2\nline3\nline4\nSERVER5\n".write(to: otherReadme, atomically: true, encoding: .utf8)
        _ = try await service.commit([otherReadme], message: "server side")

        try "line1\nLOCAL2\nline3\nline4\nLOCAL5\n".write(to: readme, atomically: true, encoding: .utf8)
        _ = try await service.update(at: fixture.workingCopy)

        // 1. The service can name the three versions without guessing.
        let artifacts = try #require(try await service.conflictArtifacts(for: readme))
        #expect(artifacts.supportsMerge)
        let baseURL = try #require(artifacts.base)
        let mineURL = try #require(artifacts.mine)
        let theirsURL = try #require(artifacts.theirs)
        #expect(try String(contentsOf: mineURL, encoding: .utf8).contains("LOCAL2"))
        #expect(try String(contentsOf: theirsURL, encoding: .utf8).contains("SERVER2"))
        #expect(try String(contentsOf: baseURL, encoding: .utf8).contains("line2"))

        // 2. Merge and decide: mine for the first region, theirs for the second.
        let result = ThreeWayMerge.merge(
            base: try String(contentsOf: baseURL, encoding: .utf8),
            mine: try String(contentsOf: mineURL, encoding: .utf8),
            theirs: try String(contentsOf: theirsURL, encoding: .utf8)
        )
        #expect(result.conflicts.count == 2)
        let merged = try result.render([0: .mine, 1: .theirs])
        #expect(merged == "line1\nLOCAL2\nline3\nline4\nSERVER5\n")

        // 3. Backup first, then write, then resolve with the file as the answer.
        let backup = try await service.backupConflictArtifacts(for: [readme], reason: "test")
        #expect(backup?.entries.contains { $0.sourcePath == readme.standardizedFileURL.path } == true)

        try merged.write(to: readme, atomically: true, encoding: .utf8)
        let outcome = try await service.resolve([readme], strategy: .working, confirmed: true)
        #expect(outcome.pathsWithResidualMarkers.isEmpty)

        // 4. The working copy is clean and the repository has the merged text.
        let status = try await service.status(at: fixture.workingCopy)
        #expect(status.conflicted.isEmpty)
        #expect(status.entries.isEmpty == false)   // the local side still needs committing
        _ = try await service.commit([readme], message: "merged")
        let committed = try await service.update(at: fixture.workingCopy)
        _ = committed
        #expect(try String(contentsOf: readme, encoding: .utf8) == merged)
    }

    @Test("properties: ignore a file, round-trip a custom property, delete it")
    func propertiesRoundTrip() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = fixture.service
        try await service.checkout(
            url: "file://\(fixture.repository.path)/trunk",
            to: fixture.workingCopy
        )

        // An untracked artefact starts out as `?`, which is exactly the state the
        // ignore action is meant to fix.
        let artefact = fixture.workingCopy.appendingPathComponent("build.log")
        try "noise\n".write(to: artefact, atomically: true, encoding: .utf8)
        var snapshot = try await service.status(at: fixture.workingCopy)
        #expect(snapshot.entries.contains { $0.path.hasSuffix("build.log") && $0.item == .unversioned })

        let first = try await service.ignore([artefact])
        #expect(first.added == ["build.log"])
        #expect(first.already.isEmpty)

        // Default `svn status` hides ignored paths, so absence is the assertion.
        snapshot = try await service.status(at: fixture.workingCopy)
        #expect(!snapshot.entries.contains { $0.path.hasSuffix("build.log") })
        let ignoreValue = try await service.propertyValue(of: "svn:ignore", at: fixture.workingCopy)
        // svn normalises the value to end with a newline, so compare the decoded
        // entry list rather than the raw string.
        #expect(IgnoreList.entries(ignoreValue) == ["build.log"])

        // Doing it twice must not rewrite the property: an unchanged propset
        // still marks the directory modified.
        let second = try await service.ignore([artefact])
        #expect(second.added.isEmpty)
        #expect(second.already == ["build.log"])

        // Multi-line and leading-dash values travel through a file, not argv.
        let readme = fixture.workingCopy.appendingPathComponent("README.md")
        try await service.setProperty(
            name: "custom:owner",
            value: "平台组\n--not-an-option",
            on: [readme]
        )
        let owner = try await service.propertyValue(of: "custom:owner", at: readme)
        #expect(owner == "平台组\n--not-an-option")

        let removed = try await service.deleteProperty(name: "custom:owner", on: [readme])
        #expect(removed == 1)
        let gone = try await service.propertyValue(of: "custom:owner", at: readme)
        #expect(gone == nil)

        // Deleting something that is not there is a no-op, not a failure: the
        // UI deletes from a selection that may only partly have the property.
        let again = try await service.deleteProperty(name: "custom:owner", on: [readme])
        #expect(again == 0)

        // Invalid names fail before an svn process is spawned.
        await #expect(throws: SVNError.self) {
            try await service.setProperty(name: "owner", value: "x", on: [readme])
        }
    }

    @Test("lock is visible to a second working copy and only one of them may hold it")
    func locking() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = fixture.service
        let repoURL = "file://\(fixture.repository.path)/trunk"
        try await service.checkout(url: repoURL, to: fixture.workingCopy)

        let readme = fixture.workingCopy.appendingPathComponent("README.md")
        let locked = try await service.lock([readme], comment: "编辑中")
        #expect(locked.lockedPaths.count == 1)
        #expect(locked.owner != nil)

        let own = try await service.locks(at: fixture.workingCopy)
        #expect(own.lock(for: readme.path)?.comment == "编辑中")
        #expect(own.isOwnLock(for: readme.path))

        // A second checkout sees the lock, does not own it, and cannot take it
        // without --force.
        let second = fixture.root.appendingPathComponent("wc2", isDirectory: true)
        try await service.checkout(url: repoURL, to: second)
        let secondReadme = second.appendingPathComponent("README.md")

        let foreign = try await service.locks(at: second)
        #expect(foreign.lock(for: secondReadme.path) != nil)
        #expect(!foreign.isOwnLock(for: secondReadme.path))
        #expect(foreign.foreignLocks(among: [secondReadme.path]) == [secondReadme.path])

        do {
            _ = try await service.lock([secondReadme], comment: "抢")
            Issue.record("locking a path someone else holds must fail")
        } catch let error as SVNError {
            #expect(error.code == .pathLocked)
        }

        // The service enforces the confirmation, not just the dialog.
        do {
            _ = try await service.lock([secondReadme], steal: true, confirmed: false)
            Issue.record("stealing without confirmation must be refused")
        } catch let error as SVNError {
            #expect(error.code == .confirmationRequired)
        }

        let unlocked = try await service.unlock([readme])
        #expect(unlocked.unlockedPaths.count == 1)
        let after = try await service.locks(at: fixture.workingCopy)
        #expect(after.lock(for: readme.path) == nil)
    }

    @Test("the update preview names the incoming revision and the paths, without changing anything")
    func remotePreview() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = fixture.service
        let repoURL = "file://\(fixture.repository.path)/trunk"

        try await service.checkout(url: repoURL, to: fixture.workingCopy)
        let second = fixture.root.appendingPathComponent("wc2", isDirectory: true)
        try await service.checkout(url: repoURL, to: second)

        // The first working copy commits, so the second is now behind.
        let readme = fixture.workingCopy.appendingPathComponent("README.md")
        try "# changed on server\n".write(to: readme, atomically: true, encoding: .utf8)
        _ = try await service.commit([readme], message: "server edit")

        let before = try await service.status(at: second)
        let preview = try await service.remotePreview(at: second)
        #expect(!preview.isEmpty)
        #expect(preview.serverRevision != nil)
        #expect(preview.changes.contains {
            $0.path.hasSuffix("README.md") && $0.item == WCItemStatus.modified
        })
        // Nothing local in the second copy yet, so nothing can collide.
        #expect(!preview.hasConflictsWithLocal)

        // Reading the preview must not have touched the working copy.
        let after = try await service.status(at: second)
        #expect(after.entries.count == before.entries.count)

        // Edit the same file locally: now the update has something to collide with.
        let secondReadme = second.appendingPathComponent("README.md")
        try "# local edit\n".write(to: secondReadme, atomically: true, encoding: .utf8)
        let risky = try await service.remotePreview(at: second)
        #expect(risky.conflictRisks.contains { $0.path.hasSuffix("README.md") })
    }

}

@Suite("write serialization")
struct WriteGateTests {
    private actor PeakTracker {
        private var current = 0
        private var peak = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func exit() {
            current -= 1
        }

        func peakValue() -> Int { peak }
    }

    @Test("writes on one working copy never overlap")
    func serialized() async {
        let gate = WCWriteGate()
        let tracker = PeakTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try? await gate.withLock("wc-root") {
                        await tracker.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await tracker.exit()
                    }
                }
            }
        }

        let peak = await tracker.peakValue()
        let stillBusy = await gate.isBusy("wc-root")
        #expect(peak == 1)
        #expect(!stillBusy)
    }

    @Test("different working copies are not blocked by each other")
    func independentKeys() async {
        let gate = WCWriteGate()
        await gate.acquire("a")
        var busyA = await gate.isBusy("a")
        var busyB = await gate.isBusy("b")
        #expect(busyA)
        #expect(!busyB)
        await gate.acquire("b")
        busyA = await gate.isBusy("a")
        busyB = await gate.isBusy("b")
        #expect(busyB)
        #expect(busyA)
        await gate.release("a")
        await gate.release("b")
    }

    @Test("working copy root is found by walking up to .svn")
    func locator() throws {
        let directory = try TestEnvironment.makeTemporaryDirectory("locator")
        defer { try? FileManager.default.removeItem(at: directory) }
        let wcRoot = directory.appendingPathComponent("wc", isDirectory: true)
        let nested = wcRoot.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wcRoot.appendingPathComponent(".svn"), withIntermediateDirectories: true)

        #expect(WorkingCopyLocator.root(for: nested)?.path == wcRoot.path)
        #expect(WorkingCopyLocator.serializationKey(for: nested) == wcRoot.path)
        #expect(WorkingCopyLocator.root(for: directory) == nil)
    }
}
