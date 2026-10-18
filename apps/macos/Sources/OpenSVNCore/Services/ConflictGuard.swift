import Foundation

/// A copy of the conflict-related files taken *before* `svn resolve`, so that a
/// wrong `--accept` choice can be undone by hand. The repository history cannot
/// help here: `mine-full` / `theirs-full` / `base` overwrite the working file,
/// and `svn` keeps no local copy of what was there.
public struct ConflictBackup: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        /// Absolute path the file was copied from.
        public let sourcePath: String
        /// Absolute path inside the backup directory.
        public let backupPath: String
        public let byteCount: Int
    }

    public let directory: URL
    public let createdAt: Date
    /// Why the backup was taken, e.g. `resolve-theirs-full`.
    public let reason: String
    public let entries: [Entry]

    public var isEmpty: Bool { entries.isEmpty }
}

/// Leftover-conflict-marker scan performed *after* a resolve.
///
/// `svn resolve --accept=working` only clears the conflict *state*; the file may
/// still literally contain `<<<<<<<` / `>>>>>>>` lines. Committing that is the
/// classic way to ship conflict markers, so we look for them and say so.
public struct ConflictMarkerScan: Sendable, Hashable {
    public enum Result: Sendable, Hashable {
        case clean
        case unresolved(markerLines: [Int])
        /// Binary, unreadable, or too large to scan. Not a failure.
        case skipped(reason: String)
    }

    public let path: String
    public let result: Result

    public var hasUnresolvedMarkers: Bool {
        if case .unresolved = result { return true }
        return false
    }
}

/// What `SVNService.resolve` reports back.
public struct ResolveOutcome: Sendable {
    public let resolvedPaths: [String]
    public let backup: ConflictBackup?
    public let scans: [ConflictMarkerScan]

    public init(
        resolvedPaths: [String] = [],
        backup: ConflictBackup? = nil,
        scans: [ConflictMarkerScan] = []
    ) {
        self.resolvedPaths = resolvedPaths
        self.backup = backup
        self.scans = scans
    }

    /// Files that still contain conflict markers after the resolve.
    public var pathsWithResidualMarkers: [String] {
        scans.filter(\.hasUnresolvedMarkers).map(\.path)
    }
}

/// Backs up conflict artifacts and verifies that a resolve actually left the
/// file clean. Filesystem-only; no subprocess, no repository access.
public struct ConflictGuard: Sendable {
    /// Files larger than this are not scanned. Conflict markers live in text;
    /// reading a multi-gigabyte binary to look for them is not worth the stall.
    public static let maximumScanBytes = 8 * 1024 * 1024

    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
    }

    public static var defaultRoot: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenSVN", isDirectory: true)
            .appendingPathComponent("ConflictBackups", isDirectory: true)
    }

    // MARK: - Artifacts

    /// The working file plus every conflict copy svn may have left next to it:
    /// `.mine`, `.r<rev>`, `.working` (pre-1.8), `.orig`, `.rej`.
    ///
    /// The directory is listed because `.r<rev>` cannot be predicted; a resolve
    /// touches at most a handful of files, so the cost is irrelevant here.
    public static func conflictArtifacts(for path: URL) -> [URL] {
        let manager = FileManager.default
        let directory = path.deletingLastPathComponent()
        let name = path.lastPathComponent
        let prefix = name + "."

        var result: [URL] = []
        var seen: Set<String> = []
        if manager.fileExists(atPath: path.path), seen.insert(path.path).inserted {
            result.append(path)
        }

        let siblings = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for sibling in siblings.sorted() where sibling.hasPrefix(prefix) {
            let suffix = String(sibling.dropFirst(prefix.count))
            guard isConflictSuffix(suffix) else { continue }
            let candidate = directory.appendingPathComponent(sibling)
            guard seen.insert(candidate.path).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    static func isConflictSuffix(_ suffix: String) -> Bool {
        switch suffix {
        case "mine", "working", "orig", "rej":
            return true
        default:
            // `.r1`, `.r1234`, ...
            guard suffix.hasPrefix("r") else { return false }
            return !suffix.dropFirst().isEmpty && suffix.dropFirst().allSatisfy(\.isNumber)
        }
    }

    // MARK: - Backup

    /// Copies the conflict artifacts of `paths` into the backup root.
    ///
    /// Returns `nil` when there is nothing to copy (e.g. the file was already
    /// resolved). Throws `SVN-0303` on any failure: a resolve without a working
    /// backup is exactly the situation this guard exists to prevent, so the
    /// caller must abort instead of continuing.
    @discardableResult
    public func backup(paths: [URL], reason: String, now: Date = Date()) throws -> ConflictBackup? {
        var sources: [URL] = []
        var seen: Set<String> = []
        for path in paths {
            for artifact in Self.conflictArtifacts(for: path) where seen.insert(artifact.path).inserted {
                sources.append(artifact)
            }
        }
        guard !sources.isEmpty else { return nil }

        let directory = directoryFor(paths: paths, reason: reason, now: now)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SVNError(
                code: .backupFailed,
                message: "无法创建冲突备份目录",
                diagnosticOutput: "\(directory.path): \(error.localizedDescription)"
            )
        }

        var entries: [ConflictBackup.Entry] = []
        for (index, source) in sources.enumerated() {
            let name = String(format: "%03d", index) + "-" + source.lastPathComponent
            let destination = directory.appendingPathComponent(name)
            do {
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.copyItem(at: source, to: destination)
            } catch {
                throw SVNError(
                    code: .backupFailed,
                    message: "备份冲突文件失败：\(source.lastPathComponent)",
                    diagnosticOutput: "\(source.path) → \(destination.path): \(error.localizedDescription)"
                )
            }
            let attributes = try? manager.attributesOfItem(atPath: destination.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            entries.append(
                ConflictBackup.Entry(
                    sourcePath: source.path,
                    backupPath: destination.path,
                    byteCount: byteCount
                )
            )
        }

        return ConflictBackup(
            directory: directory,
            createdAt: now,
            reason: reason,
            entries: entries
        )
    }

    // MARK: - Verification

    public func scan(paths: [URL]) -> [ConflictMarkerScan] {
        paths.map { scan(path: $0) }
    }

    public func scan(path: URL) -> ConflictMarkerScan {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: path.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return ConflictMarkerScan(path: path.path, result: .skipped(reason: "无法读取文件"))
        }
        guard size <= Self.maximumScanBytes else {
            return ConflictMarkerScan(
                path: path.path,
                result: .skipped(reason: "文件过大（\(size) 字节），未扫描冲突标记")
            )
        }
        guard let data = try? Data(contentsOf: path, options: .mappedIfSafe) else {
            return ConflictMarkerScan(path: path.path, result: .skipped(reason: "无法读取文件"))
        }
        if data.contains(0) {
            return ConflictMarkerScan(path: path.path, result: .skipped(reason: "二进制文件"))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return ConflictMarkerScan(path: path.path, result: .skipped(reason: "非 UTF-8 文本"))
        }

        var markers: [Int] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.hasPrefix("<<<<<<<") || line.hasPrefix(">>>>>>>") || line.hasPrefix("|||||||") {
                markers.append(offset + 1)
            }
        }
        // A lone `=======` is a legitimate reStructuredText underline, so only
        // the unambiguous markers count.
        return ConflictMarkerScan(
            path: path.path,
            result: markers.isEmpty ? .clean : .unresolved(markerLines: markers)
        )
    }

    // MARK: - Retention

    /// Keeps the newest `limit` backups per working copy.
    @discardableResult
    public func prune(keepingPerWorkingCopy limit: Int = 10) -> Int {
        guard limit >= 0 else { return 0 }
        let manager = FileManager.default
        guard let groups = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let rootPath = root.standardizedFileURL.path
        var removed = 0
        for group in groups {
            let isDirectory = (try? group.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let snapshots = (try? manager.contentsOfDirectory(
                at: group,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            guard snapshots.count > limit else { continue }
            for stale in snapshots.prefix(snapshots.count - limit) {
                // Never follow a path outside the backup root.
                guard stale.standardizedFileURL.path.hasPrefix(rootPath) else { continue }
                if (try? manager.removeItem(at: stale)) != nil {
                    removed += 1
                }
            }
        }
        return removed
    }

    // MARK: - Naming

    private func directoryFor(paths: [URL], reason: String, now: Date) -> URL {
        let anchor = paths.compactMap { WorkingCopyLocator.root(for: $0) }.first
            ?? paths.first?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let slug = Self.slug(anchor.lastPathComponent)
        let digest = Self.digest(anchor.path)
        return root
            .appendingPathComponent("\(slug)-\(digest)", isDirectory: true)
            .appendingPathComponent("\(Self.stamp(now))-\(Self.slug(reason))", isDirectory: true)
    }

    static func slug(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("-")
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let clipped = String(trimmed.prefix(40))
        return clipped.isEmpty ? "wc" : clipped
    }

    /// FNV-1a. `hashValue` is seeded per process and would make backup folder
    /// names change on every launch, defeating retention.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "%08llx", hash & 0xffff_ffff)
    }

    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}
