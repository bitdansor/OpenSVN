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
                timeout: 60
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
