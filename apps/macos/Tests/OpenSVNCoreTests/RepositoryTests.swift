import Foundation
import Testing
@testable import OpenSVNCore

@Suite("repository listing")
struct RepositoryListingTests {
    private func fixture() throws -> RepositoryListing {
        try SVNXMLParser.parseList(TestEnvironment.fixture("svn-list.xml"))
    }

    @Test("directories and files are read with their metadata")
    func parsing() throws {
        let listing = try fixture()
        #expect(listing.entries.count == 2)
        #expect(listing.path.hasSuffix("/trunk"))

        let readme = try #require(listing.entries.first { $0.name == "readme.md" })
        #expect(readme.kind == .file)
        #expect(readme.size == 6)
        #expect(readme.revision == 1)
        #expect(readme.author == "fixture")
        #expect(readme.isDirectory == false)

        let sub = try #require(listing.entries.first { $0.name == "sub" })
        #expect(sub.kind == .dir)
        // svn emits no <size> for a directory; nil must not become 0.
        #expect(sub.size == nil)
        #expect(sub.isDirectory)
    }

    @Test("directories sort before files, then alphabetically")
    func sorting() throws {
        var listing = try fixture()
        listing.entries.append(RemoteEntry(name: "aaa.txt", kind: .file))
        listing.entries.append(RemoteEntry(name: "zzz", kind: .dir))
        #expect(listing.sortedEntries.map(\.name) == ["sub", "zzz", "aaa.txt", "readme.md"])
    }
}

@Suite("repository path")
struct RepositoryPathTests {
    private let root = "https://svn.example.com/repo"

    @Test("components are relative to the repository root")
    func components() {
        let path = RepositoryPath(url: root + "/trunk/src", rootURL: root)
        #expect(path.components == ["trunk", "src"])
        #expect(path.lastComponent == "src")
    }

    @Test("the breadcrumb starts at the repository root")
    func breadcrumb() {
        let path = RepositoryPath(url: root + "/trunk/src", rootURL: root)
        let items = path.breadcrumb()
        #expect(items.map(\.name) == ["repo", "trunk", "src"])
        #expect(items[0].path.url == root)
        #expect(items[2].path.url == root + "/trunk/src")
    }

    @Test("parent stops at the root instead of walking past it")
    func parent() {
        let path = RepositoryPath(url: root + "/trunk", rootURL: root)
        let parent = path.parent()
        #expect(parent?.url == root)
        // Above the repository root there is no directory to go to.
        #expect(parent?.parent() == nil)

        let atRoot = RepositoryPath(url: root, rootURL: root)
        #expect(atRoot.parent() == nil)
    }

    @Test("appending keeps the root and never doubles the slash")
    func appending() {
        let path = RepositoryPath(url: root + "/", rootURL: root)
        #expect(path.appending("trunk").url == root + "/trunk")
        #expect(path.appending("trunk").rootURL == root)
    }

    @Test("without a known root the host is the base")
    func withoutRoot() {
        let path = RepositoryPath(url: root + "/trunk/sub")
        #expect(path.baseURL == "https://svn.example.com")
        #expect(path.components == ["repo", "trunk", "sub"])
    }
}

@Suite("remote commit output")
struct RemoteCommitTests {
    @Test("the revision is read from svn's line")
    func revisionParsing() {
        #expect(RemoteCommit.parseRevision("Committing transaction...\nCommitted revision 12.\n") == 12)
        #expect(RemoteCommit.parseRevision("Committed revision 1.") == 1)
    }

    @Test("a missing revision is nil, not zero")
    func missingRevision() {
        #expect(RemoteCommit.parseRevision("") == nil)
        #expect(RemoteCommit.parseRevision("Committed revision .") == nil)
        // The exit code is the contract; the message is a convenience.
        #expect(RemoteCommit.parseRevision("svn: something else") == nil)
    }
}

@Suite("changelist and externals in status")
struct ChangelistStatusTests {
    private func snapshot() throws -> StatusSnapshot {
        try SVNXMLParser.parseStatus(TestEnvironment.fixture("svn-status-changelist.xml"))
    }

    @Test("changelist members are parsed, not dropped")
    func changelistMembersSurvive() throws {
        let snapshot = try snapshot()
        // One entry lives under <target>, the other under <changelist>. A parser
        // that reads only <target> loses half the working copy with no error.
        #expect(snapshot.entries.count == 2)
        let names = Set(snapshot.entries.map(\.path))
        #expect(names.contains("trunk/readme.md"))
        #expect(names.contains("trunk/sub/b.txt"))
    }

    @Test("the changelist name lands on the entry")
    func changelistName() throws {
        let snapshot = try snapshot()
        let member = try #require(snapshot.entries.first { $0.path == "trunk/readme.md" })
        #expect(member.changelist == "ui-review")
        let loose = try #require(snapshot.entries.first { $0.path == "trunk/sub/b.txt" })
        #expect(loose.changelist == nil)
    }
}

@Suite("externals")
struct ExternalsTests {
    @Test("paths below an external mount are recognised")
    func insideExternal() {
        let roots = ["/wc/shared", "/wc/vendor"]
        let entry = StatusEntry(path: "/wc/shared/b.txt", item: .modified)
        #expect(entry.isInsideExternal(roots))

        // The mount point itself is not "inside" itself: it is the external.
        let mount = StatusEntry(path: "/wc/shared", item: .external)
        #expect(!mount.isInsideExternal(roots))

        let own = StatusEntry(path: "/wc/own.txt", item: .modified)
        #expect(!own.isInsideExternal(roots))

        // A sibling whose name merely starts with the root's name is not below it.
        let sibling = StatusEntry(path: "/wc/shared-notes.md", item: .modified)
        #expect(!sibling.isInsideExternal(roots))
    }

    @Test("an external is its own category, never 'ignored'")
    func category() {
        let mount = StatusEntry(path: "/wc/shared", item: .external)
        #expect(mount.category == .external)
        let ignored = StatusEntry(path: "/wc/tmp/", item: .ignored)
        #expect(ignored.category == .ignored)
    }

    @Test("changes inside an external are not committable here")
    func committable() {
        let snapshot = StatusSnapshot(entries: [
            StatusEntry(path: "/wc/shared", item: .external),
            StatusEntry(path: "/wc/shared/b.txt", item: .modified),
            StatusEntry(path: "/wc/mine.txt", item: .modified),
            StatusEntry(path: "/wc/conflicted.txt", item: .conflicted)
        ])
        #expect(snapshot.externalRoots == ["/wc/shared"])
        #expect(snapshot.committable.map(\.path) == ["/wc/mine.txt"])
    }

    @Test("without externals nothing is excluded")
    func noExternals() {
        let snapshot = StatusSnapshot(entries: [
            StatusEntry(path: "/wc/a.txt", item: .modified),
            StatusEntry(path: "/wc/b.txt", item: .added)
        ])
        #expect(snapshot.externalRoots.isEmpty)
        #expect(snapshot.committable.count == 2)
    }
}
