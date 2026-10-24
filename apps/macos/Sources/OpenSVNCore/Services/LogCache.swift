import CryptoKit
import Foundation

/// On-disk cache for `svn log` pages, one file per (working copy, target).
///
/// Two things make this worth persisting rather than keeping in memory:
///
/// 1. **Incremental fetch.** Knowing the newest revision already cached turns
///    "load the first page again" into "ask for what happened since", which is
///    one small request instead of a full page — and on a slow link the
///    difference is the whole perceived speed of the history tab.
/// 2. **Surviving a restart.** History is the page people reopen to read
///    something they saw yesterday; re-downloading it every launch is work with
///    no output.
///
/// The cache is keyed by working-copy path *and* target, so opening a file's
/// history does not evict the working copy's own. `repositoryUUID` guards
/// against the repository being recreated underneath us: a reloaded dump has new
/// revision numbers for the same content, and serving stale entries would show
/// history that never existed.
public actor LogCache {
    public struct Key: Sendable, Hashable {
        /// Absolute path of the working-copy root.
        public var workingCopy: String
        /// Path relative to that root; empty for the root itself.
        public var target: String
        public var repositoryUUID: String?

        public init(workingCopy: String, target: String = "", repositoryUUID: String? = nil) {
            self.workingCopy = workingCopy
            self.target = target
            self.repositoryUUID = repositoryUUID
        }
    }

    public struct Snapshot: Sendable {
        public var entries: [LogEntry]
        public var storedAt: Date

        public init(entries: [LogEntry], storedAt: Date) {
            self.entries = entries
            self.storedAt = storedAt
        }
    }

    /// Newest-first, capped. A cache that grows without bound eventually costs
    /// more to decode than the request it saves.
    public static let maximumEntries = 2000
    private static let currentVersion = 1

    private let directory: URL
    private let maximumEntries: Int

    public init(
        directory: URL = LogCache.defaultDirectory,
        maximumEntries: Int = LogCache.maximumEntries
    ) {
        self.directory = directory
        self.maximumEntries = maximumEntries
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("OpenSVN", isDirectory: true)
            .appendingPathComponent("log-cache", isDirectory: true)
    }

    /// Reads what is on disk for this key, or an empty list.
    ///
    /// Every failure path returns empty rather than throwing: a cache is an
    /// optimisation, and a corrupt one must cost a request, not an error dialog.
    public func load(key: Key) -> Snapshot {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else {
            return Snapshot(entries: [], storedAt: .distantPast)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.version <= Self.currentVersion,
              payload.workingCopy == key.workingCopy,
              payload.target == key.target else {
            return Snapshot(entries: [], storedAt: .distantPast)
        }

        // A recreated repository keeps the path but changes every revision
        // number and its URL may not have changed either.
        if let cached = payload.repositoryUUID,
           let current = key.repositoryUUID,
           cached != current {
            try? FileManager.default.removeItem(at: url)
            return Snapshot(entries: [], storedAt: .distantPast)
        }

        return Snapshot(
            entries: Array(payload.entries.prefix(maximumEntries)),
            storedAt: payload.storedAt ?? .distantPast
        )
    }

    /// Merges new entries into what is stored and writes the result.
    ///
    /// Deduplicates by revision, which is what makes an incremental fetch safe:
    /// the overlapping revision (already cached *and* included in the new page)
    /// appears once, and an out-of-order page cannot duplicate a row.
    @discardableResult
    public func merge(_ entries: [LogEntry], key: Key) -> [LogEntry] {
        var existing = load(key: key).entries
        var seen = Set(existing.map(\.revision))
        for entry in entries where !seen.contains(entry.revision) {
            existing.append(entry)
            seen.insert(entry.revision)
        }
        existing.sort { $0.revision > $1.revision }
        if existing.count > maximumEntries {
            existing = Array(existing.prefix(maximumEntries))
        }
        write(existing, key: key)
        return existing
    }

    public func replace(_ entries: [LogEntry], key: Key) {
        var sorted = entries
        sorted.sort { $0.revision > $1.revision }
        write(Array(sorted.prefix(maximumEntries)), key: key)
    }

    public func clear(key: Key) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    public func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Plumbing

    private func write(_ entries: [LogEntry], key: Key) {
        guard !entries.isEmpty else {
            clear(key: key)
            return
        }
        let payload = Payload(
            version: Self.currentVersion,
            workingCopy: key.workingCopy,
            target: key.target,
            repositoryUUID: key.repositoryUUID,
            storedAt: Date(),
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else {
            AppLog.shared.record(.warning, "历史缓存编码失败", category: "history")
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            // A cache that cannot be written is still correct, just slower.
            AppLog.shared.record(
                .warning,
                "历史缓存写入失败：\(error.localizedDescription)",
                category: "history"
            )
        }
    }

    private func fileURL(for key: Key) -> URL {
        let seed = "\(key.workingCopy)\u{0}\(key.target)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(name.prefix(32)) + ".json")
    }

    private struct Payload: Codable {
        var version: Int
        var workingCopy: String
        var target: String
        var repositoryUUID: String?
        var storedAt: Date?
        var entries: [LogEntry]
    }
}
