import Foundation
import Testing
@testable import OpenSVNCore

/// The demo is a product surface, not a fixture: if it does not produce a mix of
/// automatic merges and a real decision, the guide built on top of it is lying to
/// the user. These tests assert that mix, not merely that files appeared.
@Suite("demo workspace", .enabled(if: TestEnvironment.integrationPrerequisitesMet))
struct DemoWorkspaceTests {

    private func makeService(svn: URL) async throws -> SVNService {
        let installation = try await SVNDiscovery(
            explicitExecutablePath: svn.path,
            environment: ProcessInfo.processInfo.environment
        ).resolve()
        return SVNService(
            configuration: SVNServiceConfiguration(
                installation: installation,
                credentialStore: InMemoryCredentialStore(),
                environment: ProcessInfo.processInfo.environment,
                timeout: 60,
                conflictBackupRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("opensvn-demo-backups", isDirectory: true)
            )
        )
    }

    @Test("the sample separates automatic merges from the one real decision")
    func generatedSampleExercisesAutoMerge() async throws {
        let svn = try #require(TestEnvironment.svnExecutable)
        let svnadmin = try #require(TestEnvironment.svnadminExecutable)
        let root = try TestEnvironment.makeTemporaryDirectory("demo")
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = DemoWorkspace(root: root, svn: svn, svnadmin: svnadmin)
        let result = try await workspace.build()
        #expect(WorkingCopyLocator.isWorkingCopy(result.workingCopy))

        let service = try await makeService(svn: svn)
        let status = try await service.status(at: result.workingCopy)
        let conflicted = status.entries.filter(\.hasConflicts)

        #expect(conflicted.count == 4, "expected 3 text + 1 property conflict, got \(status.entries.map(\.path))")
        #expect(conflicted.filter { $0.conflicts.contains(.text) }.count == 3)
        #expect(conflicted.filter { $0.conflicts.contains(.property) }.count == 1)

        // The file only the server changed must have been updated silently.
        let util = result.workingCopy.appendingPathComponent("src/util.swift")
        let utilText = try String(contentsOf: util, encoding: .utf8)
        #expect(utilText.contains("Swift.min(Swift.max"))
        #expect(!status.entries.contains { $0.path.hasSuffix("util.swift") })

        // calculator.swift: three regions merge by themselves, one needs a choice.
        let calculator = try #require(status.entries.first { $0.path.hasSuffix("calculator.swift") })
        let artifacts = try #require(
            try await service.conflictArtifacts(for: URL(fileURLWithPath: calculator.path))
        )
        #expect(artifacts.supportsMerge)

        let base = try String(contentsOf: #require(artifacts.base), encoding: .utf8)
        let mine = try String(contentsOf: #require(artifacts.mine), encoding: .utf8)
        let theirs = try String(contentsOf: #require(artifacts.theirs), encoding: .utf8)
        let merged = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)

        #expect(merged.conflicts.count == 1, "the sample is meant to leave exactly one decision")

        let rendered = try #require(try? merged.render([0: .mine]))
        // Taken from me, because only I changed it.
        #expect(rendered.contains("本地版本"))
        #expect(rendered.contains("func divide"))
        // Taken from the server, because only the server changed it.
        #expect(rendered.contains("避免 -0"))
        // The one region under decision does not silently use the other side.
        #expect(!rendered.contains("短路"))
    }

    @Test("a property conflict advertises that it cannot be three-way merged")
    func propertyConflictIsNotMergeable() async throws {
        let svn = try #require(TestEnvironment.svnExecutable)
        let svnadmin = try #require(TestEnvironment.svnadminExecutable)
        let root = try TestEnvironment.makeTemporaryDirectory("demo-property")
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = DemoWorkspace(root: root, svn: svn, svnadmin: svnadmin)
        let result = try await workspace.build()

        let service = try await makeService(svn: svn)
        let status = try await service.status(at: result.workingCopy)
        let property = try #require(status.entries.first { $0.path.hasSuffix("属性冲突.txt") })
        let artifacts = try await service.conflictArtifacts(for: URL(fileURLWithPath: property.path))

        // nil means "no text conflict copies"; the guide must say so rather than
        // offering a merge editor that would fail on open.
        #expect(artifacts?.supportsMerge != true)
    }

    @Test("refuses to touch an existing folder it did not create")
    func refusesForeignFolder() async throws {
        let root = try TestEnvironment.makeTemporaryDirectory("demo-foreign")
        defer { try? FileManager.default.removeItem(at: root) }
        let precious = root.appendingPathComponent("我的笔记.txt")
        try "别删我\n".write(to: precious, atomically: true, encoding: .utf8)

        let workspace = DemoWorkspace(
            root: root,
            svn: try #require(TestEnvironment.svnExecutable),
            svnadmin: try #require(TestEnvironment.svnadminExecutable)
        )

        await #expect(throws: SVNError.self) {
            _ = try await workspace.build()
        }
        #expect(FileManager.default.fileExists(atPath: precious.path))
        let text = try String(contentsOf: precious, encoding: .utf8)
        #expect(text == "别删我\n")
    }
}
