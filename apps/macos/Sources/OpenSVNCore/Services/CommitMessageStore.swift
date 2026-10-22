import Foundation
import Observation

/// The commit messages this user has written recently.
///
/// Why a store at all: rewriting "修复登录后不能退出" from scratch every time is
/// busywork, and people solve it by keeping the text in a scratch file. Keeping
/// the last few messages one click away is the same habit, without the file.
///
/// Deliberate choices:
///
/// - **Global, not per repository.** The messages describe the person's work,
///   not one checkout; someone who opens four working copies should not get four
///   different lists.
/// - **Exact-duplicate collapse.** Recording the same text twice moves the
///   existing entry to the front instead of adding a copy, so the list stays a
///   list of distinct messages.
/// - **Capped, and trimmed oldest-first.** Only a picker's worth is useful; an
///   unbounded file would quietly accumulate every typo the user committed.
/// - **Storage failure is not an error.** The list is a convenience, and a
///   read-only disk must not block a commit.
@MainActor
@Observable
public final class CommitMessageStore {
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public var message: String
        public var lastUsed: Date
        public var uses: Int

        public var id: String { message }

        public init(message: String, lastUsed: Date = Date(), uses: Int = 1) {
            self.message = message
            self.lastUsed = lastUsed
            self.uses = uses
        }
    }

    /// `~/Library/Application Support/OpenSVN/commit-messages.json`, next to the
    /// journal so "where does this app keep its state" has one answer.
    public static var defaultFileURL: URL {
        OperationJournal.defaultDirectory.appendingPathComponent("commit-messages.json")
    }

    /// How many messages to keep. Ten fit a menu without scrolling; thirty cover
    /// a fortnight of work and still load instantly.
    public static let maximumEntries = 30

    private struct Payload: Codable {
        var version: Int
        var entries: [Entry]
    }

    private static let currentVersion = 1

    public private(set) var entries: [Entry] = []
    private let fileURL: URL?
    private let now: @Sendable () -> Date

    /// - Parameter fileURL: `nil` keeps everything in memory, which is what the
    ///   tests and the demo workspace want.
    public init(fileURL: URL? = CommitMessageStore.defaultFileURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        self.entries = Self.load(from: fileURL)
    }

    /// Messages to offer, newest first.
    public func recent(limit: Int = 10) -> [String] {
        entries.prefix(max(0, limit)).map(\.message)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Records a message that was actually committed.
    ///
    /// Only successful commits are recorded: an entry for a message that never
    /// reached the repository would suggest work that does not exist.
    public func record(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let index = entries.firstIndex(where: { $0.message == trimmed }) {
            var existing = entries.remove(at: index)
            existing.lastUsed = now()
            existing.uses += 1
            entries.insert(existing, at: 0)
        } else {
            entries.insert(Entry(message: trimmed, lastUsed: now()), at: 0)
        }

        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        persist()
    }

    public func remove(_ message: String) {
        guard entries.contains(where: { $0.message == message }) else { return }
        entries.removeAll { $0.message == message }
        persist()
    }

    public func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        persist()
    }

    // MARK: - Storage

    private func persist() {
        guard let fileURL else { return }
        let payload = Payload(version: Self.currentVersion, entries: entries)
        do {
            let data = try Self.encoder().encode(payload)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A convenience that cannot be saved is still a working convenience
            // for this session; the next launch simply starts empty.
            AppLog.shared.record(.warning, "提交说明历史写入失败：\(error.localizedDescription)", category: "commit")
        }
    }

    /// ISO 8601 rather than the default "seconds since 2001": this file is small,
    /// human-readable, and occasionally pasted into a bug report. A number there
    /// tells the reader nothing.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func load(from url: URL?) -> [Entry] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let payload = try decoder().decode(Payload.self, from: data)
            guard payload.version <= currentVersion else { return [] }
            return Array(payload.entries.prefix(maximumEntries))
        } catch {
            // A corrupt file is not worth a dialog: the data is a list of recent
            // messages, and the cost of dropping it is one retyped sentence.
            AppLog.shared.record(.warning, "提交说明历史无法读取，已忽略：\(error.localizedDescription)", category: "commit")
            return []
        }
    }
}
