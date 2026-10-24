import Foundation
import Testing
@testable import OpenSVNCore

@Suite("history filter")
struct LogFilterTests {
    private func entry(
        _ revision: Int64,
        author: String? = "alice",
        message: String = "",
        paths: [String] = [],
        daysAgo: Int = 0
    ) -> LogEntry {
        LogEntry(
            revision: revision,
            author: author,
            date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()),
            message: message,
            changedPaths: paths.map { ChangedPath(path: $0, action: .modified) }
        )
    }

    private var sample: [LogEntry] {
        [
            entry(120, author: "alice", message: "修复登录超时", paths: ["src/auth/session.swift"], daysAgo: 1),
            entry(119, author: "bob", message: "更新 README", paths: ["README.md"], daysAgo: 5),
            entry(118, author: "alice", message: "增加重试退避", paths: ["src/net/retry.swift"], daysAgo: 40)
        ]
    }

    @Test("an empty filter keeps everything")
    func empty() {
        let filter = LogFilter()
        #expect(filter.isEmpty)
        #expect(filter.apply(to: sample).count == 3)
        #expect(filter.serverSearchPattern == nil)
    }

    @Test("free text matches the message")
    func messageText() {
        #expect(LogFilter(text: "重试").apply(to: sample).map(\.revision) == [118])
    }

    @Test("free text matches the author and the changed path")
    func authorAndPathText() {
        #expect(LogFilter(text: "bob").apply(to: sample).map(\.revision) == [119])
        #expect(LogFilter(text: "session").apply(to: sample).map(\.revision) == [120])
    }

    @Test("a revision number is searchable as rN")
    func revisionText() {
        #expect(LogFilter(text: "r119").apply(to: sample).map(\.revision) == [119])
    }

    @Test("all whitespace-separated terms must match")
    func conjunction() {
        #expect(LogFilter(text: "alice retry").apply(to: sample).map(\.revision) == [118])
        #expect(LogFilter(text: "bob retry").apply(to: sample).isEmpty)
    }

    @Test("author is exact, not a substring")
    func authorIsExact() {
        // "ali" must not match "alice": a field filter that behaves like a text
        // search is two different features wearing one label.
        #expect(LogFilter(author: "ali").apply(to: sample).isEmpty)
        #expect(LogFilter(author: "alice").apply(to: sample).map(\.revision) == [120, 118])
    }

    @Test("path matches any changed path, case-insensitively")
    func path() {
        #expect(LogFilter(path: "SRC/AUTH").apply(to: sample).map(\.revision) == [120])
        #expect(LogFilter(path: "src/").apply(to: sample).map(\.revision) == [120, 118])
    }

    @Test("a date window keeps only newer commits")
    func dateWindow() {
        let from = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        #expect(LogFilter(from: from).apply(to: sample).map(\.revision) == [120, 119])
    }

    @Test("conditions combine with AND")
    func combined() {
        let from = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let filter = LogFilter(text: "src", author: "alice", from: from)
        #expect(filter.apply(to: sample).map(\.revision) == [120])
        #expect(filter.conditionCount == 3)
    }

    @Test("only free text can be sent to the server, and the rest is reported")
    func serverSearchability() {
        let filter = LogFilter(text: "  timeout  ", author: "alice", path: "src/")
        #expect(filter.serverSearchPattern == "timeout")
        #expect(filter.conditionsNotSearchableOnServer == ["作者", "路径"])

        #expect(LogFilter(author: "alice").serverSearchPattern == nil)
    }

    @Test("an entry without a date cannot satisfy a date window")
    func undatedEntry() {
        let undated = LogEntry(revision: 99, author: "alice", date: nil, message: "no date")
        #expect(!LogFilter(from: Date.distantPast).matches(undated))
    }
}

@Suite("blame")
struct BlameTests {
    private func fixture() throws -> BlameResult {
        try SVNXMLParser.parseBlame(TestEnvironment.fixture("svn-blame.xml"))
    }

    @Test("the annotation is parsed without the text")
    func parsing() throws {
        let result = try fixture()
        #expect(result.lines.count == 4)
        #expect(result.target == "renamed.txt")
        #expect(result.lines.map(\.lineNumber) == [1, 2, 3, 4])
        #expect(result.lines.map(\.revision) == [1, 4, 1, 4])
        #expect(result.lines.allSatisfy { $0.author == "wanyingfei" })
        // The XML truly carries no content.
        #expect(result.lines.allSatisfy { $0.content.isEmpty })
    }

    @Test("authorship counts lines in first-appearance order")
    func authorship() throws {
        var result = try fixture()
        result.lines[0].author = "alice"
        result.lines[2].author = "alice"
        let counts = result.authorship
        #expect(counts.count == 2)
        #expect(counts[0].author == "alice")
        #expect(counts[0].lines == 2)
        #expect(counts[1].author == "wanyingfei")
        #expect(counts[1].lines == 2)
    }

    @Test("contents are paired by line number")
    func attachContents() throws {
        var result = try fixture()
        result.attachContents("aaa\nBBB changed again\nccc\nddd\n")
        #expect(result.lines.map(\.content) == ["aaa", "BBB changed again", "ccc", "ddd"])
    }

    @Test("a trailing newline does not create a phantom line")
    func trailingNewline() throws {
        var result = try fixture()
        result.attachContents("one\ntwo\nthree\nfour\n")
        #expect(result.lines.last?.content == "four")
    }

    @Test("a shorter file leaves the surplus rows empty instead of shifting them")
    func shorterFile() throws {
        var result = try fixture()
        result.attachContents("one\ntwo\n")
        // Rows 3 and 4 keep their annotation but have no text: shifting would
        // attribute line 2's text to revision 1's row.
        #expect(result.lines[0].content == "one")
        #expect(result.lines[1].content == "two")
        #expect(result.lines[2].content.isEmpty)
        #expect(result.lines[3].content.isEmpty)
        #expect(result.lines[3].revision == 4)
    }
}

@Suite("log cache")
struct LogCacheTests {
    private func makeCache() throws -> (LogCache, URL) {
        let directory = try TestEnvironment.makeTemporaryDirectory("logcache")
        return (LogCache(directory: directory), directory)
    }

    private func entry(_ revision: Int64, message: String = "") -> LogEntry {
        LogEntry(revision: revision, author: "alice", date: Date(), message: message)
    }

    @Test("merging deduplicates by revision and keeps newest first")
    func merge() async throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = LogCache.Key(workingCopy: "/wc", target: "", repositoryUUID: "uuid-1")

        await cache.merge([entry(3), entry(2)], key: key)
        // The overlap (r2) is the proof that cache and server agree.
        let merged = await cache.merge([entry(4), entry(3), entry(2)], key: key)
        #expect(merged.map(\.revision) == [4, 3, 2])
    }

    @Test("a stored page comes back on the next launch")
    func persistence() async throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = LogCache.Key(workingCopy: "/wc", target: "", repositoryUUID: "uuid-1")

        await cache.merge([entry(2), entry(1)], key: key)
        let reloaded = await cache.load(key: key)
        #expect(reloaded.entries.map(\.revision) == [2, 1])
    }

    @Test("entries are capped, keeping the newest")
    func cap() async throws {
        let directory = try TestEnvironment.makeTemporaryDirectory("logcache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LogCache(directory: directory, maximumEntries: 3)
        let key = LogCache.Key(workingCopy: "/wc", target: "", repositoryUUID: "uuid-1")

        let merged = await cache.merge([entry(5), entry(4), entry(3), entry(2), entry(1)], key: key)
        #expect(merged.map(\.revision) == [5, 4, 3])
    }

    @Test("a different target gets its own file")
    func perTarget() async throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = LogCache.Key(workingCopy: "/wc", target: "", repositoryUUID: "uuid-1")
        let file = LogCache.Key(workingCopy: "/wc", target: "src/a.swift", repositoryUUID: "uuid-1")

        await cache.merge([entry(9)], key: root)
        await cache.merge([entry(3)], key: file)

        let rootEntries = await cache.load(key: root).entries
        let fileEntries = await cache.load(key: file).entries
        #expect(rootEntries.map(\.revision) == [9])
        #expect(fileEntries.map(\.revision) == [3])
    }

    @Test("a recreated repository invalidates the cache")
    func uuidMismatch() async throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = LogCache.Key(workingCopy: "/wc", target: "", repositoryUUID: "uuid-1")
        await cache.merge([entry(9)], key: old)

        // Same path, new UUID: revision numbers no longer mean the same thing.
        let recreated = LogCache.Key(workingCopy: "/wc", target: "", repositoryUUID: "uuid-2")
        let stale = await cache.load(key: recreated)
        #expect(stale.entries.isEmpty)
    }

    @Test("a corrupt file costs a request, not an error")
    func corruptFile() async throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = LogCache.Key(workingCopy: "/wc", target: "", repositoryUUID: "uuid-1")
        await cache.merge([entry(1)], key: key)

        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try Data("not json".utf8).write(to: file)
        }
        let reloaded = await cache.load(key: key)
        #expect(reloaded.entries.isEmpty)
    }
}
