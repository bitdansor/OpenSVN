import Foundation

/// Progress reported by long-running operations. The UI renders `message`;
/// `fraction` is only set when a meaningful ratio is known.
public struct SVNTaskProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case preparing
        case running
        case finishing
        case finished
    }

    public var phase: Phase
    public var message: String
    /// 0...1 when computable, otherwise nil (indeterminate).
    public var fraction: Double?

    public init(phase: Phase, message: String, fraction: Double? = nil) {
        self.phase = phase
        self.message = message
        self.fraction = fraction
    }

    public static func running(_ message: String) -> SVNTaskProgress {
        SVNTaskProgress(phase: .running, message: message)
    }
}

/// A tiny wrapper instead of a bare closure type.
///
/// A struct can be stored and forwarded freely, which keeps `progress`
/// parameters usable from escaping contexts (tasks, task centers) without
/// sprinkling `@escaping` through the whole call chain.
public struct SVNProgressReporter: Sendable {
    private let handler: @Sendable (SVNTaskProgress) -> Void

    public init(_ handler: @escaping @Sendable (SVNTaskProgress) -> Void) {
        self.handler = handler
    }

    public func callAsFunction(_ progress: SVNTaskProgress) {
        handler(progress)
    }

    public func report(_ progress: SVNTaskProgress) {
        handler(progress)
    }
}

public typealias SVNProgressHandler = SVNProgressReporter

/// A read-only description of a destructive operation, produced before it runs
/// so the user (or an automated caller) can decide whether to confirm.
public struct OperationPreview: Sendable, Hashable {
    public enum Risk: String, Sendable, Hashable {
        case low
        case medium
        case high
    }

    public var summary: String
    public var detail: String
    public var risk: Risk
    /// Paths that will be modified, deleted, or overwritten.
    public var affectedPaths: [String]
    /// Local modifications that will be lost.
    public var discardedPaths: [String]

    public init(
        summary: String,
        detail: String,
        risk: Risk,
        affectedPaths: [String],
        discardedPaths: [String] = []
    ) {
        self.summary = summary
        self.detail = detail
        self.risk = risk
        self.affectedPaths = affectedPaths
        self.discardedPaths = discardedPaths
    }
}

/// Summary of `svn update`.
public struct UpdateSummary: Sendable, Hashable {
    public var target: String
    public var fromRevision: Int64?
    public var toRevision: Int64?
    public var updatedPaths: [String]
    public var conflictedPaths: [String]
    public var removedPaths: [String]
    public var rawOutput: String

    public init(
        target: String,
        fromRevision: Int64? = nil,
        toRevision: Int64? = nil,
        updatedPaths: [String] = [],
        conflictedPaths: [String] = [],
        removedPaths: [String] = [],
        rawOutput: String = ""
    ) {
        self.target = target
        self.fromRevision = fromRevision
        self.toRevision = toRevision
        self.updatedPaths = updatedPaths
        self.conflictedPaths = conflictedPaths
        self.removedPaths = removedPaths
        self.rawOutput = rawOutput
    }
}

/// Summary of `svn commit`.
public struct CommitSummary: Sendable, Hashable {
    public var revision: Int64?
    public var committedPaths: [String]
    public var rawOutput: String

    public init(revision: Int64? = nil, committedPaths: [String] = [], rawOutput: String = "") {
        self.revision = revision
        self.committedPaths = committedPaths
        self.rawOutput = rawOutput
    }
}

/// How a conflict should be resolved. Mirrors `svn resolve --accept=<arg>`
/// exactly, including the irreversible options — see `svn-operations.md`.
public enum ResolveStrategy: String, Sendable, Hashable, CaseIterable {
    /// Keep the file as it is on disk (still containing conflict markers) and
    /// only clear the conflict state.
    case working
    /// Discard the incoming changes, keep my version.
    case mineFull = "mine-full"
    /// Discard all local changes, take the repository version.
    case theirsFull = "theirs-full"
    /// Revert to the pristine base revision.
    case base

    public var isDestructive: Bool {
        switch self {
        case .mineFull, .theirsFull, .base: return true
        case .working: return false
        }
    }

    /// Menu title. Never expose `rawValue` in the UI: `--accept` tokens are
    /// implementation details and, per 执行计划 §7, each option must state its
    /// consequence in plain language.
    public var title: String {
        switch self {
        case .working:
            return "保留当前内容，仅清除冲突标记"
        case .mineFull:
            return "用我的版本覆盖（丢弃服务器改动）"
        case .theirsFull:
            return "用服务器版本覆盖（丢弃我的改动）"
        case .base:
            return "恢复基线版本（丢弃双方改动）"
        }
    }

    /// SF Symbol hinting that the option cannot be undone.
    public var menuSymbol: String {
        isDestructive ? "exclamationmark.triangle" : "checkmark.circle"
    }

    /// One-sentence, human-readable consequence, shown next to each option.
    public var consequence: String {
        switch self {
        case .working:
            return "保留磁盘上的当前内容（可能仍含冲突标记），仅清除冲突状态。"
        case .mineFull:
            return "丢弃服务器带来的修改，只保留本地版本。此操作不可撤销。"
        case .theirsFull:
            return "丢弃全部本地修改，改用服务器版本。此操作不可撤销。"
        case .base:
            return "还原到冲突前的基线版本，本地与该次服务器修改都会被丢弃。"
        }
    }
}
