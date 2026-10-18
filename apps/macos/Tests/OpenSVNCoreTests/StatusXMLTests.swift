import Foundation
import Testing
@testable import OpenSVNCore

@Suite("svn status XML")
struct StatusXMLTests {
    @Test("a clean checkout produces no entries")
    func cleanCheckout() throws {
        let snapshot = try SVNXMLParser.parseStatus(TestEnvironment.fixture("svn-status-clean.xml"))
        #expect(snapshot.entries.isEmpty)
        #expect(snapshot.target == "wc-clean")
        #expect(snapshot.conflicted.isEmpty)
        #expect(snapshot.isEmpty)
    }

    @Test("conflicted working copy: every state maps to the right field")
    func conflictedWorkingCopy() throws {
        let snapshot = try SVNXMLParser.parseStatus(TestEnvironment.fixture("svn-status-conflicted.xml"))
        #expect(snapshot.target == "wc-a")

        func entry(_ path: String) throws -> StatusEntry {
            try #require(snapshot.entries.first { $0.path == path })
        }

        // Property-only modification on the working copy root.
        let root = try entry("wc-a")
        #expect(root.item == .normal)
        #expect(root.properties == .modified)
        #expect(root.category == .modified)

        // Text conflict: item="conflicted" → .text, and only .text.
        let locked = try entry("wc-a/docs/locked.txt")
        #expect(locked.item == .conflicted)
        #expect(locked.conflicts == .text)
        #expect(locked.hasConflicts)
        #expect(locked.category == .conflicted)
        #expect(locked.repositoryLock == nil)

        // Text conflict + property modification are independent facts.
        let util = try entry("wc-a/src/util.swift")
        #expect(util.item == .conflicted)
        #expect(util.properties == .modified)
        #expect(util.conflicts == .text)
        #expect(util.revision == 4)

        // Tree conflict: item="added" plus tree-conflicted="true"; must not be
        // reported as a text conflict.
        let tree = try entry("wc-a/docs/tree-conflict.txt")
        #expect(tree.conflicts == .tree)
        #expect(tree.item == .added)
        #expect(tree.isCopied)
        #expect(tree.category == .conflicted)

        // Scheduled delete vs. file absent from disk are different states.
        let deleted = try entry("wc-a/docs/to-delete.txt")
        #expect(deleted.item == .deleted)
        let missing = try entry("wc-a/src/temp-copy.swift")
        #expect(missing.item == .missing)
        #expect(missing.category == .deleted)

        // Non-ASCII path survives parsing byte-for-byte.
        let added = try entry("wc-a/docs/新增文件.txt")
        #expect(added.item == .added)
        let unversioned = try entry("wc-a/docs/未纳入版本控制.txt")
        #expect(unversioned.item == .unversioned)
        #expect(unversioned.category == .unversioned)

        #expect(snapshot.conflicted.count == 3)
        #expect(snapshot.changed.count >= 5)
        #expect(snapshot.missing.count == 1)
    }

    @Test("repository file lock is reported, and is not a working-copy lock")
    func repositoryLock() throws {
        let snapshot = try SVNXMLParser.parseStatus(TestEnvironment.fixture("svn-status-locked.xml"))
        let locked = try #require(snapshot.entries.first { $0.path == "wc-b/docs/repo-locked.txt" })
        let lock = try #require(locked.repositoryLock)
        #expect(lock.owner == "fixture")
        #expect(lock.comment == "fixture lock")
        #expect(lock.token?.hasPrefix("opaquelocktoken:") == true)
        #expect(lock.createdAt != nil)
        #expect(locked.isWorkingCopyLocked == false)
    }

    @Test("malformed XML fails with a classified error, not a crash")
    func malformedXML() {
        do {
            _ = try SVNXMLParser.parseStatus(Data("<status><target".utf8))
            Issue.record("expected parse failure")
        } catch let error as SVNError {
            #expect(error.code == .xmlParseFailure)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

@Suite("conflict and status model")
struct StatusModelTests {
    @Test("conflict flags combine without losing information")
    func conflictFlags() {
        let all: ConflictFlags = [.text, .property, .tree]
        #expect(all.codes == ["text", "property", "tree"])
        #expect(ConflictFlags(codes: ["tree"]) == .tree)
        #expect(ConflictFlags(codes: ["nonsense"]).isEmpty)
        #expect(!all.isEmpty)
    }

    @Test("unknown svn status tokens are preserved rather than dropped")
    func unknownToken() {
        let status = WCItemStatus(rawValue: "future-state")
        #expect(status == .unknown("future-state"))
        #expect(status.rawValue == "future-state")
        #expect(!status.isCommittableChange)
    }

    @Test("category prefers conflict over the underlying item")
    func categoryPrecedence() {
        let entry = StatusEntry(path: "a", item: .modified, conflicts: .text)
        #expect(entry.category == .conflicted)
    }
}
