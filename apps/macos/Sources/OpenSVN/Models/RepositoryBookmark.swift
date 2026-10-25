import Foundation
import OpenSVNCore

/// What a bookmark points at.
///
/// A working copy and a repository are different things with different possible
/// actions: one has files to edit and a status to read, the other only has URLs
/// and immediate commits. Collapsing them into "a bookmark with a path" forced
/// every screen to ask which it was holding.
public enum BookmarkKind: String, Codable, Sendable, Hashable {
    case workingCopy
    case repository
}

/// A persisted repository entry.
///
/// Deliberately contains no credentials, no username, and no password: the
/// bookmark is only a path (or URL) plus a display name (red line R2).
public struct RepositoryBookmark: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Filesystem path for a working copy; empty for a repository bookmark.
    public var path: String
    public var name: String
    public var lastOpenedAt: Date?
    public var kind: BookmarkKind
    /// Repository URL for a `repository` bookmark.
    public var repositoryURL: String?

    public init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        lastOpenedAt: Date? = nil,
        kind: BookmarkKind = .workingCopy,
        repositoryURL: String? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.lastOpenedAt = lastOpenedAt
        self.kind = kind
        self.repositoryURL = repositoryURL
    }

    /// A bookmark for a repository, with no working copy behind it.
    public static func repository(url: String, name: String? = nil) -> RepositoryBookmark {
        RepositoryBookmark(
            path: "",
            name: name ?? suggestedName(for: url),
            kind: .repository,
            repositoryURL: url
        )
    }

    public var url: URL { URL(fileURLWithPath: path) }

    public var isRepository: Bool { kind == .repository }

    /// The URL shown and browsed, whichever kind this is.
    public var displayLocation: String {
        isRepository ? (repositoryURL ?? "") : path
    }

    private static func suggestedName(for url: String) -> String {
        var cleaned = url
        while cleaned.count > 1, cleaned.hasSuffix("/") { cleaned.removeLast() }
        let leaf = (cleaned as NSString).lastPathComponent
        if !leaf.isEmpty { return leaf }
        return URL(string: cleaned)?.host ?? cleaned
    }

    // MARK: - Codable
    //
    // Written by hand for one reason: `kind` and `repositoryURL` were added after
    // bookmarks were already on disk. A synthesised decoder ignores property
    // defaults and fails on a missing key, which would have emptied the sidebar
    // of every existing user on first launch after the update.

    private enum CodingKeys: String, CodingKey {
        case id, path, name, lastOpenedAt, kind, repositoryURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        kind = try container.decodeIfPresent(BookmarkKind.self, forKey: .kind) ?? .workingCopy
        repositoryURL = try container.decodeIfPresent(String.self, forKey: .repositoryURL)
    }
}

/// UserDefaults-backed bookmark list. Credentials live in the Keychain only.
/// `UserDefaults` is thread-safe but not marked `Sendable`.
public struct RepositoryStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "cn.opensvn.repositories"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [RepositoryBookmark] {
        guard let data = defaults.data(forKey: key),
              let bookmarks = try? JSONDecoder().decode([RepositoryBookmark].self, from: data) else {
            return []
        }
        return bookmarks
    }

    public func save(_ bookmarks: [RepositoryBookmark]) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Application preferences. Not a credential store.
public struct AppSettings: Sendable {
    public var explicitSVNPath: String?
    public var operationTimeout: TimeInterval
    public var confirmBeforeDestructiveAction: Bool
    /// How much to write to `~/Library/Logs/OpenSVN/opensvn.log`.
    public var logLevel: LogLevel
    /// How many write operations may run at once across *different* working
    /// copies. Writes on one working copy are always serialised regardless.
    public var maxConcurrentWrites: Int
    /// Watch the open working copy for file changes and refresh the status.
    public var autoRefresh: Bool
    /// Read `svn status --show-updates` before updating, so the sheet can say
    /// what is coming in and whether it collides with local edits.
    public var previewBeforeUpdate: Bool
    /// Path or shell command handed to `svn diff --diff-cmd`.
    ///
    /// A wrapper script for a GUI tool, not the tool's binary: svn waits for the
    /// child to exit, so a script that returns immediately is what keeps the
    /// operation from blocking until the window is closed.
    public var externalDiffCommand: String?

    public static let defaultTimeout: TimeInterval = 300
    public static let defaultMaxConcurrentWrites = 4
    public static let maxConcurrentWritesRange = 1...8

    public init(
        explicitSVNPath: String? = nil,
        operationTimeout: TimeInterval = AppSettings.defaultTimeout,
        confirmBeforeDestructiveAction: Bool = true,
        logLevel: LogLevel = .info,
        maxConcurrentWrites: Int = AppSettings.defaultMaxConcurrentWrites,
        autoRefresh: Bool = true,
        previewBeforeUpdate: Bool = true,
        externalDiffCommand: String? = nil
    ) {
        self.explicitSVNPath = explicitSVNPath
        self.operationTimeout = operationTimeout
        self.confirmBeforeDestructiveAction = confirmBeforeDestructiveAction
        self.logLevel = logLevel
        self.maxConcurrentWrites = maxConcurrentWrites
        self.autoRefresh = autoRefresh
        self.previewBeforeUpdate = previewBeforeUpdate
        self.externalDiffCommand = externalDiffCommand
    }

    private static let pathKey = "cn.opensvn.svnPath"
    private static let timeoutKey = "cn.opensvn.operationTimeout"
    private static let confirmKey = "cn.opensvn.confirmDestructive"
    private static let logLevelKey = "cn.opensvn.logLevel"
    private static let maxWritesKey = "cn.opensvn.maxConcurrentWrites"
    private static let autoRefreshKey = "cn.opensvn.autoRefresh"
    private static let previewUpdateKey = "cn.opensvn.previewBeforeUpdate"
    private static let externalDiffKey = "cn.opensvn.externalDiffCommand"

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        let path = defaults.string(forKey: pathKey)
        let timeout = defaults.double(forKey: timeoutKey)
        let confirm = defaults.object(forKey: confirmKey) as? Bool ?? true
        let level = defaults.string(forKey: logLevelKey).flatMap(LogLevel.init(rawValue:)) ?? .info
        let writes = defaults.object(forKey: maxWritesKey) as? Int ?? defaultMaxConcurrentWrites
        let autoRefresh = defaults.object(forKey: autoRefreshKey) as? Bool ?? true
        let previewUpdate = defaults.object(forKey: previewUpdateKey) as? Bool ?? true
        let externalDiff = defaults.string(forKey: externalDiffKey)
        return AppSettings(
            explicitSVNPath: (path?.isEmpty ?? true) ? nil : path,
            operationTimeout: timeout > 0 ? timeout : defaultTimeout,
            confirmBeforeDestructiveAction: confirm,
            logLevel: level,
            maxConcurrentWrites: min(
                max(maxConcurrentWritesRange.lowerBound, writes),
                maxConcurrentWritesRange.upperBound
            ),
            autoRefresh: autoRefresh,
            previewBeforeUpdate: previewUpdate,
            externalDiffCommand: (externalDiff?.isEmpty ?? true) ? nil : externalDiff
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(explicitSVNPath, forKey: Self.pathKey)
        defaults.set(operationTimeout, forKey: Self.timeoutKey)
        defaults.set(confirmBeforeDestructiveAction, forKey: Self.confirmKey)
        defaults.set(logLevel.rawValue, forKey: Self.logLevelKey)
        defaults.set(maxConcurrentWrites, forKey: Self.maxWritesKey)
        defaults.set(autoRefresh, forKey: Self.autoRefreshKey)
        defaults.set(previewBeforeUpdate, forKey: Self.previewUpdateKey)
        defaults.set(externalDiffCommand, forKey: Self.externalDiffKey)
    }
}
