import Foundation

/// One changed path inside a log entry (`<path>` in `svn log --xml`).
public struct ChangedPath: Sendable, Hashable {
    public enum Action: String, Sendable, Hashable {
        case added = "A"
        case deleted = "D"
        case modified = "M"
        case replaced = "R"
        case unknown = "?"
    }

    public var path: String
    public var action: Action
    public var kind: String?
    public var copyFromPath: String?
    public var copyFromRevision: Int64?

    public init(
        path: String,
        action: Action,
        kind: String? = nil,
        copyFromPath: String? = nil,
        copyFromRevision: Int64? = nil
    ) {
        self.path = path
        self.action = action
        self.kind = kind
        self.copyFromPath = copyFromPath
        self.copyFromRevision = copyFromRevision
    }
}

/// One revision from `svn log --xml`.
public struct LogEntry: Sendable, Hashable, Identifiable {
    public var revision: Int64
    public var author: String?
    /// Always stored as an absolute instant; formatting is a UI concern.
    public var date: Date?
    public var message: String
    public var changedPaths: [ChangedPath]

    public var id: Int64 { revision }

    public init(
        revision: Int64,
        author: String? = nil,
        date: Date? = nil,
        message: String = "",
        changedPaths: [ChangedPath] = []
    ) {
        self.revision = revision
        self.author = author
        self.date = date
        self.message = message
        self.changedPaths = changedPaths
    }
}

/// A page of history, keeping the information needed for paginated loading.
public struct LogPage: Sendable, Hashable {
    public var entries: [LogEntry]
    public var target: String?
    public var limit: Int
    /// Lowest revision in this page, for `-r <lowest-1>:1` paging.
    public var oldestRevision: Int64? { entries.map(\.revision).min() }
    public var newestRevision: Int64? { entries.map(\.revision).max() }
    public var hasMore: Bool

    public init(entries: [LogEntry], target: String? = nil, limit: Int, hasMore: Bool) {
        self.entries = entries
        self.target = target
        self.limit = limit
        self.hasMore = hasMore
    }
}

/// Node kind reported by `svn info`.
public enum NodeKind: String, Sendable, Hashable {
    case file
    case dir
    case none
    case unknown

    public init(rawValue: String) {
        switch rawValue {
        case "file": self = .file
        case "dir": self = .dir
        case "none": self = .none
        default: self = .unknown
        }
    }
}

/// The result of `svn info --xml`.
///
/// `svn info` can return several `<entry>` elements when given multiple targets;
/// the primary entry is `entries[0]`.
public struct InfoReport: Sendable, Hashable {
    public var entries: [RepositoryInfo]

    public init(entries: [RepositoryInfo]) {
        self.entries = entries
    }

    public var primary: RepositoryInfo? { entries.first }
}

public struct RepositoryInfo: Sendable, Hashable, Identifiable {
    public var path: String
    public var url: String
    public var repositoryRoot: String?
    public var repositoryUUID: String?
    public var revision: Int64?
    public var kind: NodeKind
    public var schedule: String?
    public var depth: String?
    public var workingCopyRoot: String?
    public var lastChangedRevision: Int64?
    public var lastChangedAuthor: String?
    public var lastChangedDate: Date?
    /// Repository-side lock on this path, when one exists.
    public var repositoryLock: RepositoryLock?

    public var id: String { path }

    public init(
        path: String,
        url: String,
        repositoryRoot: String? = nil,
        repositoryUUID: String? = nil,
        revision: Int64? = nil,
        kind: NodeKind = .none,
        schedule: String? = nil,
        depth: String? = nil,
        workingCopyRoot: String? = nil,
        lastChangedRevision: Int64? = nil,
        lastChangedAuthor: String? = nil,
        lastChangedDate: Date? = nil,
        repositoryLock: RepositoryLock? = nil
    ) {
        self.path = path
        self.url = url
        self.repositoryRoot = repositoryRoot
        self.repositoryUUID = repositoryUUID
        self.revision = revision
        self.kind = kind
        self.schedule = schedule
        self.depth = depth
        self.workingCopyRoot = workingCopyRoot
        self.lastChangedRevision = lastChangedRevision
        self.lastChangedAuthor = lastChangedAuthor
        self.lastChangedDate = lastChangedDate
        self.repositoryLock = repositoryLock
    }

    /// Host component of `url`, used as the Keychain credential scope.
    public var host: String? { URL(string: url)?.host }
}
