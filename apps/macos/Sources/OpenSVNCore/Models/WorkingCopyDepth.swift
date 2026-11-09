import Foundation

/// A depth a *sparse* working copy can be moved to with `svn update --set-depth`.
///
/// Deliberately not the same type as `SVNService.CheckoutDepth`: `--depth` takes
/// four values and `--set-depth` takes five, the extra one being `exclude`, which
/// svn rejects on checkout. Sharing one enum would make an impossible command
/// line representable, which is the sort of thing a compiler should catch.
public enum WorkingCopyDepth: String, Sendable, Hashable, CaseIterable, Codable {
    /// Everything, recursively.
    case infinity
    /// This directory and its immediate children, no deeper.
    case immediates
    /// The files in this directory, but no subdirectories.
    case files
    /// This directory only: its children are removed and remembered as absent.
    case empty
    /// Remove the path from the working copy entirely, remembering nothing.
    case exclude

    /// Maps svn's `<depth>` value. `nil` for anything unrecognised so a newer svn
    /// cannot make the UI claim a depth it does not understand.
    public static func parse(_ raw: String?) -> WorkingCopyDepth? {
        guard let raw else { return nil }
        return WorkingCopyDepth(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public var displayName: String {
        switch self {
        case .infinity: return L.t("完整（含所有子目录）")
        case .immediates: return L.t("仅直接子项")
        case .files: return L.t("仅文件")
        case .empty: return L.t("仅目录本身")
        case .exclude: return L.t("排除（从工作副本移除）")
        }
    }

    /// What the change actually does, in one sentence, for the picker's caption.
    public var explanation: String {
        switch self {
        case .infinity:
            return L.t("递归取出全部内容。已经排除的路径不会自动回来，需要单独设置。")
        case .immediates:
            return L.t("取出这一层和直接子项；子目录保留为空壳，内部内容不下载。")
        case .files:
            return L.t("只取出这一层的文件，子目录整体不下载。")
        case .empty:
            return L.t("只保留这个目录本身，子项从磁盘删除但仓库里仍然记得它们。")
        case .exclude:
            return L.t("把这个路径从工作副本里彻底移除，磁盘上的内容会被删除。")
        }
    }

    /// `exclude` is the only value that deletes anything from disk.
    public var removesContent: Bool { self == .exclude }

    /// Why a shrinking change needs a pre-check, stated once and reused by the
    /// service and the UI.
    ///
    /// Measured with svn 1.15.0: excluding a directory that still holds
    /// unversioned or ignored files does *not* remove it. svn un-version-controls
    /// the subtree instead, leaves the files on disk, and in the unversioned-file
    /// case leaves the working copy locked — while still exiting 0. An app that
    /// trusts the exit code reports success over a mangled working copy.
    public var warning: String? {
        switch self {
        case .exclude:
            return L.t("磁盘上的文件会被删除，且仓库不再记得它们。目录里若有未纳入版本控制的文件，svn 会留下一个半成品并可能锁住工作副本，所以必须先清空。")
        case .empty:
            return L.t("子项会从磁盘删除。它们仍在仓库里，改回更大的深度即可重新取回。")
        default:
            return nil
        }
    }
}

/// Builds the `svn update` argument array. Pure: no filesystem, no subprocess.
public enum UpdateArguments {
    /// - Parameter setDepth: changes how much of the subtree is present *now*.
    ///   It is passed to the service only when `revision` is `nil`; the service
    ///   refuses the combination, because svn applies both at once and a path
    ///   that does not exist at the given revision is deleted outright
    ///   (measured: `svn update -r 1 --set-depth immediates dir` removed `dir`).
    public static func make(
        target: URL,
        revision: Int64?,
        setDepth: WorkingCopyDepth?
    ) -> [String] {
        var args = ["update", "--accept", "postpone"]
        if let setDepth { args += ["--set-depth", setDepth.rawValue] }
        if let revision { args += ["-r", String(revision)] }
        args.append(SVNPeg.escape(target.standardizedFileURL.path))
        return args
    }
}

/// Escaping for svn's peg-revision parsing.
///
/// Every svn path operand is read as `PATH@PEG`, and peg parsing happens before
/// option parsing, so `--` does not protect a path containing `@`. appending one
/// `@` is svn's documented way to say "the `@` is part of the name"; on a path
/// that already ends in `@` this yields `@@`, which svn reads correctly.
public enum SVNPeg {
    public static func escape(_ path: String) -> String {
        path.contains("@") ? path + "@" : path
    }
}
