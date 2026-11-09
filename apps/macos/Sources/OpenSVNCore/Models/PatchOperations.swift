import Foundation

/// A `svn patch` request.
///
/// `svn patch` is not a diff viewer: it applies a unidiff to the working copy and
/// can schedule additions and deletions. It is also the one svn command whose
/// exit status is useless — measured with svn 1.15.0, a run that rejected every
/// hunk, and a run that skipped every path because the targets did not exist,
/// both returned **0**. Success has to be read out of the output, which is why
/// `PatchOutcome` exists rather than a `Void` return.
public struct PatchRequest: Sendable, Hashable {
    /// Absolute path to the patch file. Relative paths would resolve against the
    /// app's working directory, which is not the user's.
    public var patchFile: URL
    /// Working-copy path the patch is applied to. A file or a directory.
    public var target: URL
    /// `--strip N`: leading path components to drop from paths inside the patch.
    ///
    /// A patch produced by `svn diff` inside a working copy is written with the
    /// working copy's own name as the first component (`--- wc/f.txt`), so
    /// applying it to `wc` needs `1` or svn looks for `wc/wc/f.txt` and silently
    /// skips. Default 0 matches svn's default; the UI explains when to raise it.
    public var strip: Int
    /// `--reverse-diff`: apply backwards, i.e. undo the change the patch encodes.
    public var reverse: Bool
    /// `--ignore-whitespace`.
    public var ignoreWhitespace: Bool
    /// `--dry-run`: report what would happen and change nothing.
    public var dryRun: Bool

    public init(
        patchFile: URL,
        target: URL,
        strip: Int = 0,
        reverse: Bool = false,
        ignoreWhitespace: Bool = false,
        dryRun: Bool = false
    ) {
        self.patchFile = patchFile
        self.target = target
        self.strip = strip
        self.reverse = reverse
        self.ignoreWhitespace = ignoreWhitespace
        self.dryRun = dryRun
    }

    public func validate() throws {
        guard strip >= 0 else {
            throw SVNError(code: .invalidInvocation, message: L.t("剥离层数不能为负数"))
        }
        guard FileManager.default.isReadableFile(atPath: patchFile.path) else {
            throw SVNError(
                code: .pathNotFound,
                message: L.f("读不到补丁文件：%@", String(describing: patchFile.path))
            )
        }
    }

    /// The same request as a real application. Used after a dry run so the two
    /// invocations cannot drift apart.
    public func applying() -> PatchRequest {
        var copy = self
        copy.dryRun = false
        return copy
    }
}

/// Builds the `svn patch` argument array. Pure: no filesystem, no subprocess.
public enum PatchArguments {
    public static func make(_ request: PatchRequest) -> [String] {
        var args = ["patch"]
        if request.dryRun { args.append("--dry-run") }
        if request.reverse { args.append("--reverse-diff") }
        if request.ignoreWhitespace { args.append("--ignore-whitespace") }
        if request.strip > 0 { args += ["--strip", String(request.strip)] }
        // The patch file is a path operand like any other, so it is peg-escaped
        // too; svn reads `PATCHFILE` before `WCPATH`, and both may contain `@`.
        args.append(SVNPeg.escape(request.patchFile.standardizedFileURL.path))
        args.append(SVNPeg.escape(request.target.standardizedFileURL.path))
        return args
    }
}

/// What `svn patch` reported, per file, in svn's own vocabulary.
public struct PatchOutcome: Sendable, Hashable {
    public var target: String
    public var isDryRun: Bool
    /// Files the patch created, scheduled for addition.
    public var added: [String] = []
    public var updated: [String] = []
    /// Deleted, i.e. scheduled for deletion — `svn revert` undoes it.
    public var deleted: [String] = []
    /// Applied, but the file already had local modifications.
    public var merged: [String] = []
    /// Hunks that did not match. svn writes `<file>.svnpatch.rej` beside each.
    public var conflicted: [String] = []
    /// Targets svn could not find, e.g. a wrong `--strip`.
    public var skipped: [String] = []
    /// Lines svn prefixed with `>`: offsets, fuzz, "already applied", rejected hunks.
    public var notes: [String] = []
    public var conflictSummary: String?
    public var rawOutput: String

    public init(
        target: String,
        isDryRun: Bool,
        added: [String] = [],
        updated: [String] = [],
        deleted: [String] = [],
        merged: [String] = [],
        conflicted: [String] = [],
        skipped: [String] = [],
        notes: [String] = [],
        conflictSummary: String? = nil,
        rawOutput: String = ""
    ) {
        self.target = target
        self.isDryRun = isDryRun
        self.added = added
        self.updated = updated
        self.deleted = deleted
        self.merged = merged
        self.conflicted = conflicted
        self.skipped = skipped
        self.notes = notes
        self.conflictSummary = conflictSummary
        self.rawOutput = rawOutput
    }

    /// Paths the patch actually touched, in any way.
    public var touched: [String] { added + updated + deleted + merged }

    public var appliedCount: Int { touched.count }

    public var hasConflicts: Bool { !conflicted.isEmpty }

    /// True only when something was applied and nothing was lost. This is the
    /// judgement svn's exit code cannot make.
    public var succeeded: Bool {
        appliedCount > 0 && !hasConflicts && skipped.isEmpty
    }

    /// Shown after a real run. A dry run says so, because "已应用 0 个文件" is
    /// confusing when the user only asked what *would* happen.
    public var summary: String {
        var parts = [
            isDryRun
                ? L.n("将影响 %d 个文件", appliedCount)
                : L.n("已应用 %d 个文件", appliedCount)
        ]
        if !added.isEmpty { parts.append(L.f("新增 %@", String(added.count))) }
        if !deleted.isEmpty { parts.append(L.f("删除 %@", String(deleted.count))) }
        if !merged.isEmpty { parts.append(L.f("合并 %@", String(merged.count))) }
        if !conflicted.isEmpty { parts.append(L.f("冲突 %@", String(conflicted.count))) }
        if !skipped.isEmpty { parts.append(L.f("跳过 %@", String(skipped.count))) }
        return parts.joined(separator: L.t("，"))
    }
}
