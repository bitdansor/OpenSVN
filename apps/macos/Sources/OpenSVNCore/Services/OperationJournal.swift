import Foundation
import os

/// A durable record of write operations, so a crash, a force-quit or a power
/// loss leaves evidence instead of a mystery.
///
/// Why this exists: `svn update` and `svn commit` can die halfway. The next
/// launch otherwise has no way to tell "nothing happened" from "a write was
/// interrupted and the working copy may be wedged". The journal is written
/// *before* the subprocess starts and removed when it returns, so an entry that
/// survives a process boundary is, by construction, an operation with no
/// recorded outcome.
///
/// Deliberate choices:
///
/// - **The file is written atomically** (`Data.write(options: .atomic)` renames a
///   temp file). A torn JSON file would lose the very record that exists to
///   survive a crash.
/// - **A corrupt file is quarantined, never deleted.** Renaming it to
///   `journal.corrupt-<timestamp>.json` keeps whatever a human might need to
///   reconstruct what happened, and the app still starts.
/// - **Writing failures never block the operation.** Callers use `try?`: a read-only
///   disk must not stop a commit. The cost is that recovery may be unavailable,
///   which is strictly better than refusing to work.
/// - **Entries are keyed by run, not by PID.** Two launches can reuse a PID; a
///   UUID per `OperationJournal` instance cannot collide.
/// - **Nothing secret is stored.** No credentials, no environment, no argv beyond
///   the operation kind and the number of paths.
public actor OperationJournal {
    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            case checkout
            case update
            case commit
            case add
            case delete
            case revert
            case resolve
            case cleanup
            case property
            case lock
            case unlock

            /// Short label for the recovery banner. Never an svn token.
            public var title: String {
                switch self {
                case .checkout: return "检出"
                case .update: return "更新"
                case .commit: return "提交"
                case .add: return "添加"
                case .delete: return "删除"
                case .revert: return "还原"
                case .resolve: return "解决冲突"
                case .cleanup: return "清理"
                case .property: return "修改属性"
                case .lock: return "锁定"
                case .unlock: return "解锁"
                }
            }
        }

        public let id: UUID
        public let kind: Kind
        /// Absolute path of the working copy root (or the checkout destination,
        /// which may not have been created yet).
        public let workingCopy: String
        /// One human sentence written before the operation started.
        public let summary: String
        public let startedAt: Date
        public let runIdentifier: UUID
        public let processIdentifier: Int32

        public init(
            id: UUID = UUID(),
            kind: Kind,
            workingCopy: String,
            summary: String,
            startedAt: Date = Date(),
            runIdentifier: UUID,
            processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
        ) {
            self.id = id
            self.kind = kind
            self.workingCopy = workingCopy
            self.summary = summary
            self.startedAt = startedAt
            self.runIdentifier = runIdentifier
            self.processIdentifier = processIdentifier
        }

        /// What the user should do, in plain language.
        ///
        /// `commit` deliberately does **not** say "retry": the commit may have
        /// reached the server before the process died, and a naive retry is how
        /// duplicate commits happen.
        public var recoveryAdvice: String {
            switch kind {
            case .commit:
                return "提交可能已经到达服务器，也可能没有。先刷新状态确认，不要直接重复提交。"
            case .checkout:
                return "检出可能只完成了一部分。确认目录内容后再决定是继续还是删掉重来。"
            case .update, .revert, .resolve, .delete, .add, .property:
                return "工作副本可能停在中间状态。运行「清理」后再刷新状态。"
            case .lock:
                return "锁可能已在服务器上生效。刷新锁定状态确认，再决定是否重试。"
            case .unlock:
                return "锁可能已释放。刷新锁定状态确认，不要直接重复解锁。"
            case .cleanup:
                return "上次清理没有完成。重新运行「清理」即可。"
            }
        }
    }

    /// Directory that holds `journal.json`. Defaults to
    /// `~/Library/Application Support/OpenSVN`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenSVN", isDirectory: true)
    }

    /// Upper bound on stored entries. The file only ever holds unfinished
    /// operations, so hitting this means repeated crashes; keeping the newest
    /// fifty is enough to see the pattern without growing without bound.
    public static let maximumEntries = 50

    private struct Payload: Codable {
        var version: Int
        var entries: [Entry]
    }

    private static let currentVersion = 1

    private let fileURL: URL
    private let runIdentifier: UUID
    private let logger = Logger(subsystem: "cn.opensvn.app", category: "journal")

    private var quarantinedFile: URL?
    private var lastWriteFailure: String?

    public init(directory: URL? = nil, runIdentifier: UUID = UUID()) {
        let root = directory ?? Self.defaultDirectory
        self.fileURL = root.appendingPathComponent("journal.json")
        self.runIdentifier = runIdentifier
        // Load once so a corrupt file is quarantined before the first write.
        // The entries are deliberately not cached: the file is the source of
        // truth, and a cached copy goes stale the moment another instance (or
        // another process) writes.
        let loaded = Self.load(from: root.appendingPathComponent("journal.json"))
        self.quarantinedFile = loaded.quarantined
    }

    // MARK: - Recording

    /// Records an operation that is about to start. Returns the ticket to pass
    /// to `finish`.
    ///
    /// - Parameter now: injectable so tests can produce a deterministic order;
    ///   production always uses the current time.
    @discardableResult
    public func begin(
        _ kind: Entry.Kind,
        workingCopy: URL,
        summary: String,
        now: Date = Date()
    ) throws -> UUID {
        var entries = loadEntries()
        let entry = Entry(
            kind: kind,
            workingCopy: workingCopy.standardizedFileURL.path,
            summary: summary,
            startedAt: now,
            runIdentifier: runIdentifier
        )
        entries.append(entry)
        entries = Self.trimmed(entries, logger: logger)
        try persist(entries)
        return entry.id
    }

    /// Removes the entry. Safe to call twice, and safe with `nil`, so callers can
    /// write `try? await journal.finish(ticket)` in both the success and failure
    /// paths without extra branching.
    ///
    /// An operation that *failed* is not an interrupted operation: we know its
    /// outcome, so the entry must go. Only a process that never returns leaves
    /// one behind.
    public func finish(_ ticket: UUID?) throws {
        guard let ticket else { return }
        var entries = loadEntries()
        guard entries.contains(where: { $0.id == ticket }) else { return }
        entries.removeAll { $0.id == ticket }
        try persist(entries)
    }

    // MARK: - Recovery

    /// Entries written by a *previous* run. Empty during a healthy session.
    public func unfinished(limit: Int = 20) -> [Entry] {
        loadEntries()
            .filter { $0.runIdentifier != runIdentifier }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Forgets one recovered entry. Called after recovery succeeded, or when the
    /// user explicitly dismisses it.
    public func discard(_ id: UUID) {
        var entries = loadEntries()
        entries.removeAll { $0.id == id }
        try? persist(entries)
    }

    public func discardAll() {
        var entries = loadEntries()
        entries.removeAll { $0.runIdentifier != runIdentifier }
        try? persist(entries)
    }

    /// All entries, including this run's in-flight ones. Tests use it; the UI
    /// should use `unfinished(limit:)`.
    public func allEntries() -> [Entry] {
        loadEntries()
    }

    /// Non-nil when the journal file could not be decoded and was moved aside.
    /// The UI shows this once, because silently losing it would hide the only
    /// clue that an operation may have been interrupted.
    public func quarantineURL() -> URL? {
        quarantinedFile
    }

    /// Non-nil when the last write failed (read-only disk, full volume…).
    public func writeFailure() -> String? {
        lastWriteFailure
    }

    // MARK: - Storage

    private func loadEntries() -> [Entry] {
        let loaded = Self.load(from: fileURL)
        if let quarantined = loaded.quarantined {
            quarantinedFile = quarantined
        }
        return loaded.entries
    }

    private static func trimmed(_ entries: [Entry], logger: Logger) -> [Entry] {
        guard entries.count > maximumEntries else { return entries }
        logger.warning("journal trimmed to \(maximumEntries, privacy: .public) entries")
        return Array(entries.sorted { $0.startedAt > $1.startedAt }.prefix(maximumEntries))
    }

    private func persist(_ entries: [Entry]) throws {
        let payload = Payload(version: Self.currentVersion, entries: entries)
        do {
            let data = try JSONEncoder().encode(payload)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            lastWriteFailure = nil
        } catch {
            // Losing the journal is bad; refusing to run the operation is worse.
            lastWriteFailure = error.localizedDescription
            logger.error("journal write failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func load(from url: URL) -> (entries: [Entry], quarantined: URL?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([], nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version <= currentVersion else {
                // Written by a newer build: we cannot trust the schema.
                return ([], quarantine(url))
            }
            return (payload.entries, nil)
        } catch {
            return ([], quarantine(url))
        }
    }

    /// Moves the unreadable file aside. Never deletes: it is the only record
    /// that something was in flight.
    private static func quarantine(_ url: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("journal.corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }
}
