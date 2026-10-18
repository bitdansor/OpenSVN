import Foundation
import OpenSVNCore

/// A persisted repository entry.
///
/// Deliberately contains no credentials, no username, and no password: the
/// bookmark is only a path plus a display name (red line R2).
public struct RepositoryBookmark: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var name: String
    public var lastOpenedAt: Date?

    public init(id: UUID = UUID(), path: String, name: String? = nil, lastOpenedAt: Date? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.lastOpenedAt = lastOpenedAt
    }

    public var url: URL { URL(fileURLWithPath: path) }
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

    public static let defaultTimeout: TimeInterval = 300

    public init(
        explicitSVNPath: String? = nil,
        operationTimeout: TimeInterval = AppSettings.defaultTimeout,
        confirmBeforeDestructiveAction: Bool = true
    ) {
        self.explicitSVNPath = explicitSVNPath
        self.operationTimeout = operationTimeout
        self.confirmBeforeDestructiveAction = confirmBeforeDestructiveAction
    }

    private static let pathKey = "cn.opensvn.svnPath"
    private static let timeoutKey = "cn.opensvn.operationTimeout"
    private static let confirmKey = "cn.opensvn.confirmDestructive"

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        let path = defaults.string(forKey: pathKey)
        let timeout = defaults.double(forKey: timeoutKey)
        let confirm = defaults.object(forKey: confirmKey) as? Bool ?? true
        return AppSettings(
            explicitSVNPath: (path?.isEmpty ?? true) ? nil : path,
            operationTimeout: timeout > 0 ? timeout : defaultTimeout,
            confirmBeforeDestructiveAction: confirm
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(explicitSVNPath, forKey: Self.pathKey)
        defaults.set(operationTimeout, forKey: Self.timeoutKey)
        defaults.set(confirmBeforeDestructiveAction, forKey: Self.confirmKey)
    }
}
