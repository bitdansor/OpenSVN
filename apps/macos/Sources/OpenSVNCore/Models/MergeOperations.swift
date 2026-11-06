import Foundation

/// How `svn merge` / `svn switch` should settle a conflict while running under
/// `--non-interactive` (which the service always adds).
///
/// The raw values are the exact `--accept` tokens. `edit` and `launch` are
/// deliberately absent: they open an interactive tool and would hang a headless
/// subprocess. `postpone` is the safe default — it merely records the conflict
/// and leaves the decision to the resolve/merge-editor flow.
public enum SVNAccept: String, Sendable, Hashable, CaseIterable {
    case postpone
    case working
    case base
    case mineFull = "mine-full"
    case theirsFull = "theirs-full"
    case mineConflict = "mine-conflict"
    case theirsConflict = "theirs-conflict"

    /// Overwriting strategies discard local or incoming content, so a caller
    /// combining them with a merge should treat the merge as destructive.
    public var isOverwriting: Bool {
        switch self {
        case .mineFull, .theirsFull, .base: return true
        default: return false
        }
    }
}

/// Revision selection for an automatic (sync / cherry-pick) merge.
public enum MergeRevisions: Sendable, Hashable {
    /// `-r N:M`. A reverse merge (`N > M`) is allowed: that is how svn reverts
    /// an already-committed change.
    case range(from: Int64, to: Int64)
    /// `-c N[,M...]`. svn accepts a comma-separated list of single revisions.
    case changes([Int64])
}

/// Everything `svn merge` needs, as a value so the command line can be built and
/// asserted on without spawning a process.
///
/// svn 1.8 folded the old `--reintegrate` form into the "automatic" merge; on
/// 1.14 `svn merge SOURCE` is the sync/reintegrate merge driven by `svn:mergeinfo`.
/// The classic "two-URL merge" is still available and is the other supported form.
public struct MergeRequest: Sendable, Hashable {
    public enum Style: Sendable, Hashable {
        /// `svn merge [-r N:M | -c N] SOURCE[@PEG] [TARGET_WCPATH]`.
        /// Automatic (sync / reintegrate) merge with merge tracking.
        case automatic(sourceURL: String, revisions: MergeRevisions? = nil)
        /// `svn merge SOURCE1[@N] SOURCE2[@M] [TARGET_WCPATH]`.
        /// Classic two-URL merge; `--ignore-ancestry` is often wanted here.
        case twoURL(leftURL: String, rightURL: String)
    }

    public var style: Style
    /// Working-copy path that receives the merge.
    public var target: URL
    /// `--record-only`: update `svn:mergeinfo` without applying the changes.
    public var recordOnly: Bool
    public var accept: SVNAccept
    /// `--ignore-ancestry`: merge unrelated trees without copy-history checks.
    public var ignoreAncestry: Bool

    public init(
        style: Style,
        target: URL,
        recordOnly: Bool = false,
        accept: SVNAccept = .postpone,
        ignoreAncestry: Bool = false
    ) {
        self.style = style
        self.target = target
        self.recordOnly = recordOnly
        self.accept = accept
        self.ignoreAncestry = ignoreAncestry
    }

    /// The URL used to scope Keychain lookups and to describe the merge source.
    public var primarySourceURL: String {
        switch style {
        case .automatic(let sourceURL, _): return sourceURL
        case .twoURL(let leftURL, _): return leftURL
        }
    }

    /// Cheap, process-free validation. Naming an empty operand here is far more
    /// useful than the generic error svn would produce for it.
    public func validate() throws {
        switch style {
        case .automatic(let sourceURL, let revisions):
            guard !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SVNError(code: .invalidInvocation, message: "合并来源 URL 不能为空")
            }
            if let revisions {
                switch revisions {
                case .changes(let list) where list.isEmpty:
                    throw SVNError(code: .invalidInvocation, message: "挑拣合并至少需要一个修订号")
                default:
                    break
                }
            }
        case .twoURL(let leftURL, let rightURL):
            guard !leftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rightURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SVNError(code: .invalidInvocation, message: "两 URL 合并的两个来源都不能为空")
            }
        }
    }
}

/// Builds the `svn merge` argument array. Pure: no filesystem, no subprocess.
public enum MergeArguments {
    public static func make(_ request: MergeRequest) -> [String] {
        var revisionOptions: [String] = []
        var operands: [String] = []

        switch request.style {
        case .automatic(let sourceURL, let revisions):
            if let revisions {
                switch revisions {
                case .range(let from, let to):
                    revisionOptions = ["-r", "\(from):\(to)"]
                case .changes(let list):
                    revisionOptions = ["-c", list.map { String($0) }.joined(separator: ",")]
                }
            }
            operands = [sourceURL]
        case .twoURL(let leftURL, let rightURL):
            operands = [leftURL, rightURL]
        }

        var args: [String] = ["merge"]
        // Revision selection is an option, so it must precede the operands.
        args += revisionOptions
        // An explicit --accept keeps a conflict from becoming an interactive
        // prompt (svn is always launched with --non-interactive here).
        args += ["--accept", request.accept.rawValue]
        if request.recordOnly { args.append("--record-only") }
        if request.ignoreAncestry { args.append("--ignore-ancestry") }
        args += operands
        args.append(request.target.standardizedFileURL.path)
        return args
    }
}

/// Read-only description of a merge, built from the request alone.
///
/// Deliberately does not scan the working copy: a preview that is a pure
/// computation is always available (offline, in tests, before a checkout
/// exists), and the "what would I lose" question is answered separately by
/// `status` / `remotePreview`. This is a warning, not a verdict — matching the
/// philosophy of `RemotePreview`.
public enum MergePreview {
    public static func make(from request: MergeRequest) -> OperationPreview {
        let targetName = request.target.lastPathComponent
        let summary: String
        switch request.style {
        case .automatic(let sourceURL, _):
            summary = "将「\(leaf(sourceURL))」合并到「\(targetName)」"
        case .twoURL(let leftURL, let rightURL):
            summary = "将「\(leaf(leftURL))」与「\(leaf(rightURL))」的差异合并到「\(targetName)」"
        }

        var notes: [String] = [
            "这是本地合并：改动先进入工作副本，需要再执行一次提交才会进入仓库。",
            "工作副本里未提交的修改可能与合并结果冲突；合并不会自动解决冲突，冲突会保留为待解决状态。",
            "本预览不扫描工作副本，合并前请先刷新状态查看本地改动。"
        ]
        if request.recordOnly {
            notes.append("已启用 --record-only：只更新 svn:mergeinfo 合并记录，不改动文件内容。")
        }
        if request.accept.isOverwriting {
            notes.append("已指定 --accept \(request.accept.rawValue)：冲突处理会覆盖本地或服务器端内容，不可撤销。")
        }

        return OperationPreview(
            summary: summary,
            detail: notes.joined(separator: "\n"),
            // A normal merge rewrites working files; record-only touches only
            // the versioned mergeinfo property, so it is one level less risky.
            risk: request.recordOnly ? .medium : .high,
            affectedPaths: [request.target.standardizedFileURL.path],
            discardedPaths: []
        )
    }

    private static func leaf(_ url: String) -> String {
        let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? url : name
    }
}

/// The path-level changes `svn merge` / `svn switch` printed on stdout.
///
/// `svn merge` has no `--xml`; these lines are progress/summary only. Conflict
/// state must still be read from `status --xml`. "Skipped" lines are quoted
/// paths that `SVNOutputParser.parseUpdate` intentionally ignores, so they are
/// collected separately here.
public struct WorkingCopyChanges: Sendable, Hashable {
    public var added: [String]
    public var deleted: [String]
    public var updated: [String]
    public var merged: [String]
    public var conflicted: [String]
    public var skipped: [String]

    public init(
        added: [String] = [],
        deleted: [String] = [],
        updated: [String] = [],
        merged: [String] = [],
        conflicted: [String] = [],
        skipped: [String] = []
    ) {
        self.added = added
        self.deleted = deleted
        self.updated = updated
        self.merged = merged
        self.conflicted = conflicted
        self.skipped = skipped
    }

    public var hasConflicts: Bool { !conflicted.isEmpty }

    public static func parse(_ output: String) -> WorkingCopyChanges {
        let parsed = SVNOutputParser.parseUpdate(output)
        return WorkingCopyChanges(
            added: parsed.added,
            deleted: parsed.deleted,
            updated: parsed.updated,
            merged: parsed.merged,
            conflicted: parsed.conflicted,
            skipped: skippedPaths(in: output)
        )
    }

    private static func skippedPaths(in output: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"^Skipped[^']*'([^']+)'"#,
            options: [.anchorsMatchLines]
        ) else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        return regex.matches(in: output, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: output) else { return nil }
            return String(output[captured])
        }
    }
}

/// Result of a successful `svn merge`.
public struct MergeOutcome: Sendable, Hashable {
    public var target: String
    public var changes: WorkingCopyChanges
    public var recordOnly: Bool
    /// Redacted stdout, for the task detail and diagnostics.
    public var rawOutput: String

    public init(
        target: String,
        changes: WorkingCopyChanges = WorkingCopyChanges(),
        recordOnly: Bool = false,
        rawOutput: String = ""
    ) {
        self.target = target
        self.changes = changes
        self.recordOnly = recordOnly
        self.rawOutput = rawOutput
    }

    public var hasConflicts: Bool { changes.hasConflicts }

    public static func make(target: URL, recordOnly: Bool, from output: String) -> MergeOutcome {
        MergeOutcome(
            target: target.standardizedFileURL.path,
            changes: WorkingCopyChanges.parse(output),
            recordOnly: recordOnly,
            rawOutput: LogRedactor.redact(output)
        )
    }
}

/// Which set of revisions `svn mergeinfo --show-revs` should report.
public enum MergeInfoRevisions: String, Sendable, Hashable, CaseIterable {
    /// Revisions already merged from the source into the target.
    case merged
    /// Revisions still eligible to be merged.
    case eligible

    /// Parses `svn mergeinfo --show-revs <merged|eligible>`: one revision per
    /// line, printed as `r<N>` (optionally with a trailing `*` marker).
    ///
    /// Tolerant of bare numbers and trailing whitespace; a line that cannot be
    /// read as a revision is skipped rather than failing the whole read.
    public static func parse(_ output: String) -> [Int64] {
        var result: [Int64] = []
        for rawLine in output.split(separator: "\n") {
            var token = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if token.hasPrefix("r") || token.hasPrefix("R") { token = String(token.dropFirst()) }
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: "* \t"))
            if let number = Int64(token) { result.append(number) }
        }
        return result
    }
}

/// One inclusive revision range inside a `svn:mergeinfo` value. A single
/// revision is represented with `lower == upper`. `nonInheritable` is the `*`
/// suffix svn uses to mark a range that must not be inherited by children.
public struct MergeInfoRange: Sendable, Hashable {
    public var lower: Int64
    public var upper: Int64
    public var nonInheritable: Bool

    public init(lower: Int64, upper: Int64, nonInheritable: Bool = false) {
        self.lower = lower
        self.upper = upper
        self.nonInheritable = nonInheritable
    }
}

/// One `path:rangelist` line of a `svn:mergeinfo` property value.
public struct MergeInfoLine: Sendable, Hashable {
    public var sourcePath: String
    public var ranges: [MergeInfoRange]

    public init(sourcePath: String, ranges: [MergeInfoRange] = []) {
        self.sourcePath = sourcePath
        self.ranges = ranges
    }
}

/// Parses the raw text of a `svn:mergeinfo` property (`svn propget`).
///
/// Example value:
/// ```
/// /trunk:1-5,7,9-11
/// /branches/feature:3-9*
/// ```
/// Ranges are kept as ranges on purpose: expanding `1-100000` into an array of
/// revisions would be wasteful and would lose the `*` marker.
public enum MergeInfoProperty {
    public static func parse(_ text: String) -> [MergeInfoLine] {
        var result: [MergeInfoLine] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            // The ranges part contains no colon, so the last colon is the
            // separator even if the source path itself contains one.
            guard !line.isEmpty,
                  let colon = line.range(of: ":", options: .backwards) else { continue }
            let sourcePath = String(line[line.startIndex..<colon.lowerBound])
            guard !sourcePath.isEmpty else { continue }

            var ranges: [MergeInfoRange] = []
            for rawToken in line[colon.upperBound...].split(separator: ",") {
                var token = String(rawToken).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { continue }
                let nonInheritable = token.hasSuffix("*")
                if nonInheritable { token = String(token.dropLast()) }
                let parts = token.split(separator: "-", maxSplits: 1)
                guard let lower = Int64(String(parts[0])) else { continue }
                let upper = parts.count > 1 ? (Int64(String(parts[1])) ?? lower) : lower
                ranges.append(MergeInfoRange(lower: lower, upper: upper, nonInheritable: nonInheritable))
            }
            result.append(MergeInfoLine(sourcePath: sourcePath, ranges: ranges))
        }
        return result
    }
}
