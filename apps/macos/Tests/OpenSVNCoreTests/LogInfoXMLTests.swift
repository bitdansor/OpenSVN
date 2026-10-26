import Foundation
import Testing
@testable import OpenSVNCore

@Suite("svn log XML")
struct LogXMLTests {
    @Test("entries, authors, messages and changed paths")
    func logEntries() throws {
        let entries = try SVNXMLParser.parseLog(TestEnvironment.fixture("svn-log.xml"))
        #expect(entries.count == 4)
        #expect(entries.map(\.revision) == [4, 3, 2, 1])

        let latest = try #require(entries.first)
        #expect(latest.author == "fixture")
        #expect(latest.message == "wc-b：删除 tree-conflict.txt")
        #expect(latest.changedPaths.count == 1)
        #expect(latest.changedPaths[0].action == .deleted)
        #expect(latest.changedPaths[0].path == "/trunk/docs/tree-conflict.txt")
        #expect(latest.changedPaths[0].kind == "file")

        let oldest = try #require(entries.last)
        #expect(oldest.revision == 1)
        #expect(oldest.message.contains("初始导入"))
        #expect(oldest.changedPaths.count > 5)
        #expect(oldest.changedPaths.contains { $0.path.contains("中文 文档") })
    }

    @Test("dates are absolute UTC instants")
    func logDates() throws {
        let entries = try SVNXMLParser.parseLog(TestEnvironment.fixture("svn-log.xml"))
        let date = try #require(entries.first?.date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 10)
        #expect(components.day == 18)
        #expect(components.hour == 4)
        // Sub-second precision must survive (fixtures carry microseconds).
        #expect(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) != 0)
    }

    @Test("log paging reports whether more history may exist")
    func paging() {
        let page = LogPage(entries: [LogEntry(revision: 9), LogEntry(revision: 8)], limit: 2, hasMore: true)
        #expect(page.hasMore)
        #expect(page.oldestRevision == 8)
        #expect(page.newestRevision == 9)
    }
}

@Suite("svn info XML")
struct InfoXMLTests {
    @Test("working copy info exposes wc root and repository identity")
    func workingCopyInfo() throws {
        let report = try SVNXMLParser.parseInfo(TestEnvironment.fixture("svn-info-wc.xml"))
        let info = try #require(report.primary)
        #expect(report.entries.count == 1)
        #expect(info.path == "wc-a")
        #expect(info.kind == .dir)
        #expect(info.revision == 4)
        #expect(info.url.hasSuffix("/trunk"))
        #expect(info.repositoryRoot?.hasPrefix("file://") == true)
        #expect(info.repositoryUUID?.isEmpty == false)
        #expect(info.workingCopyRoot?.hasSuffix("/wc-a") == true)
        #expect(info.schedule == "normal")
        #expect(info.depth == "infinity")
        #expect(info.lastChangedRevision == 4)
        #expect(info.lastChangedAuthor == "fixture")
        #expect(info.lastChangedDate != nil)
        #expect(info.host == nil) // file:// URLs have no host
    }

    @Test("URL info has no wc-info and still parses commit metadata")
    func urlInfo() throws {
        let report = try SVNXMLParser.parseInfo(TestEnvironment.fixture("svn-info-url.xml"))
        let info = try #require(report.primary)
        #expect(info.kind == .file)
        #expect(info.workingCopyRoot == nil)
        #expect(info.schedule == nil)
        #expect(info.url.hasSuffix("/trunk/src/main.swift"))
        #expect(info.lastChangedRevision == 1)
        #expect(info.lastChangedAuthor == "fixture")
        #expect(info.repositoryLock == nil)
    }
}

@Suite("date parsing")
struct DateParserTests {
    @Test("microsecond precision")
    func microseconds() throws {
        let date = try #require(SVNDateParser.parse("2026-10-18T04:35:56.116733Z"))
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 18
        components.hour = 4
        components.minute = 35
        components.second = 56
        components.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = try #require(calendar.date(from: components))
        #expect(abs(date.timeIntervalSince(expected) - 0.116733) < 0.002)
    }

    @Test("without fractional seconds")
    func noFraction() {
        #expect(SVNDateParser.parse("2026-10-18T04:35:56Z") != nil)
    }

    @Test("garbage is rejected instead of guessed")
    func garbage() {
        #expect(SVNDateParser.parse("not a date") == nil)
        #expect(SVNDateParser.parse("") == nil)
        #expect(SVNDateParser.parse(nil) == nil)
    }
}
