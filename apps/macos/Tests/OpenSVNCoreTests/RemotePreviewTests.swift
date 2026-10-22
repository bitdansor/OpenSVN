import Foundation
import Testing
@testable import OpenSVNCore

@Suite("remote update preview")
struct RemotePreviewTests {
    private func fixtureSnapshot() throws -> StatusSnapshot {
        try SVNXMLParser.parseStatus(
            TestEnvironment.fixture("svn-status-remote-changes.xml")
        )
    }

    @Test("a directory is not counted alongside the child that changed")
    func directoryDeduplication() {
        let directory = StatusEntry(path: "docs", item: .normal, remoteItem: .modified)
        let child = StatusEntry(path: "docs/a.md", item: .normal, remoteItem: .modified)
        let preview = RemotePreview.make(
            from: StatusSnapshot(target: ".", entries: [directory, child])
        )
        #expect(preview.changes.map(\.path) == ["docs/a.md"])
        #expect(preview.modifiedCount == 1)
    }

    @Test("a directory whose own properties changed is still listed")
    func directoryPropertyChange() {
        let directory = StatusEntry(
            path: "docs",
            item: .normal,
            remoteItem: .modified,
            remoteProperties: .modified
        )
        let child = StatusEntry(path: "docs/a.md", item: .normal, remoteItem: .modified)
        let preview = RemotePreview.make(
            from: StatusSnapshot(target: ".", entries: [directory, child])
        )
        #expect(preview.changes.map(\.path) == ["docs", "docs/a.md"])
    }

    @Test("repos-status carries the server side, wc-status the local side")
    func parsing() throws {
        let snapshot = try fixtureSnapshot()
        #expect(snapshot.serverRevision == 2)

        let added = snapshot.entries.first { $0.path == "n.txt" }
        #expect(added?.remoteItem == .added)
        // Spelled out: `== .none` on an `Optional<WCItemStatus>` resolves to
        // `Optional.none` (nil), not to the `.none` case meaning "no change".
        #expect(added?.item == WCItemStatus.none)

        let modified = snapshot.entries.first { $0.path == "a.txt" }
        #expect(modified?.remoteItem == .modified)
        #expect(modified?.item == .modified)

        let deleted = snapshot.entries.first { $0.path == "b.txt" }
        #expect(deleted?.remoteItem == .deleted)
        #expect(deleted?.item == .normal)
    }

    @Test("the working-copy root is not counted as one more change")
    func rootEntryExcluded() throws {
        let preview = RemotePreview.make(from: try fixtureSnapshot())
        // Four entries in the fixture, one of which is "."
        #expect(preview.changes.count == 3)
        #expect(preview.changes.allSatisfy { $0.path != "." })
        #expect(preview.addedCount == 1)
        #expect(preview.modifiedCount == 1)
        #expect(preview.deletedCount == 1)
        #expect(preview.serverRevision == 2)
    }

    @Test("a path edited on both sides is reported as a conflict risk")
    func conflictRisk() throws {
        let preview = RemotePreview.make(from: try fixtureSnapshot())
        #expect(preview.hasConflictsWithLocal)
        #expect(preview.conflictRisks.map(\.path) == ["a.txt"])

        // Incoming content at a path we never touched is not a risk.
        #expect(preview.changes.first { $0.path == "n.txt" }?.conflictsWithLocal == false)
        #expect(preview.changes.first { $0.path == "b.txt" }?.conflictsWithLocal == false)
    }

    @Test("no repos-status means the server has nothing new")
    func unchangedOnServer() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <status><target path="."><against revision="7"/></target></status>
        """
        let preview = RemotePreview.make(
            from: try SVNXMLParser.parseStatus(Data(xml.utf8))
        )
        #expect(preview.isEmpty)
        #expect(preview.serverRevision == 7)
        #expect(preview.conflictRisks.isEmpty)
    }

    @Test("without --show-updates there is no server revision to name")
    func noServerRevision() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <status><target path=".">
        <entry path="a.txt"><wc-status item="modified" props="none"/></entry>
        </target></status>
        """
        let preview = RemotePreview.make(
            from: try SVNXMLParser.parseStatus(Data(xml.utf8))
        )
        #expect(preview.serverRevision == nil)
        #expect(preview.isEmpty)
    }

    @Test("a property-only change counts as a modification")
    func propertyOnly() {
        let entry = StatusEntry(
            path: "x.txt",
            item: .normal,
            properties: .normal,
            // Explicit: `.none` here would bind to `Optional.none` (nil).
            remoteItem: WCItemStatus.none,
            remoteProperties: .modified
        )
        let preview = RemotePreview.make(
            from: StatusSnapshot(target: ".", entries: [entry])
        )
        #expect(preview.changes.count == 1)
        #expect(preview.modifiedCount == 1)
        #expect(preview.deletedCount == 0)
        #expect(preview.changes[0].isPropertyOnly)
    }

    @Test("a local delete against a remote edit is a tree-conflict risk")
    func localDelete() {
        let entry = StatusEntry(path: "y.txt", item: .deleted, remoteItem: .modified)
        let preview = RemotePreview.make(
            from: StatusSnapshot(target: ".", entries: [entry])
        )
        #expect(preview.hasConflictsWithLocal)
    }

    @Test("an incoming add colliding with an unversioned file is a risk")
    func incomingAddVersusUnversioned() {
        let entry = StatusEntry(path: "z.txt", item: .unversioned, remoteItem: .added)
        let preview = RemotePreview.make(
            from: StatusSnapshot(target: ".", entries: [entry])
        )
        #expect(preview.hasConflictsWithLocal)
    }

    @Test("a property change on the root is kept, item changes are not")
    func rootPropertyChange() {
        let root = StatusEntry(
            path: ".",
            item: .normal,
            // Explicit: `.none` here would bind to `Optional.none` (nil).
            remoteItem: WCItemStatus.none,
            remoteProperties: .modified
        )
        let preview = RemotePreview.make(
            from: StatusSnapshot(target: ".", entries: [root])
        )
        #expect(preview.changes.isEmpty)
        #expect(preview.rootPropertyChange != nil)
        #expect(!preview.isEmpty)
    }
}

@Suite("working copy watcher filter")
struct WatchFilterTests {
    @Test("changes inside .svn never trigger a refresh")
    func ignoresMetadataDirectory() {
        #expect(!WatchFilter.isRelevant(path: "/wc/.svn/wc.db"))
        #expect(!WatchFilter.isRelevant(path: "/wc/.svn"))
        #expect(!WatchFilter.isRelevant(paths: ["/wc/.svn/wc.db", "/wc/.svn/pristine/aa"]))
    }

    @Test("one real file change is enough to be relevant")
    func acceptsWorkingFiles() {
        #expect(WatchFilter.isRelevant(path: "/wc/src/a.txt"))
        #expect(WatchFilter.isRelevant(paths: ["/wc/.svn/wc.db", "/wc/src/a.txt"]))
    }

    @Test("a file that merely starts with .svn is still a working file")
    func lookalikeNames() {
        #expect(WatchFilter.isRelevant(path: "/wc/docs/.svn-guide.md"))
        #expect(WatchFilter.isRelevant(path: "/wc/.svnignore"))
    }

    @Test("an empty batch is not a reason to refresh")
    func emptyBatch() {
        #expect(!WatchFilter.isRelevant(paths: []))
    }
}

@Suite("credential scope keys")
struct CredentialScopeTests {
    @Test("a storage key round-trips")
    func roundTrip() {
        let plain = CredentialScope(host: "svn.example.com")
        #expect(plain.storageKey == "svn.example.com")
        #expect(CredentialScope(storageKey: plain.storageKey) == plain)

        let withRealm = CredentialScope(host: "svn.example.com", realm: "repo")
        #expect(withRealm.storageKey == "svn.example.com|repo")
        #expect(CredentialScope(storageKey: withRealm.storageKey) == withRealm)
        #expect(CredentialScope(storageKey: "host").realm == nil)
    }

    @Test("a realm containing the separator survives")
    func realmWithSeparator() {
        let scope = CredentialScope(host: "h", realm: "a|b")
        #expect(CredentialScope(storageKey: scope.storageKey) == scope)
    }
}
