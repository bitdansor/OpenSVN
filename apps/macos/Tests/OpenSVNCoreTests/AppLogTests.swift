import Foundation
import Testing
@testable import OpenSVNCore

@Suite("Log file")
struct AppLogTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contents(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("messages below the configured level are not written")
    func levelFilter() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = AppLog(directory: directory, level: .warning)
        await log.append(.info, "this should be dropped")
        await log.append(.debug, "this too")
        await log.append(.error, "this one is kept")

        let text = try contents(at: directory.appendingPathComponent("opensvn.log"))
        #expect(text.contains("this one is kept"))
        #expect(!text.contains("dropped"))
        #expect(!text.contains("this too"))
    }

    @Test("level .off writes nothing at all, not even a file")
    func offWritesNothing() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = AppLog(directory: directory, level: .off)
        await log.append(.error, "nothing")

        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("opensvn.log").path))
    }

    @Test("credentials are redacted before they reach the file")
    func redactsCredentials() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = AppLog(directory: directory, level: .debug)
        await log.append(.error, "检查失败 https://alice:s3cret@example.com/repo")
        await log.append(.warning, "command: svn --password=hunter2 status")
        await log.append(.info, "token=abcdef123456")

        let text = try contents(at: directory.appendingPathComponent("opensvn.log"))
        #expect(!text.contains("s3cret"))
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("abcdef123456"))
        #expect(text.contains("https://***@example.com/repo"))
    }

    @Test("the file rotates instead of growing without bound")
    func rotates() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = AppLog(directory: directory, level: .debug, maxBytes: 1024, maxBackups: 1)
        // ~120 bytes per line, so this crosses 1 KB several times over.
        for index in 0..<40 {
            await log.append(.info, String(repeating: "x", count: 100) + " \(index)")
        }

        let live = try contents(at: directory.appendingPathComponent("opensvn.log"))
        let backup = try contents(at: URL(fileURLWithPath: directory.appendingPathComponent("opensvn.log").path + ".1"))
        #expect(!live.isEmpty)
        #expect(!backup.isEmpty)
        // The live file must be smaller than the cap plus one line.
        #expect(live.utf8.count < 1400)
    }

    @Test("each line carries a timestamp, level and category")
    func lineShape() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = AppLog(directory: directory, level: .debug)
        await log.append(.warning, "hello", category: "svn")

        let line = try contents(at: directory.appendingPathComponent("opensvn.log"))
            .split(separator: "\n")
            .first
            .map(String.init) ?? ""
        #expect(line.contains("[warning]"))
        #expect(line.contains("[svn]"))
        #expect(line.contains("hello"))
        // yyyy-MM-dd HH:mm:ss.SSS
        #expect(line.count > 23)
        #expect(line[line.index(line.startIndex, offsetBy: 4)] == "-")
    }

    @Test("changing the directory starts a new file there")
    func reconfigureDirectory() async throws {
        let first = try makeDirectory()
        let second = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let log = AppLog(directory: first, level: .info)
        await log.append(.info, "in the first place")
        await log.configure(directory: second)
        await log.append(.info, "in the second place")

        #expect(try contents(at: first.appendingPathComponent("opensvn.log")).contains("first place"))
        #expect(try contents(at: second.appendingPathComponent("opensvn.log")).contains("second place"))
    }
}
