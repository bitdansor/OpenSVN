import Foundation

/// The text/property status of one working-copy entry, as reported by
/// `svn status --xml` (`<wc-status item="...">`).
///
/// `unknown` exists so that a future `svn` release cannot make parsing fail:
/// the raw token is preserved and shown to the user.
public enum WCItemStatus: Sendable, Hashable, RawRepresentable {
    case added
    case conflicted
    case deleted
    case external
    case ignored
    case incomplete
    case invalid
    case merged
    case missing
    case modified
    case none
    case normal
    case obstructed
    case replaced
    case unversioned
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "added": self = .added
        case "conflicted": self = .conflicted
        case "deleted": self = .deleted
        case "external": self = .external
        case "ignored": self = .ignored
        case "incomplete": self = .incomplete
        case "invalid": self = .invalid
        case "merged": self = .merged
        case "missing": self = .missing
        case "modified": self = .modified
        case "none": self = .none
        case "normal": self = .normal
        case "obstructed": self = .obstructed
        case "replaced": self = .replaced
        case "unversioned": self = .unversioned
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .added: return "added"
        case .conflicted: return "conflicted"
        case .deleted: return "deleted"
        case .external: return "external"
        case .ignored: return "ignored"
        case .incomplete: return "incomplete"
        case .invalid: return "invalid"
        case .merged: return "merged"
        case .missing: return "missing"
        case .modified: return "modified"
        case .none: return "none"
        case .normal: return "normal"
        case .obstructed: return "obstructed"
        case .replaced: return "replaced"
        case .unversioned: return "unversioned"
        case .unknown(let raw): return raw
        }
    }

    /// Whether this item represents a local change that can be committed.
    public var isCommittableChange: Bool {
        switch self {
        case .added, .deleted, .modified, .replaced, .merged:
            return true
        default:
            return false
        }
    }

    /// Whether this entry requires user attention before any further write.
    public var isBlocking: Bool {
        switch self {
        case .conflicted, .obstructed, .incomplete, .missing:
            return true
        default:
            return false
        }
    }
}

/// The three independent conflict kinds Subversion can report for one entry.
///
/// They are modelled as flags instead of a single `isConflicted` boolean because
/// one path may carry several at once, and the resolution flow differs per kind
/// (see `specifications/data-models.md`).
public struct ConflictFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Textual conflict: overlapping edits in the file body.
    public static let text = ConflictFlags(rawValue: 1 << 0)
    /// Property conflict: overlapping property changes on a file or directory.
    public static let property = ConflictFlags(rawValue: 1 << 1)
    /// Tree conflict: structural conflict (delete/modify, moved away, etc.).
    public static let tree = ConflictFlags(rawValue: 1 << 2)

    public static let all: ConflictFlags = [.text, .property, .tree]

    public var isEmpty: Bool { rawValue == 0 }

    public var hasAnyConflict: Bool { !isEmpty }

    /// Stable, machine-readable description used in logs and contract tests.
    public var codes: [String] {
        var result: [String] = []
        if contains(.text) { result.append("text") }
        if contains(.property) { result.append("property") }
        if contains(.tree) { result.append("tree") }
        return result
    }

    public init(codes: [String]) {
        var flags: ConflictFlags = []
        for code in codes {
            switch code {
            case "text": flags.insert(.text)
            case "property": flags.insert(.property)
            case "tree": flags.insert(.tree)
            default: break
            }
        }
        self = flags
    }
}

/// A repository-side file lock (`<lock>`), which is a different thing from a
/// working-copy internal lock and must never be collapsed into the same field.
public struct RepositoryLock: Sendable, Hashable {
    public var token: String?
    public var owner: String?
    public var comment: String?
    public var createdAt: Date?

    public init(token: String? = nil, owner: String? = nil, comment: String? = nil, createdAt: Date? = nil) {
        self.token = token
        self.owner = owner
        self.comment = comment
        self.createdAt = createdAt
    }
}

/// Commit metadata attached to a working-copy entry's base revision.
public struct CommitInfo: Sendable, Hashable {
    public var revision: Int64
    public var author: String?
    public var date: Date?

    public init(revision: Int64, author: String? = nil, date: Date? = nil) {
        self.revision = revision
        self.author = author
        self.date = date
    }
}

/// One entry of `svn status --xml`.
public struct StatusEntry: Sendable, Hashable, Identifiable {
    /// Path exactly as reported by svn (absolute when `--xml` is used with an
    /// absolute target, otherwise relative to the target).
    public var path: String
    public var item: WCItemStatus
    public var properties: WCItemStatus
    public var revision: Int64?
    public var isCopied: Bool
    public var conflicts: ConflictFlags
    /// The lock token *this* working copy holds, from `<wc-status><lock>`.
    public var repositoryLock: RepositoryLock?
    /// The lock the server reports, from `<repos-status><lock>`.
    ///
    /// Only populated by `svn status --show-updates`. Kept apart from
    /// `repositoryLock` because holding a token and seeing someone else's lock
    /// are different situations with different remedies (`unlock` vs "ask the
    /// owner, or steal it").
    public var remoteLock: RepositoryLock?
    /// What the *server* has for this path, from `<repos-status item="...">`.
    ///
    /// Only populated by `svn status --show-updates`, and only for paths that
    /// actually differ from the base revision: svn omits `<repos-status>`
    /// entirely otherwise, so `nil` means "unchanged on the server", not
    /// "unknown".
    public var remoteItem: WCItemStatus?
    public var remoteProperties: WCItemStatus?
    /// Working-copy internal lock / incomplete operation marker. Populated from
    /// `svn cleanup`-class failures or a `tree-conflicted` marker, never from a
    /// repository lock.
    public var isWorkingCopyLocked: Bool
    public var changelist: String?
    public var commit: CommitInfo?
    public var depth: String?

    public var id: String { path }

    public init(
        path: String,
        item: WCItemStatus,
        properties: WCItemStatus = .none,
        revision: Int64? = nil,
        isCopied: Bool = false,
        conflicts: ConflictFlags = [],
        repositoryLock: RepositoryLock? = nil,
        remoteLock: RepositoryLock? = nil,
        remoteItem: WCItemStatus? = nil,
        remoteProperties: WCItemStatus? = nil,
        isWorkingCopyLocked: Bool = false,
        changelist: String? = nil,
        commit: CommitInfo? = nil,
        depth: String? = nil
    ) {
        self.path = path
        self.item = item
        self.properties = properties
        self.revision = revision
        self.isCopied = isCopied
        self.conflicts = conflicts
        self.repositoryLock = repositoryLock
        self.remoteLock = remoteLock
        self.remoteItem = remoteItem
        self.remoteProperties = remoteProperties
        self.isWorkingCopyLocked = isWorkingCopyLocked
        self.changelist = changelist
        self.commit = commit
        self.depth = depth
    }

    /// The lock to show for this entry, whether it is ours or someone else's.
    public var effectiveLock: RepositoryLock? { repositoryLock ?? remoteLock }

    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    public var hasConflicts: Bool { conflicts.hasAnyConflict }

    /// Grouping used by the Changes page and by `data-models.md`.
    public var category: StatusCategory {
        if hasConflicts { return .conflicted }
        switch item {
        case .added, .replaced: return .added
        case .deleted, .missing: return .deleted
        case .modified, .merged: return .modified
        case .unversioned: return .unversioned
        case .ignored, .external: return .ignored
        case .normal, .none: return propertyOrNone
        default: return .other
        }
    }

    private var propertyOrNone: StatusCategory {
        properties == .modified ? .modified : .normal
    }
}

public enum StatusCategory: String, Sendable, Hashable, CaseIterable {
    case conflicted
    case modified
    case added
    case deleted
    case unversioned
    case ignored
    case normal
    case other
}

/// The result of one `svn status --xml` invocation.
public struct StatusSnapshot: Sendable, Hashable {
    public var target: String?
    public var entries: [StatusEntry]
    /// Revision of the working copy root at scan time, when svn reports it.
    public var workingCopyRevision: Int64?
    /// The server's head revision, from `<against revision="N">`.
    ///
    /// Only present with `--show-updates`. This is the revision an `update`
    /// would bring the working copy to, which is why the update preview can
    /// name a target revision before running anything.
    public var serverRevision: Int64?

    public init(
        target: String? = nil,
        entries: [StatusEntry],
        workingCopyRevision: Int64? = nil,
        serverRevision: Int64? = nil
    ) {
        self.target = target
        self.entries = entries
        self.workingCopyRevision = workingCopyRevision
        self.serverRevision = serverRevision
    }

    public var conflicted: [StatusEntry] { entries.filter(\.hasConflicts) }
    public var changed: [StatusEntry] { entries.filter { $0.item.isCommittableChange || $0.properties == .modified } }
    public var unversioned: [StatusEntry] { entries.filter { $0.item == .unversioned } }
    public var missing: [StatusEntry] { entries.filter { $0.item == .missing } }

    public var isEmpty: Bool { entries.isEmpty }
}
