import Foundation
import Testing
@testable import OpenSVNCore

/// The journal exists for one scenario: the process dies between `begin` and
/// `finish`. Everything else (corrupt file, read-only disk, trimming) is about
/// not making that scenario worse.
@Suite("operation journal")
struct OperationJournalTests {

    private func makeDirectory(_ label: String) throws -> URL {
        try TestEnvironment.makeTemporaryDirectory(label)
    }

    private func entryFile(in directory: URL) -> URL {
        directory.appendingPathComponent("journal.json")
    }

    // A realistic working-copy path: contains a space and a non-ASCII segment,
    // because JSON encoding of paths is where cheap implementations break.
    private let workingCopy = URL(fileURLWithPath: "/Users/someone/文档/我的 仓库")

    @Test("an entry written by one run is visible to the next")
    func survivesProcessBoundary() async throws {
        let directory = try makeDirectory("journal-survive")
        let previousRun = OperationJournal(directory: directory, runIdentifier: UUID())
        let nextRun = OperationJournal(directory: directory, runIdentifier: UUID())

        try await previousRun.begin(.commit, workingCopy: workingCopy, summary: "提交 3 个路径")

        let recovered = await nextRun.unfinished()
        #expect(recovered.count == 1)
        #expect(recovered.first?.kind == .commit)
        #expect(recovered.first?.workingCopy == workingCopy.standardizedFileURL.path)
        #expect(recovered.first?.summary == "提交 3 个路径")

        // The run that wrote it must not see its own in-flight work as residue.
        let own = await previousRun.unfinished()
        #expect(own.isEmpty)
    }

    @Test("finishing removes the entry so the next run sees nothing")
    func finishClears() async throws {
        let directory = try makeDirectory("journal-finish")
        let previousRun = OperationJournal(directory: directory, runIdentifier: UUID())
        let ticket = try await previousRun.begin(.update, workingCopy: workingCopy, summary: "更新")
        try await previousRun.finish(ticket)
        try await previousRun.finish(nil)  // must be a no-op, not a crash

        let nextRun = OperationJournal(directory: directory, runIdentifier: UUID())
        let recovered = await nextRun.unfinished()
        #expect(recovered.isEmpty)
        #expect(await nextRun.allEntries().isEmpty)
    }

    @Test("finishing an unknown ticket is a no-op")
    func finishUnknownTicket() async throws {
        let directory = try makeDirectory("journal-unknown")
        let journal = OperationJournal(directory: directory, runIdentifier: UUID())
        try await journal.finish(UUID())
        let entries = await journal.allEntries()
        #expect(entries.isEmpty)
    }

    @Test("a corrupt journal is quarantined, not deleted")
    func corruptFileIsQuarantined() async throws {
        let directory = try makeDirectory("journal-corrupt")
        try Data(#"{"version": 1, "entries": [ {"#.utf8)
            .write(to: entryFile(in: directory))

        let journal = OperationJournal(directory: directory, runIdentifier: UUID())

        // The app still starts and reports nothing — a broken journal must never
        // be fatal, because the failure mode is "we don't know", not "we crash".
        let recovered = await journal.unfinished()
        #expect(recovered.isEmpty)

        let backup = try #require(await journal.quarantineURL())
        #expect(FileManager.default.fileExists(atPath: backup.path))

        // The original is gone, so the next write starts from a clean slate
        // instead of failing forever on the same bytes.
        #expect(!FileManager.default.fileExists(atPath: entryFile(in: directory).path))
        try await journal.begin(.cleanup, workingCopy: workingCopy, summary: "清理")
        #expect(FileManager.default.fileExists(atPath: entryFile(in: directory).path))
    }

    @Test("a journal from a newer schema is quarantined rather than misread")
    func futureSchemaIsQuarantined() async throws {
        let directory = try makeDirectory("journal-future")
        try Data(#"{"version": 99, "entries": []}"#.utf8)
            .write(to: entryFile(in: directory))

        let journal = OperationJournal(directory: directory, runIdentifier: UUID())
        #expect(await journal.quarantineURL() != nil)
    }

    @Test("the file stays valid JSON after many atomic writes")
    func fileStaysDecodable() async throws {
        let directory = try makeDirectory("journal-atomic")
        let journal = OperationJournal(directory: directory, runIdentifier: UUID())
        var tickets: [UUID] = []
        for index in 0..<10 {
            tickets.append(try await journal.begin(
                .update,
                workingCopy: workingCopy,
                summary: "更新 \(index)",
                now: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        for ticket in tickets {
            try await journal.finish(ticket)
        }

        let data = try Data(contentsOf: entryFile(in: directory))
        let payload = try JSONDecoder().decode(JournalPayloadProbe.self, from: data)
        #expect(payload.version == 1)
        #expect(payload.entries.isEmpty)
    }

    @Test("entries are capped and the newest ones survive")
    func trimming() async throws {
        let directory = try makeDirectory("journal-trim")
        let journal = OperationJournal(directory: directory, runIdentifier: UUID())
        let base = Date(timeIntervalSince1970: 1_000_000)

        for index in 0..<(OperationJournal.maximumEntries + 5) {
            try await journal.begin(
                .commit,
                workingCopy: workingCopy,
                summary: "提交 \(index)",
                now: base.addingTimeInterval(TimeInterval(index))
            )
        }

        let entries = await journal.allEntries()
        #expect(entries.count == OperationJournal.maximumEntries)
        // The oldest five were dropped; the most recent write is still there.
        #expect(entries.contains { $0.summary == "提交 \(OperationJournal.maximumEntries + 4)" })
        #expect(!entries.contains { $0.summary == "提交 0" })
    }

    @Test("discard removes one recovered entry, discardAll removes the rest")
    func discard() async throws {
        let directory = try makeDirectory("journal-discard")
        let previousRun = OperationJournal(directory: directory, runIdentifier: UUID())
        let first = try await previousRun.begin(.commit, workingCopy: workingCopy, summary: "提交")
        try await previousRun.begin(.update, workingCopy: workingCopy, summary: "更新")

        let nextRun = OperationJournal(directory: directory, runIdentifier: UUID())
        #expect(await nextRun.unfinished().count == 2)

        await nextRun.discard(first)
        #expect(await nextRun.unfinished().count == 1)

        await nextRun.discardAll()
        #expect(await nextRun.unfinished().isEmpty)
    }

    @Test("discardAll never touches the current run's in-flight operations")
    func discardAllKeepsCurrentRun() async throws {
        let directory = try makeDirectory("journal-discard-current")
        let previousRun = OperationJournal(directory: directory, runIdentifier: UUID())
        try await previousRun.begin(.commit, workingCopy: workingCopy, summary: "上一次的提交")

        let currentRun = OperationJournal(directory: directory, runIdentifier: UUID())
        try await currentRun.begin(.update, workingCopy: workingCopy, summary: "本次更新")

        await currentRun.discardAll()

        // Only the stale entry is gone; the write this process is performing now
        // must still be recoverable if we crash in the next second.
        let remaining = await currentRun.allEntries()
        #expect(remaining.count == 1)
        #expect(remaining.first?.summary == "本次更新")
    }

    @Test("an in-flight write is visible in the journal until the process returns")
    func inFlightWriteIsVisible() async throws {
        // A fake svn that takes a second: long enough to observe the entry that
        // was written before the subprocess started. This is the wiring test for
        // SVNService — the unit tests above only prove the journal itself works.
        let directory = try makeDirectory("journal-inflight")
        let journal = OperationJournal(directory: directory)
        let script = try TestEnvironment.makeExecutableScript(
            in: directory,
            name: "svn",
            contents: "#!/bin/sh\nsleep 1\nexit 0\n"
        )
        let installation = SVNInstallation(
            executableURL: script,
            version: SVNVersion(major: 1, minor: 14, patch: 0),
            source: .explicit
        )
        let service = SVNService(
            configuration: SVNServiceConfiguration(
                installation: installation,
                credentialStore: InMemoryCredentialStore(),
                timeout: 30,
                journal: journal
            )
        )

        let workingCopy = directory.appendingPathComponent("wc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingCopy.appendingPathComponent(".svn", isDirectory: true),
            withIntermediateDirectories: true
        )

        let task = Task { try await service.cleanup(at: workingCopy) }

        var observed: [OperationJournal.Entry] = []
        for _ in 0..<40 {
            observed = await journal.allEntries()
            if !observed.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(observed.count == 1)
        #expect(observed.first?.kind == .cleanup)
        #expect(observed.first?.workingCopy == workingCopy.standardizedFileURL.path)

        try await task.value
        // The entry must be gone the moment svn returned, otherwise every normal
        // operation would look like a crash next launch.
        let after = await journal.allEntries()
        #expect(after.isEmpty)
    }

    @Test("a failed write also clears its entry")
    func failedWriteClearsEntry() async throws {
        let directory = try makeDirectory("journal-failed")
        let journal = OperationJournal(directory: directory)
        let script = try TestEnvironment.makeExecutableScript(
            in: directory,
            name: "svn",
            contents: "#!/bin/sh\necho 'svn: E155004: working copy locked' >&2\nexit 1\n"
        )
        let installation = SVNInstallation(
            executableURL: script,
            version: SVNVersion(major: 1, minor: 14, patch: 0),
            source: .explicit
        )
        let service = SVNService(
            configuration: SVNServiceConfiguration(
                installation: installation,
                credentialStore: InMemoryCredentialStore(),
                timeout: 30,
                journal: journal
            )
        )
        let workingCopy = directory.appendingPathComponent("wc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingCopy.appendingPathComponent(".svn", isDirectory: true),
            withIntermediateDirectories: true
        )

        await #expect(throws: SVNError.self) {
            try await service.cleanup(at: workingCopy)
        }

        // A known failure is not an interruption: the recovery banner must not
        // appear because svn exited non-zero.
        let entries = await journal.allEntries()
        #expect(entries.isEmpty)
    }

    @Test("recovery advice never tells the user to blindly retry a commit")
    func commitAdviceIsNotRetry() {
        let entry = OperationJournal.Entry(
            kind: .commit,
            workingCopy: "/tmp/wc",
            summary: "提交",
            runIdentifier: UUID()
        )
        #expect(entry.recoveryAdvice.contains("不要直接重复提交"))
        // Every kind must explain itself; an empty string in the banner is worse
        // than no banner at all.
        for kind in OperationJournal.Entry.Kind.allCases {
            let sample = OperationJournal.Entry(
                kind: kind,
                workingCopy: "/tmp/wc",
                summary: "x",
                runIdentifier: UUID()
            )
            #expect(!sample.recoveryAdvice.isEmpty)
            #expect(!sample.kind.title.isEmpty)
        }
    }
}

/// Mirrors the on-disk envelope so the test decodes the real bytes instead of
/// asserting on the writer's private type.
private struct JournalPayloadProbe: Decodable {
    struct Entry: Decodable {
        let id: UUID
        let kind: String
        let summary: String
    }
    let version: Int
    let entries: [Entry]
}
