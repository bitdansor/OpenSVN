import Foundation

/// Everything `svn switch` needs, as a value so the command line can be built
/// and asserted on without spawning a process.
///
/// `switch` repoints a working copy at a *different URL inside the same
/// repository* (a branch). It is not `relocate` (same repository, new network
/// address) and it is not a way to mix two histories: svn checks the repository
/// UUID and refuses a switch to a different repository.
public struct SwitchRequest: Sendable, Hashable {
    /// A different URL inside the same repository, optionally `URL@PEGREV`.
    public var url: String
    /// Working-copy path to repoint.
    public var target: URL
    /// `-r N`: operative revision to switch to.
    public var revision: Int64?
    public var accept: SVNAccept
    /// `--ignore-externals`: leave external working copies alone.
    public var ignoreExternals: Bool
    /// `--force`: allow unversioned obstructions to be overwritten.
    public var force: Bool

    public init(
        url: String,
        target: URL,
        revision: Int64? = nil,
        accept: SVNAccept = .postpone,
        ignoreExternals: Bool = false,
        force: Bool = false
    ) {
        self.url = url
        self.target = target
        self.revision = revision
        self.accept = accept
        self.ignoreExternals = ignoreExternals
        self.force = force
    }

    public func validate() throws {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SVNError(code: .invalidInvocation, message: "切换目标 URL 不能为空")
        }
    }
}

/// Builds the `svn switch` argument array. Pure: no filesystem, no subprocess.
public enum SwitchArguments {
    public static func make(_ request: SwitchRequest) -> [String] {
        var args: [String] = ["switch"]
        if let revision = request.revision { args += ["-r", String(revision)] }
        args += ["--accept", request.accept.rawValue]
        if request.ignoreExternals { args.append("--ignore-externals") }
        if request.force { args.append("--force") }
        args.append(request.url)
        args.append(request.target.standardizedFileURL.path)
        return args
    }
}

/// Read-only description of a switch, built from the request alone.
public enum SwitchPreview {
    public static func make(from request: SwitchRequest) -> OperationPreview {
        let targetName = request.target.lastPathComponent
        let summary = "将「\(targetName)」切换到「\(leaf(request.url))」"

        var notes: [String] = [
            "切换会把工作副本整体指向同一仓库内的另一个 URL（分支）；仓库 UUID 由 svn 校验，切到别的仓库会失败。",
            "本地未提交的修改会被尽量保留，但与切换后内容冲突时会进入待解决状态，不会自动合并。",
            "本预览不扫描工作副本，切换前请先刷新状态查看并妥善处理本地改动。"
        ]
        if let revision = request.revision {
            notes.append("目标修订号：-r \(revision)。")
        }
        if request.ignoreExternals {
            notes.append("已启用 --ignore-externals：外挂工作副本不会被更新。")
        }
        if request.force {
            notes.append("已启用 --force：未纳入版本控制的同名文件可能被覆盖。")
        }
        if request.accept.isOverwriting {
            notes.append("已指定 --accept \(request.accept.rawValue)：冲突处理会覆盖本地或服务器端内容，不可撤销。")
        }

        return OperationPreview(
            summary: summary,
            detail: notes.joined(separator: "\n"),
            risk: request.force || request.accept.isOverwriting ? .high : .medium,
            affectedPaths: [request.target.standardizedFileURL.path],
            discardedPaths: []
        )
    }

    private static func leaf(_ url: String) -> String {
        // A peg revision (`URL@123`) is not part of the display name.
        let base = url.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map { String($0) } ?? url
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? url : name
    }
}

/// Result of a successful `svn switch`.
public struct SwitchOutcome: Sendable, Hashable {
    public var target: String
    public var url: String
    public var changes: WorkingCopyChanges
    /// Redacted stdout, for the task detail and diagnostics.
    public var rawOutput: String

    public init(
        target: String,
        url: String,
        changes: WorkingCopyChanges = WorkingCopyChanges(),
        rawOutput: String = ""
    ) {
        self.target = target
        self.url = url
        self.changes = changes
        self.rawOutput = rawOutput
    }

    public var hasConflicts: Bool { changes.hasConflicts }

    public static func make(target: URL, url: String, from output: String) -> SwitchOutcome {
        SwitchOutcome(
            target: target.standardizedFileURL.path,
            url: url,
            changes: WorkingCopyChanges.parse(output),
            rawOutput: LogRedactor.redact(output)
        )
    }
}
