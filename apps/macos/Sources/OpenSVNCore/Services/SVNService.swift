import Foundation

/// Everything the service needs to run. Immutable after creation; Settings
/// changes rebuild the service instead of mutating shared state.
public struct SVNServiceConfiguration: Sendable {
    public var installation: SVNInstallation
    public var credentialStore: any CredentialStoring
    public var environment: [String: String]
    public var timeout: TimeInterval
    /// Where conflict backups go. `nil` uses `ConflictGuard.defaultRoot`
    /// (`~/Library/Application Support/OpenSVN/ConflictBackups`).
    public var conflictBackupRoot: URL?
    /// Records write operations so an interrupted one can be found on the next
    /// launch. `nil` disables recording (tests, and headless use where there is
    /// no UI to act on a recovery prompt).
    public var journal: OperationJournal?

    public init(
        installation: SVNInstallation,
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 300,
        conflictBackupRoot: URL? = nil,
        journal: OperationJournal? = nil
    ) {
        self.installation = installation
        self.credentialStore = credentialStore
        self.environment = environment
        self.timeout = timeout
        self.conflictBackupRoot = conflictBackupRoot
        self.journal = journal
    }
}

/// The single entry point for all SVN operations.
///
/// Contract highlights (see `specifications/svn-operations.md`):
/// - writes are serialised per working copy;
/// - destructive operations take a `confirmed` flag that the service itself
///   enforces;
/// - credentials are resolved from the Keychain, sent via stdin, and only
///   persisted after a successful authenticated call;
/// - every method surfaces a classified `SVNError`.
public actor SVNService {
    /// `--password-from-stdin` first shipped in svn 1.10.
    public nonisolated static let passwordStdinMinimumVersion = SVNVersion(major: 1, minor: 10, patch: 0)

    /// `--store-pristine=no` (Pristines on Demand) first shipped in svn 1.15.
    ///
    /// It is not merely a flag: opting in switches the working copy to format 32,
    /// which svn 1.14 and older cannot read at all. Refusing below 1.15 keeps a
    /// working copy usable by every client that might touch it — the alternative
    /// is a silent "unable to open working copy" for a colleague on 1.14.
    public nonisolated static let pristineStoreMinimumVersion = SVNVersion(major: 1, minor: 15, patch: 0)

    public nonisolated let installation: SVNInstallation
    private let runner: SVNProcessRunner
    private let credentials: any CredentialStoring
    private let gate = WCWriteGate()
    private let defaultTimeout: TimeInterval
    private let conflictGuard: ConflictGuard
    private let journal: OperationJournal?

    public init(configuration: SVNServiceConfiguration) {
        self.installation = configuration.installation
        self.credentials = configuration.credentialStore
        self.defaultTimeout = configuration.timeout
        self.conflictGuard = ConflictGuard(root: configuration.conflictBackupRoot)
        self.journal = configuration.journal
        self.runner = SVNProcessRunner(
            executableURL: configuration.installation.executableURL,
            environment: configuration.environment,
            defaultTimeout: configuration.timeout
        )
    }

    // MARK: - Interruption journal

    /// Starts recording a write. Returns `nil` when journaling is off or the
    /// write to disk failed — neither may block the operation itself. A commit
    /// must not be refused because `~/Library` is read-only.
    private func beginJournal(
        _ kind: OperationJournal.Entry.Kind,
        workingCopy: URL,
        summary: String
    ) async -> UUID? {
        guard let journal else { return nil }
        return try? await journal.begin(kind, workingCopy: workingCopy, summary: summary)
    }

    /// Removes the entry on both paths. A failed operation is *not* an
    /// interrupted one: its outcome is known, so the record must go.
    private func finishJournal(_ ticket: UUID?) async {
        guard let journal, let ticket else { return }
        try? await journal.finish(ticket)
    }

    // MARK: - Reads

    public func status(
        at target: URL,
        includeIgnored: Bool = false,
        checkRepository: Bool = false,
        credential: SVNCredential? = nil
    ) async throws -> StatusSnapshot {
        var args = ["status", "--xml"]
        if includeIgnored { args.append("--no-ignore") }
        // `--show-updates` is the only way to see a lock someone else holds:
        // without it svn reports just the token this working copy has.
        if checkRepository { args.append("--show-updates") }
        args.append(target.path)
        let repositoryURL = checkRepository ? await repositoryURL(for: target.path) : nil
        let result = try await invoke(
            args,
            workingDirectory: nil,
            credential: credential,
            repositoryURL: repositoryURL
        )
        return try SVNXMLParser.parseStatus(Data(result.standardOutput.utf8))
    }

    /// What an `update` would bring in, without changing anything.
    ///
    /// Same command as `locks(at:)` — `status --show-updates` — but a different
    /// reading of it. Keeping them as two entry points is deliberate: one is a
    /// question about ownership, the other about content, and merging them would
    /// force the lock refresh to parse changes it never shows.
    public func remotePreview(
        at target: URL,
        credential: SVNCredential? = nil
    ) async throws -> RemotePreview {
        let snapshot = try await status(at: target, checkRepository: true, credential: credential)
        return RemotePreview.make(from: snapshot)
    }

    /// `target` accepts either a filesystem path or a repository URL.
    public func info(at target: String) async throws -> InfoReport {
        let isURL = target.contains("://")
        let path = isURL ? target : URL(fileURLWithPath: target).standardizedFileURL.path
        let result = try await invoke(
            ["info", "--xml", path],
            workingDirectory: nil,
            credential: nil,
            repositoryURL: isURL ? target : nil
        )
        return try SVNXMLParser.parseInfo(Data(result.standardOutput.utf8))
    }

    public func log(
        at target: String,
        limit: Int = 50,
        from startRevision: Int64? = nil,
        to endRevision: Int64? = nil,
        newerThanOrEqual: Int64? = nil,
        search: String? = nil,
        credential: SVNCredential? = nil,
        progress: SVNProgressHandler? = nil
    ) async throws -> LogPage {
        let isURL = target.contains("://")
        let path = isURL ? target : URL(fileURLWithPath: target).standardizedFileURL.path
        var args = ["log", "--xml", "-v", "-l", String(max(1, limit))]
        let trimmedSearch = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedSearch.isEmpty {
            // `-l` and `--search` do not compose the way it looks: with
            // `--search`, svn applies the limit to the messages *scanned*, not
            // the ones printed. Asking for 50 matches would scan 50 revisions
            // and usually return nothing. The scan is unbounded instead, which
            // is why the caller runs it as a task it can cancel.
            args = ["log", "--xml", "-v", "--search", trimmedSearch]
        }
        if let newerThanOrEqual {
            // Deliberately inclusive of `newerThanOrEqual` itself. The cached
            // revision comes back as the last row and is dropped by the merge's
            // deduplication — which is also the cheapest proof that the cache and
            // the server are talking about the same revision, instead of trusting
            // that they are.
            args += ["-r", "HEAD:\(newerThanOrEqual)"]
        } else if let startRevision, let endRevision {
            args += ["-r", "\(startRevision):\(endRevision)"]
        } else if let startRevision {
            args += ["-r", "\(startRevision):1"]
        } else if let endRevision {
            args += ["-r", "\(endRevision):1"]
        }
        args.append(path)

        let repositoryURL = isURL ? target : await repositoryURL(for: path)
        let result = try await invoke(
            args,
            workingDirectory: nil,
            credential: credential,
            repositoryURL: repositoryURL,
            progress: progress
        )
        let entries = try SVNXMLParser.parseLog(Data(result.standardOutput.utf8))
        return LogPage(
            entries: entries,
            target: target,
            limit: limit,
            // A search is a scan of everything; there is no next page.
            hasMore: trimmedSearch.isEmpty && entries.count >= limit
        )
    }

    /// Annotates every line of a file.
    ///
    /// On a working-copy path this annotates the file **on disk**, reporting
    /// locally modified lines with no revision at all (the CLI prints `-`). That
    /// is the behaviour that makes it useful before committing: uncommitted work
    /// shows up as uncommitted instead of being attributed to whoever last
    /// touched the surrounding lines.
    public func blame(
        at target: URL,
        revision: Int64? = nil,
        credential: SVNCredential? = nil
    ) async throws -> BlameResult {
        let path = target.standardizedFileURL.path
        var args = ["blame", "--xml"]
        if let revision { args += ["-r", String(revision)] }
        args += ["--", path]

        let result = try await invoke(
            args,
            workingDirectory: nil,
            credential: credential,
            repositoryURL: await repositoryURL(for: path)
        )
        return try SVNXMLParser.parseBlame(Data(result.standardOutput.utf8))
    }

    /// Diff of local modifications inside a working copy.
    public func diffWorkingCopy(
        at target: URL,
        contextLines: Int = 3,
        maxBytes: Int = 2_000_000,
        externalDiffCommand: String? = nil
    ) async throws -> DiffResult {
        var args = ["diff"]
        if let command = externalDiffCommand?.trimmingCharacters(in: .whitespaces), !command.isEmpty {
            // `--diff-cmd` replaces the differ entirely, so `--internal-diff` and
            // `-x -U<n>` must not be sent with it: svn would pass the context
            // option to a tool that does not understand it.
            //
            // A GUI tool is expected to be wrapped in a script that returns
            // immediately; svn waits for the child to exit, and a tool that
            // blocks until the window closes freezes this operation with it.
            args += ["--diff-cmd", command]
        } else {
            args += ["--internal-diff", "-x", "-U\(max(0, contextLines))"]
        }
        args.append(target.path)
        let result = try await invoke(args, workingDirectory: nil, credential: nil, repositoryURL: nil)
        return Self.makeDiffResult(result.standardOutput, maxBytes: maxBytes)
    }

    /// Diff introduced by one revision, resolved against the working copy.
    public func diff(
        at target: URL,
        revision: Int64,
        credential: SVNCredential? = nil,
        contextLines: Int = 3,
        maxBytes: Int = 2_000_000
    ) async throws -> DiffResult {
        let args = [
            "diff", "-c", String(revision), "--internal-diff",
            "-x", "-U\(max(0, contextLines))",
            target.path
        ]
        let repositoryURL = await repositoryURL(for: target.path)
        let result = try await invoke(
            args,
            workingDirectory: nil,
            credential: credential,
            repositoryURL: repositoryURL
        )
        return Self.makeDiffResult(result.standardOutput, maxBytes: maxBytes)
    }

    private static func makeDiffResult(_ text: String, maxBytes: Int) -> DiffResult {
        let bytes = text.utf8.count
        guard bytes > maxBytes else {
            return DiffResult(text: text, isTruncated: false, byteCount: bytes)
        }
        let prefix = String(decoding: Data(text.utf8.prefix(maxBytes)), as: UTF8.self)
        return DiffResult(
            text: prefix + L.f("\n\n… 差异过大，已截断显示（共 %@ 字节）。", String(describing: bytes)),
            isTruncated: true,
            byteCount: bytes
        )
    }

    // MARK: - Working copy creation and update

    public enum CheckoutDepth: String, Sendable, CaseIterable {
        case infinity
        case immediates
        case files
        case empty

        public var displayName: String {
            switch self {
            case .infinity: return L.t("完整检出（含子目录）")
            case .immediates: return L.t("仅直接子项")
            case .files: return L.t("仅文件")
            case .empty: return L.t("仅目录本身")
            }
        }
    }

    /// `storePristines: false` enables svn 1.15 "Pristines on Demand" by adding
    /// `--store-pristine=no` (singular — the plural is rejected by svn); the
    /// default keeps svn's stock behaviour.
    ///
    /// Opting out is refused below svn 1.15 rather than attempted: the flag does
    /// not exist there, and it would rewrite the working copy into a format that
    /// older clients cannot open.
    public func checkout(
        url: String,
        to destination: URL,
        revision: Int64? = nil,
        depth: CheckoutDepth = .infinity,
        storePristines: Bool = true,
        credential: SVNCredential? = nil,
        progress: SVNProgressHandler? = nil
    ) async throws {
        if !storePristines {
            guard installation.version >= Self.pristineStoreMinimumVersion else {
                throw SVNError(
                    code: .invalidInvocation,
                    message: L.f("svn %@ 不支持按需获取原始副本（Pristines on Demand），需要 1.15 或更高版本", String(describing: installation.version))
                )
            }
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SVNError(code: .invalidInvocation, message: L.f("目标已存在且不是目录：%@", String(describing: destination.path)))
            }
            let contents = try fileManager.contentsOfDirectory(atPath: destination.path)
            guard contents.isEmpty else {
                throw SVNError(code: .invalidInvocation, message: L.f("目标目录非空，无法检出：%@", String(describing: destination.path)))
            }
        }

        let checkoutArguments = CheckoutArguments.make(
            url: url,
            destination: destination,
            revision: revision,
            depth: depth.rawValue,
            storePristines: storePristines
        )

        let key = destination.standardizedFileURL.path
        let ticket = await beginJournal(
            .checkout,
            workingCopy: destination,
            summary: L.f("检出到 %@", String(describing: destination.lastPathComponent))
        )
        do {
            try await gate.withLock(key) {
                _ = try await self.invoke(
                    checkoutArguments,
                    workingDirectory: nil,
                    credential: credential,
                    repositoryURL: url,
                    progress: progress
                )
            }
            await finishJournal(ticket)
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    /// `svn update`, optionally changing how much of the subtree is present.
    ///
    /// - Parameter setDepth: moves a sparse path to another depth. It is kept
    ///   apart from `revision` on purpose: svn applies both in one pass, and a
    ///   path that does not exist at the given revision is then *deleted* rather
    ///   than merely left alone (measured: `svn update -r 1 --set-depth
    ///   immediates dir` removed `dir`, which had been added in r2). Changing
    ///   depth is a question about what to keep, not about which revision, so
    ///   the combination is refused instead of quietly having side effects.
    public func update(
        at target: URL,
        revision: Int64? = nil,
        setDepth: WorkingCopyDepth? = nil,
        credential: SVNCredential? = nil,
        progress: SVNProgressHandler? = nil
    ) async throws -> UpdateSummary {
        if setDepth != nil, revision != nil {
            throw SVNError(
                code: .invalidInvocation,
                message: L.t("改深度和指定修订不能在同一次更新里做。svn 会把两者一起应用，若该路径在目标修订中不存在，它会被直接删掉。")
            )
        }
        if setDepth == .exclude {
            try await requireNoStrandedFiles(at: target)
        }

        let key = WorkingCopyLocator.serializationKey(for: target)
        let ticket = await beginJournal(
            .update,
            workingCopy: URL(fileURLWithPath: key),
            summary: setDepth.map { L.f("改深度到 %@：%@", String(describing: $0.displayName), String(describing: target.lastPathComponent)) }
                ?? L.f("更新 %@", String(describing: target.lastPathComponent))
        )
        do {
            let summary = try await gate.withLock(key) {
                let args = UpdateArguments.make(target: target, revision: revision, setDepth: setDepth)

                let repositoryURL = await self.repositoryURL(for: target.path)
                let result = try await self.invoke(
                    args,
                    workingDirectory: nil,
                    credential: credential,
                    repositoryURL: repositoryURL,
                    progress: progress
                )

                let parsed = SVNOutputParser.parseUpdate(result.standardOutput)
                var summary = UpdateSummary(
                    target: target.path,
                    toRevision: SVNOutputParser.parseUpdatedRevision(result.standardOutput),
                    updatedPaths: parsed.updated,
                    conflictedPaths: parsed.conflicted,
                    removedPaths: parsed.deleted,
                    rawOutput: LogRedactor.redact(result.standardOutput)
                )
                // Reading the revision from XML is more reliable than the text line.
                if let report = try? await self.info(at: target.path) {
                    summary.toRevision = report.primary?.revision
                }
                return summary
            }
            await finishJournal(ticket)
            return summary
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    /// Current depth of a working-copy path, from `svn info`.
    ///
    /// Read-only and local: `svn info` on a path inside a working copy does not
    /// contact the repository, so this is safe to call when a sheet opens.
    public func workingCopyDepth(at target: URL) async throws -> WorkingCopyDepth? {
        let report = try await info(at: target.path)
        return WorkingCopyDepth.parse(report.primary?.depth)
    }

    /// Refuses to exclude a directory that still holds anything svn cannot remove.
    ///
    /// Measured with svn 1.15.0: `svn update --set-depth exclude dir` where `dir`
    /// contains an unversioned file does not fail. It un-version-controls the
    /// subtree, leaves the files on disk, sometimes leaves the working copy
    /// locked (`L` in `svn status`), and exits **0**. The next svn command then
    /// fails with `E155037: Previous operation has not finished`. A pre-check is
    /// the only place to stop this, because afterwards the versioning is gone.
    private func requireNoStrandedFiles(at target: URL) async throws {
        let report = try? await info(at: target.path)
        // A file is either removed whole or refused by svn when modified, so the
        // half-removed state only applies to directories.
        guard report?.primary?.kind == .dir else { return }

        // `--no-ignore` matters: an ignored file blocks removal just the same,
        // and svn reports it as `I` rather than `?`.
        let snapshot = try await status(at: target, includeIgnored: true)
        let stranded = snapshot.entries.filter {
            $0.item == .unversioned || $0.item == .ignored
        }
        guard stranded.isEmpty else {
            let names = stranded.prefix(5).map(\.fileName).joined(separator: L.t("、"))
            let more = stranded.count > 5 ? L.f(" 等 %@ 项", String(describing: stranded.count)) : ""
            throw SVNError(
                code: .confirmationRequired,
                message: L.f("这个目录里还有未纳入版本控制的文件（%@%@），不能整体排除。", String(describing: names), String(describing: more))
                    + L.t("svn 会把这些文件留在磁盘上、同时丢掉目录的版本控制信息，工作副本还可能被锁住。")
                    + L.t("请先移走或删除它们，再改深度。"),
                diagnosticOutput: stranded.map(\.path).joined(separator: "\n")
            )
        }
    }


    // MARK: - Staging changes

    public func add(
        _ paths: [URL],
        force: Bool = false,
        includeIgnored: Bool = true
    ) async throws {
        guard let first = paths.first else { return }
        let key = WorkingCopyLocator.serializationKey(for: first)
        let ticket = await beginJournal(
            .add,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.n("添加 %d 个路径", paths.count)
        )
        do {
            try await gate.withLock(key) {
                var args = ["add"]
                if force { args.append("--force") }
                if includeIgnored { args.append("--no-ignore") }
                args += paths.map(\.standardizedFileURL.path)
                _ = try await self.invoke(args, workingDirectory: nil, credential: nil, repositoryURL: nil)
            }
            await finishJournal(ticket)
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    /// Description of what `delete` would destroy. Never mutates anything.
    public func previewDelete(_ paths: [URL]) async throws -> OperationPreview {
        var discarded: [String] = []
        for path in paths {
            guard let snapshot = try? await status(at: path) else { continue }
            for entry in snapshot.entries where entry.item == .modified
                || entry.item == .added
                || entry.item == .unversioned
                || entry.item == .replaced
                || entry.properties == .modified {
                discarded.append(entry.path)
            }
        }
        let targetList = paths.map(\.lastPathComponent).joined(separator: L.t("、"))
        return OperationPreview(
            summary: L.f("删除「%@」并纳入版本控制", String(describing: targetList)),
            detail: discarded.isEmpty
                ? L.t("这些文件会从磁盘和下次提交中移除。")
                : L.n("以下 %d 项本地内容会一并丢失：\n", discarded.count) + discarded.prefix(20).joined(separator: "\n"),
            risk: discarded.isEmpty ? .medium : .high,
            affectedPaths: paths.map(\.path),
            discardedPaths: discarded
        )
    }

    public func delete(_ paths: [URL], confirmed: Bool, force: Bool = false) async throws {
        guard !paths.isEmpty else { return }
        guard confirmed else {
            let preview = try await previewDelete(paths)
            throw SVNError(
                code: .confirmationRequired,
                message: preview.summary,
                diagnosticOutput: preview.detail
            )
        }
        let key = WorkingCopyLocator.serializationKey(for: paths[0])
        let ticket = await beginJournal(
            .delete,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.n("删除 %d 个路径", paths.count)
        )
        do {
            try await gate.withLock(key) {
                var args = ["delete"]
                if force { args.append("--force") }
                args += paths.map(\.standardizedFileURL.path)
                _ = try await self.invoke(args, workingDirectory: nil, credential: nil, repositoryURL: nil)
            }
            await finishJournal(ticket)
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    /// Description of what `revert` would discard. Never mutates anything.
    public func previewRevert(_ paths: [URL]) async throws -> OperationPreview {
        var discarded: [String] = []
        for path in paths {
            guard let snapshot = try? await status(at: path) else { continue }
            for entry in snapshot.entries
            where entry.item == .modified || entry.item == .added
                || entry.item == .deleted || entry.item == .replaced
                || entry.properties == .modified {
                discarded.append(entry.path)
            }
        }
        return OperationPreview(
            summary: L.n("还原 %d 个路径的本地修改", paths.count),
            detail: discarded.isEmpty
                ? L.t("所选路径没有可还原的本地修改。")
                : L.t("以下本地修改会被丢弃，且无法恢复：\n") + discarded.prefix(20).joined(separator: "\n"),
            risk: discarded.isEmpty ? .low : .high,
            affectedPaths: paths.map(\.path),
            discardedPaths: discarded
        )
    }

    public func revert(_ paths: [URL], recursive: Bool = true, confirmed: Bool) async throws {
        guard !paths.isEmpty else { return }
        guard confirmed else {
            let preview = try await previewRevert(paths)
            throw SVNError(
                code: .confirmationRequired,
                message: preview.summary,
                diagnosticOutput: preview.detail
            )
        }
        let key = WorkingCopyLocator.serializationKey(for: paths[0])
        let ticket = await beginJournal(
            .revert,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.n("还原 %d 个路径", paths.count)
        )
        do {
            try await gate.withLock(key) {
                var args = ["revert", "--depth", recursive ? "infinity" : "empty"]
                args += paths.map(\.standardizedFileURL.path)
                _ = try await self.invoke(args, workingDirectory: nil, credential: nil, repositoryURL: nil)
            }
            await finishJournal(ticket)
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    // MARK: - Commit

    /// Commits the given paths in **one** `svn commit`, i.e. scoped to a single
    /// repository. There is deliberately no "group by repository URL/UUID and
    /// fire one commit per group" helper here — see
    /// `specifications/svn-operations.md` §5.6 for the written conclusion.
    ///
    /// The short version: `svn:externals` mounts another working copy (possibly
    /// another repository). svn refuses to commit changes *inside* an external
    /// as part of the parent's commit; `StatusSnapshot.committable` already
    /// excludes those paths (§1.14). Auto-grouping by UUID and replaying commits
    /// would either silently commit someone else's repository or hide that a
    /// path belongs to an external. The caller must commit each external from
    /// its own working copy, explicitly.
    public func commit(
        _ paths: [URL],
        message: String,
        credential: SVNCredential? = nil,
        progress: SVNProgressHandler? = nil
    ) async throws -> CommitSummary {
        guard !paths.isEmpty else {
            throw SVNError(code: .invalidInvocation, message: L.t("没有选择要提交的路径"))
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SVNError(code: .invalidInvocation, message: L.t("提交说明不能为空"))
        }

        let key = WorkingCopyLocator.serializationKey(for: paths[0])
        let ticket = await beginJournal(
            .commit,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.n("提交 %d 个路径", paths.count)
        )
        do {
            let summary = try await gate.withLock(key) {
                // Re-check the working copy before committing: a conflict discovered
                // after the dialog opened must abort the commit, not be smuggled in.
                for path in paths {
                    let snapshot = try await self.status(at: path)
                    if let conflicted = snapshot.conflicted.first {
                        throw SVNError(
                            code: .conflictRemains,
                            message: L.f("存在未解决的冲突：%@", String(describing: conflicted.path)),
                            diagnosticOutput: L.t("请先解决冲突并标记 resolve 后再提交。")
                        )
                    }
                }

                let repositoryURL = await self.repositoryURL(for: paths[0].path)
                var args = ["commit", "-m", trimmed, "--encoding", "UTF-8"]
                args += paths.map(\.standardizedFileURL.path)
                let result = try await self.invoke(
                    args,
                    workingDirectory: nil,
                    credential: credential,
                    repositoryURL: repositoryURL,
                    progress: progress
                )
                let parsed = SVNOutputParser.parseCommit(result.standardOutput)
                return CommitSummary(
                    revision: parsed.revision,
                    committedPaths: parsed.sending + parsed.adding + parsed.deleting + parsed.replacing,
                    rawOutput: LogRedactor.redact(result.standardOutput)
                )
            }
            await finishJournal(ticket)
            return summary
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    // MARK: - Locks

    /// Takes a repository lock on every path (`svn lock`).
    ///
    /// A plain lock is reversible and touches nothing but the lock table, so it
    /// needs no confirmation. `steal` is the exception: it takes the lock away
    /// from whoever holds it and blocks *their* commit until they notice, which
    /// is why the service — not just the dialog — requires `confirmed`.
    public func lock(
        _ paths: [URL],
        comment: String? = nil,
        steal: Bool = false,
        confirmed: Bool = false,
        credential: SVNCredential? = nil
    ) async throws -> LockOutcome {
        guard !paths.isEmpty else {
            throw SVNError(code: .invalidInvocation, message: L.t("没有选择要锁定的路径"))
        }
        guard !steal || confirmed else {
            throw SVNError(
                code: .confirmationRequired,
                message: L.t("「强制锁定」会抢占他人持有的锁"),
                diagnosticOutput: L.t("持有者将无法提交该路径，直到他注意到锁已易主。")
            )
        }

        let key = WorkingCopyLocator.serializationKey(for: paths[0])
        let ticket = await beginJournal(
            .lock,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.n("锁定 %d 个路径", paths.count)
        )
        do {
            let outcome = try await gate.withLock(key) {
                var args = ["lock"]
                let trimmed = (comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { args += ["-m", trimmed] }
                if steal { args.append("--force") }
                args += paths.map(\.standardizedFileURL.path)

                let repositoryURL = await self.repositoryURL(for: paths[0].path)
                let result = try await self.invoke(
                    args,
                    workingDirectory: nil,
                    credential: credential,
                    repositoryURL: repositoryURL
                )
                let reported = LockOutputParser.lockedPaths(in: result.standardOutput)
                return LockOutcome(
                    // svn prints the paths it locked; fall back to the request when
                    // the wording changes, because a successful exit code is the
                    // contract and the message is a courtesy.
                    lockedPaths: reported.isEmpty ? paths.map(\.standardizedFileURL.path) : reported,
                    owner: LockOutputParser.owner(in: result.standardOutput),
                    rawOutput: LogRedactor.redact(result.standardOutput)
                )
            }
            await finishJournal(ticket)
            return outcome
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    /// Releases the lock on every path (`svn unlock`).
    ///
    /// `breakLock` maps to `--force`: it releases a lock held by someone else.
    /// Same reasoning as `lock(steal:)` — it needs `confirmed` at the service
    /// level, not only in the UI.
    public func unlock(
        _ paths: [URL],
        breakLock: Bool = false,
        confirmed: Bool = false,
        credential: SVNCredential? = nil
    ) async throws -> UnlockOutcome {
        guard !paths.isEmpty else {
            throw SVNError(code: .invalidInvocation, message: L.t("没有选择要解锁的路径"))
        }
        guard !breakLock || confirmed else {
            throw SVNError(
                code: .confirmationRequired,
                message: L.t("「强制解除」会移除他人持有的锁"),
                diagnosticOutput: L.t("对方可能正在编辑该文件；解除后两人的提交都可能互相覆盖。")
            )
        }

        let key = WorkingCopyLocator.serializationKey(for: paths[0])
        let ticket = await beginJournal(
            .unlock,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.n("解锁 %d 个路径", paths.count)
        )
        do {
            let outcome = try await gate.withLock(key) {
                var args = ["unlock"]
                if breakLock { args.append("--force") }
                args += paths.map(\.standardizedFileURL.path)

                let repositoryURL = await self.repositoryURL(for: paths[0].path)
                let result = try await self.invoke(
                    args,
                    workingDirectory: nil,
                    credential: credential,
                    repositoryURL: repositoryURL
                )
                let reported = LockOutputParser.unlockedPaths(in: result.standardOutput)
                return UnlockOutcome(
                    unlockedPaths: reported.isEmpty ? paths.map(\.standardizedFileURL.path) : reported,
                    rawOutput: LogRedactor.redact(result.standardOutput)
                )
            }
            await finishJournal(ticket)
            return outcome
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    /// Repository-side locks for a working copy, including other users' locks.
    ///
    /// Deliberately a separate call: it needs the network, and folding it into
    /// every `refresh()` would make a local status read wait on a server that may
    /// be unreachable.
    public func locks(at target: URL, credential: SVNCredential? = nil) async throws -> LockSnapshot {
        let snapshot = try await status(at: target, checkRepository: true, credential: credential)
        return LockSnapshot.from(status: snapshot)
    }

    // MARK: - Recovery

    public func cleanup(at target: URL) async throws {
        let key = WorkingCopyLocator.serializationKey(for: target)
        let ticket = await beginJournal(
            .cleanup,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.f("清理 %@", String(describing: target.lastPathComponent))
        )
        do {
            try await gate.withLock(key) {
                _ = try await self.invoke(
                    ["cleanup", target.standardizedFileURL.path],
                    workingDirectory: nil,
                    credential: nil,
                    repositoryURL: nil
                )
            }
            await finishJournal(ticket)
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    /// Marks conflicts resolved with `svn resolve --accept=<strategy>`.
    ///
    /// Two things happen around the svn call, and both matter for safety:
    /// 1. the conflict artifacts are copied aside **before** anything is
    ///    overwritten — `--accept` is irreversible and svn keeps no local copy;
    /// 2. the file is scanned afterwards, because `--accept=working` only clears
    ///    the conflict state and happily leaves `<<<<<<<` markers in place.
    ///
    /// The backup runs inside the working-copy lock: a concurrent write between
    /// the copy and the resolve would make the backup describe a file state that
    /// never existed.
    ///
    /// - Parameter backup: pass `false` only when the caller already made its
    ///   own copy. A failed backup aborts the resolve (`SVN-0303`).
    @discardableResult
    public func resolve(
        _ paths: [URL],
        strategy: ResolveStrategy,
        confirmed: Bool,
        backup: Bool = true
    ) async throws -> ResolveOutcome {
        guard !paths.isEmpty else { return ResolveOutcome() }
        guard !strategy.isDestructive || confirmed else {
            throw SVNError(
                code: .confirmationRequired,
                message: L.f("「%@」会覆盖本地或服务器端内容", String(describing: strategy.title)),
                diagnosticOutput: strategy.consequence
            )
        }

        let key = WorkingCopyLocator.serializationKey(for: paths[0])
        let ticket = await beginJournal(
            .resolve,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.n("解决 %d 个冲突", paths.count)
        )
        do {
            let outcome = try await gate.withLock(key) {
                let record = backup
                    ? try self.conflictGuard.backup(paths: paths, reason: "resolve-\(strategy.rawValue)")
                    : nil
                var args = ["resolve", "--accept=\(strategy.rawValue)"]
                args += paths.map(\.standardizedFileURL.path)
                _ = try await self.invoke(args, workingDirectory: nil, credential: nil, repositoryURL: nil)
                return ResolveOutcome(
                    resolvedPaths: paths.map(\.standardizedFileURL.path),
                    backup: record,
                    scans: self.conflictGuard.scan(paths: paths)
                )
            }
            await finishJournal(ticket)

            // Retention runs outside the lock: deleting old backups must not hold up
            // the next write, and failing to prune is not worth failing the resolve.
            conflictGuard.prune()
            return outcome
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    // MARK: - Properties

    /// Every property on `target`, or on it and its children when `recursive`.
    ///
    /// Read-only: no gate, no journal. `proplist --verbose` is what carries the
    /// values; `propget` takes a single property name and answers a different
    /// question.
    public func properties(at target: URL, recursive: Bool = false) async throws -> [PropertyTarget] {
        var args = ["proplist", "--xml", "--verbose"]
        if recursive { args.append("--recursive") }
        args.append(target.standardizedFileURL.path)
        let result = try await invoke(args, workingDirectory: nil, credential: nil, repositoryURL: nil)
        return try SVNXMLParser.parseProperties(Data(result.standardOutput.utf8))
    }

    /// The value of one property, or `nil` when it is not set.
    public func propertyValue(of name: String, at target: URL) async throws -> String? {
        try await properties(at: target).first?.value(of: name)
    }

    /// Sets `name` to `value` on every path, creating the property if absent.
    ///
    /// Deliberately not behind a `confirmed` flag. Unlike deleting files or an
    /// overwriting resolve, this is a local and revertible change: `svn revert`
    /// restores the previous value, and nothing reaches the repository until a
    /// commit. It still holds the write lock, because two `propset` runs on one
    /// working copy race on the same `.svn/wc.db`.
    public func setProperty(name: String, value: String, on targets: [URL]) async throws {
        guard !targets.isEmpty else { return }
        try SVNPropertyName.validate(name)
        try await writeProperty(
            ["propset", name],
            value: value,
            on: targets,
            summary: L.f("设置属性 %@", String(describing: name))
        )
    }

    /// Removes `name` from every path that has it, and reports how many did.
    ///
    /// `svn propdel` fails on a path that does not have the property, which
    /// would make "delete this from the selection" fail whenever part of the
    /// selection never had it. The existence check turns that into a no-op for
    /// the paths that do not.
    @discardableResult
    public func deleteProperty(name: String, on targets: [URL]) async throws -> Int {
        guard !targets.isEmpty else { return 0 }
        try SVNPropertyName.validate(name)
        var holders: [URL] = []
        for target in targets {
            let target = target.standardizedFileURL
            do {
                if try await propertyValue(of: name, at: target) != nil {
                    holders.append(target)
                }
            } catch {
                // A path that cannot be read (deleted on disk, outside the
                // working copy) simply has nothing to delete.
                continue
            }
        }
        guard !holders.isEmpty else { return 0 }
        try await writeProperty(
            ["propdel", name],
            value: nil,
            on: holders,
            summary: L.f("删除属性 %@", String(describing: name))
        )
        return holders.count
    }

    /// Appends `pattern` to the directory's `svn:ignore`, if not already there.
    ///
    /// - Returns: whether a write happened. A no-op returns `false` instead of
    ///   running `propset` with an identical value, which would still mark the
    ///   directory as property-modified and end up in the next commit.
    @discardableResult
    public func addIgnorePattern(_ pattern: String, in directory: URL) async throws -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SVNError(code: .invalidInvocation, message: L.t("忽略规则不能为空"))
        }
        let directory = directory.standardizedFileURL
        let existing = try await propertyValue(of: "svn:ignore", at: directory)
        if IgnoreList.entries(existing).contains(trimmed) { return false }
        let updated = (IgnoreList.entries(existing) + [trimmed]).joined(separator: "\n")
        try await setProperty(name: "svn:ignore", value: updated, on: [directory])
        return true
    }

    /// Ignores each path by name, in its own parent directory.
    ///
    /// Grouping by directory matters: a single `propset` per directory is one
    /// `.svn/wc.db` write instead of one per file, and it computes the merged
    /// list from the value that was actually there.
    public func ignore(_ paths: [URL]) async throws -> IgnoreOutcome {
        var outcome = IgnoreOutcome()
        guard !paths.isEmpty else { return outcome }

        let groups = Dictionary(grouping: paths) { $0.deletingLastPathComponent().standardizedFileURL }
        for directory in groups.keys.sorted(by: { $0.path < $1.path }) {
            let files = (groups[directory] ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var value = try await propertyValue(of: "svn:ignore", at: directory)
            var addedHere: [String] = []

            for file in files {
                let name = file.lastPathComponent
                if let updated = IgnoreList.adding(name, to: value) {
                    value = updated
                    addedHere.append(name)
                } else {
                    outcome.already.append(name)
                }
            }

            guard !addedHere.isEmpty, let value else { continue }
            try await setProperty(name: "svn:ignore", value: value, on: [directory])
            outcome.added.append(contentsOf: addedHere)
        }
        return outcome
    }

    /// Shared tail of `propset` / `propdel`.
    ///
    /// The value travels through a temp file rather than argv on purpose: a
    /// value beginning with `-` would be read as an option, and multi-line
    /// values (`svn:ignore`) are ordinary. `--` then separates the operands from
    /// the options, so a path that looks like a flag is still a path.
    private func writeProperty(
        _ arguments: [String],
        value: String?,
        on targets: [URL],
        summary: String
    ) async throws {
        let key = WorkingCopyLocator.serializationKey(for: targets[0])
        let ticket = await beginJournal(
            .property,
            workingCopy: URL(fileURLWithPath: key),
            summary: summary
        )
        do {
            try await gate.withLock(key) {
                var valueFile: URL?
                defer {
                    if let valueFile { try? FileManager.default.removeItem(at: valueFile) }
                }
                var args = arguments
                if let value {
                    let temporary = try Self.writeTemporaryValue(value)
                    valueFile = temporary
                    args += ["-F", temporary.path]
                }
                args.append("--")
                args += targets.map(\.standardizedFileURL.path)
                _ = try await self.invoke(args, workingDirectory: nil, credential: nil, repositoryURL: nil)
            }
            await finishJournal(ticket)
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    /// Writes a property value where `svn` can read it back byte for byte.
    /// The file name is random and says nothing about the contents.
    private nonisolated static func writeTemporaryValue(_ value: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensvn-property-\(UUID().uuidString)")
        do {
            try value.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw SVNError(
                code: .permissionDenied,
                message: L.f("无法写入临时文件来传递属性值：%@", String(describing: error.localizedDescription))
            )
        }
        return url
    }

    // MARK: - Repository (URL) operations
    //
    // Everything here works on a URL and never touches a working copy. svn itself
    // draws the same line: `svn mkdir URL` commits immediately, while `svn mkdir
    // path` stages a change. The two are different operations with different
    // failure modes, and mixing them behind one method would hide which one the
    // user just did.

    /// Lists one directory of the repository.
    public func list(
        at url: String,
        revision: Int64? = nil,
        credential: SVNCredential? = nil
    ) async throws -> RepositoryListing {
        var args = ["list", "--xml"]
        if let revision { args += ["-r", String(revision)] }
        args += ["--", url]
        let result = try await invoke(
            args,
            workingDirectory: nil,
            credential: credential,
            repositoryURL: url
        )
        return try SVNXMLParser.parseList(Data(result.standardOutput.utf8))
    }

    /// `svn mkdir URL` — one commit, created server-side.
    public func makeDirectory(
        at url: String,
        message: String,
        parents: Bool = false,
        credential: SVNCredential? = nil
    ) async throws -> RemoteCommit {
        try Self.requireMessage(message)
        var args = ["mkdir"]
        if parents { args.append("--parents") }
        args += ["-m", message, "--", url]
        let result = try await invoke(
            args,
            workingDirectory: nil,
            credential: credential,
            repositoryURL: url
        )
        return RemoteCommit(
            revision: RemoteCommit.parseRevision(result.standardOutput),
            summary: L.f("已创建 %@", String(describing: Self.leafName(of: url)))
        )
    }

    /// `svn copy URL URL` — the primitive behind tagging and branching.
    ///
    /// Copying a directory is the operation that creates a tag or a branch; there
    /// is no separate "tag" command, and inventing one in the UI would be a
    /// promise svn cannot keep for history.
    public func copy(
        from source: String,
        to destination: String,
        message: String,
        parents: Bool = false,
        credential: SVNCredential? = nil
    ) async throws -> RemoteCommit {
        try Self.requireMessage(message)
        var args = ["copy"]
        // Tagging usually targets `tags/v1.0` when `tags` does not exist yet;
        // without `--parents` that is a failure the user has to fix by hand.
        if parents { args.append("--parents") }
        args += ["-m", message, "--", source, destination]
        let result = try await invoke(
            args,
            workingDirectory: nil,
            credential: credential,
            repositoryURL: destination
        )
        return RemoteCommit(
            revision: RemoteCommit.parseRevision(result.standardOutput),
            summary: L.f("已复制到 %@", String(describing: Self.leafName(of: destination)))
        )
    }

    /// `svn move URL URL`.
    ///
    /// The server-side counterpart of `svn mv` in a working copy: it renames in
    /// the repository immediately, including in every checkout that updates next.
    public func moveRemote(
        from source: String,
        to destination: String,
        message: String,
        credential: SVNCredential? = nil
    ) async throws -> RemoteCommit {
        try Self.requireMessage(message)
        let result = try await invoke(
            ["move", "-m", message, "--", source, destination],
            workingDirectory: nil,
            credential: credential,
            repositoryURL: destination
        )
        return RemoteCommit(
            revision: RemoteCommit.parseRevision(result.standardOutput),
            summary: L.f("已移动到 %@", String(describing: Self.leafName(of: destination)))
        )
    }

    /// `svn delete URL` — immediate and irreversible from the caller's side.
    ///
    /// Behind `confirmed` for the same reason as the local delete (R3): the path
    /// is gone from HEAD the moment it returns, and every checkout finds out on
    /// its next update. svn keeps it in history, so it is *recoverable* — by
    /// someone who knows the revision and the command, which is not the person in
    /// front of this dialog.
    public func deleteRemote(
        at url: String,
        message: String,
        confirmed: Bool,
        credential: SVNCredential? = nil
    ) async throws -> RemoteCommit {
        guard confirmed else {
            throw SVNError(
                code: .confirmationRequired,
                message: L.f("删除仓库路径需要确认：%@", String(describing: url))
            )
        }
        try Self.requireMessage(message)
        let result = try await invoke(
            ["delete", "-m", message, "--", url],
            workingDirectory: nil,
            credential: credential,
            repositoryURL: url
        )
        return RemoteCommit(
            revision: RemoteCommit.parseRevision(result.standardOutput),
            summary: L.f("已删除 %@", String(describing: Self.leafName(of: url)))
        )
    }

    /// Properties of a repository path, read recursively.
    ///
    /// **Read-only, and it has to be.** svn 1.14 refuses `svn propset` against a
    /// URL with `E200009: Targets must be working copy paths` — there is no remote
    /// property editing. Changing a property therefore requires a checkout, which
    /// is a different and much larger action than this screen can imply.
    public func remoteProperties(
        at url: String,
        credential: SVNCredential? = nil
    ) async throws -> [PropertyTarget] {
        let result = try await invoke(
            ["proplist", "--xml", "--recursive", "--verbose", "--", url],
            workingDirectory: nil,
            credential: credential,
            repositoryURL: url
        )
        return try SVNXMLParser.parseProperties(Data(result.standardOutput.utf8))
    }

    /// `svn export` — a clean tree with no `.svn` directory, at any revision.
    public func export(
        from url: String,
        to destination: URL,
        revision: Int64? = nil,
        credential: SVNCredential? = nil
    ) async throws {
        var args = ["export"]
        if let revision { args += ["-r", String(revision)] }
        args += ["--", url, destination.standardizedFileURL.path]
        _ = try await invoke(
            args,
            workingDirectory: nil,
            credential: credential,
            repositoryURL: url
        )
    }

    /// `svn import` — puts a local directory into the repository in one commit.
    ///
    /// The counterpart of `export`: it uploads a directory that was never under
    /// version control. The target must not already exist, and the import is a
    /// single commit of the whole tree, which is why the message is required.
    public func importDirectory(
        from localPath: URL,
        to destinationURL: String,
        message: String,
        credential: SVNCredential? = nil
    ) async throws -> RemoteCommit {
        try Self.requireMessage(message)
        let result = try await invoke(
            ["import", "--", localPath.standardizedFileURL.path, destinationURL, "-m", message],
            workingDirectory: nil,
            credential: credential,
            repositoryURL: destinationURL
        )
        return RemoteCommit(
            revision: RemoteCommit.parseRevision(result.standardOutput),
            summary: L.f("已导入 %@", String(describing: Self.leafName(of: destinationURL)))
        )
    }

    /// `svn relocate` — repoints a working copy at the same repository over a
    /// different URL.
    ///
    /// The UUID check is svn's, not ours: relocating to a *different* repository
    /// fails, and that failure is the guarantee that this cannot silently mix two
    /// histories.
    public func relocate(
        workingCopy: URL,
        to newURL: String,
        credential: SVNCredential? = nil
    ) async throws {
        _ = try await invoke(
            ["relocate", "--", newURL],
            workingDirectory: workingCopy.standardizedFileURL,
            credential: credential,
            repositoryURL: newURL
        )
    }

    /// Puts paths into a changelist, or takes them out when `name` is `nil`.
    ///
    /// A changelist is local-only: it never reaches the server, and it is not a
    /// commit boundary unless the commit asks for it (`--changelist`). Modelling
    /// it as "a label in the working copy" is the whole truth.
    public func setChangelist(
        _ name: String?,
        on paths: [URL]
    ) async throws {
        guard !paths.isEmpty else { return }
        var args = ["changelist"]
        if let name, !name.isEmpty {
            args.append(name)
        } else {
            args.append("--remove")
        }
        args.append("--")
        args += paths.map { $0.standardizedFileURL.path }
        _ = try await invoke(args, workingDirectory: nil, credential: nil, repositoryURL: nil)
    }

    // MARK: - Merge, switch, and local repositories
    //
    // These are working-copy writes (or, for svnadmin, a local repository
    // creation). They reuse the existing journal kinds rather than adding new
    // ones, because `OperationJournal.Entry.Kind` is a closed enum with
    // exhaustive recovery advice that this file does not own. The mapping is a
    // semantic fit, not a shortcut:
    //   - merge / switch -> .update   ("working copy may be in an intermediate
    //     state; run cleanup") — exactly what an interrupted merge/switch leaves;
    //   - createLocalRepository -> .checkout ("may be only partly created; check
    //     the directory, then delete and redo") — exactly a half-built repo.
    // Every one of them goes through gate.withLock + beginJournal/finishJournal,
    // and the dangerous ones refuse unconfirmed calls at the service layer (R3).

    /// Read-only description of a merge; never runs svn and never mutates.
    public func previewMerge(_ request: MergeRequest) -> OperationPreview {
        MergePreview.make(from: request)
    }

    /// `svn merge` — branch merging with merge tracking (svn 1.14 semantics:
    /// the automatic/sync merge and the classic two-URL merge, plus
    /// `--record-only`). The result is a *local* change that still needs a commit.
    ///
    /// A merge can overwrite local work and leave conflicts behind, so the
    /// service — not only the UI — refuses any call without `confirmed`.
    public func merge(
        _ request: MergeRequest,
        confirmed: Bool,
        credential: SVNCredential? = nil,
        progress: SVNProgressHandler? = nil
    ) async throws -> MergeOutcome {
        guard confirmed else {
            let preview = MergePreview.make(from: request)
            throw SVNError(
                code: .confirmationRequired,
                message: preview.summary,
                diagnosticOutput: preview.detail
            )
        }
        try request.validate()

        let args = MergeArguments.make(request)
        let key = WorkingCopyLocator.serializationKey(for: request.target)
        let ticket = await beginJournal(
            .update,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.f("合并到 %@", String(describing: request.target.lastPathComponent))
        )
        do {
            let outcome = try await gate.withLock(key) {
                let result = try await self.invoke(
                    args,
                    workingDirectory: nil,
                    credential: credential,
                    repositoryURL: request.primarySourceURL,
                    progress: progress
                )
                return MergeOutcome.make(
                    target: request.target,
                    recordOnly: request.recordOnly,
                    from: result.standardOutput
                )
            }
            await finishJournal(ticket)
            return outcome
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    /// `svn mergeinfo --show-revs <merged|eligible>` — which revisions are (or
    /// are not) yet merged between a source and a working-copy target.
    /// Read-only: no gate, no journal, no confirmation.
    public func mergeInfo(
        _ kind: MergeInfoRevisions,
        source: String,
        target: URL? = nil,
        credential: SVNCredential? = nil
    ) async throws -> [Int64] {
        var args = ["mergeinfo", "--show-revs", kind.rawValue, source]
        if let target { args.append(target.standardizedFileURL.path) }
        let result = try await invoke(
            args,
            workingDirectory: nil,
            credential: credential,
            repositoryURL: source
        )
        return MergeInfoRevisions.parse(result.standardOutput)
    }

    /// `svn propget svn:mergeinfo` — the raw stored merge-tracking property.
    /// Accepts either a working-copy path or a repository URL. Read-only.
    public func mergeInfoProperty(
        at target: String,
        credential: SVNCredential? = nil
    ) async throws -> [MergeInfoLine] {
        let isURL = target.contains("://")
        let path = isURL ? target : URL(fileURLWithPath: target).standardizedFileURL.path
        let result = try await invoke(
            ["propget", "svn:mergeinfo", "--", path],
            workingDirectory: nil,
            credential: credential,
            repositoryURL: isURL ? target : nil
        )
        return MergeInfoProperty.parse(result.standardOutput)
    }

    /// Read-only description of a switch; never runs svn and never mutates.
    public func previewSwitch(_ request: SwitchRequest) -> OperationPreview {
        SwitchPreview.make(from: request)
    }

    /// `svn switch` — repoint a working copy at a different URL inside the *same*
    /// repository. svn enforces the UUID check, so this cannot silently join two
    /// histories. Local modifications may conflict, hence `confirmed` at the
    /// service layer.
    public func switchTo(
        _ request: SwitchRequest,
        confirmed: Bool,
        credential: SVNCredential? = nil,
        progress: SVNProgressHandler? = nil
    ) async throws -> SwitchOutcome {
        guard confirmed else {
            let preview = SwitchPreview.make(from: request)
            throw SVNError(
                code: .confirmationRequired,
                message: preview.summary,
                diagnosticOutput: preview.detail
            )
        }
        try request.validate()

        let args = SwitchArguments.make(request)
        let key = WorkingCopyLocator.serializationKey(for: request.target)
        let ticket = await beginJournal(
            .update,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.f("切换 %@ 到 %@", String(describing: request.target.lastPathComponent), String(describing: request.url))
        )
        do {
            let outcome = try await gate.withLock(key) {
                let result = try await self.invoke(
                    args,
                    workingDirectory: nil,
                    credential: credential,
                    repositoryURL: request.url,
                    progress: progress
                )
                return SwitchOutcome.make(
                    target: request.target,
                    url: request.url,
                    from: result.standardOutput
                )
            }
            await finishJournal(ticket)
            return outcome
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    /// `svn patch` — applies a unidiff to the working copy.
    ///
    /// A dry run is allowed without `confirmed` because it changes nothing; a
    /// real run needs it, like merge and switch, since the patch can schedule
    /// additions and deletions on the user's disk.
    ///
    /// The verdict comes from the parsed per-file status, never from the exit
    /// code: svn 1.15.0 returns 0 for a run where every hunk was rejected and for
    /// a run where every target was skipped as missing.
    public func applyPatch(
        _ request: PatchRequest,
        confirmed: Bool = false,
        progress: SVNProgressHandler? = nil
    ) async throws -> PatchOutcome {
        try request.validate()
        guard request.dryRun || confirmed else {
            throw SVNError(
                code: .confirmationRequired,
                message: L.t("应用补丁会修改工作副本里的文件（补丁也可能新增或删除文件）。请先预览，再确认应用。")
            )
        }

        let args = PatchArguments.make(request)
        let key = WorkingCopyLocator.serializationKey(for: request.target)
        let ticket = request.dryRun ? nil : await beginJournal(
            .patch,
            workingCopy: URL(fileURLWithPath: key),
            summary: L.f("应用补丁 %@", String(describing: request.patchFile.lastPathComponent))
        )
        do {
            let outcome = try await gate.withLock(key) {
                let result = try await self.invoke(
                    args,
                    workingDirectory: nil,
                    credential: nil,
                    repositoryURL: nil,
                    progress: progress
                )
                return SVNOutputParser.parsePatch(
                    result.standardOutput,
                    target: request.target.path,
                    isDryRun: request.dryRun
                )
            }
            await finishJournal(ticket)
            return outcome
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }


    /// `svnadmin create` — creates a brand-new local repository and returns its
    /// `file://` URL. Refuses to touch a non-empty destination, so it needs no
    /// `confirmed`. It is still serialised and journaled like every other write.
    public func createLocalRepository(at location: URL) async throws -> LocalRepository {
        let path = location.standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SVNError(code: .invalidInvocation, message: L.f("目标已存在且不是目录：%@", String(describing: path.path)))
            }
            let contents = try fileManager.contentsOfDirectory(atPath: path.path)
            guard contents.isEmpty else {
                throw SVNError(code: .invalidInvocation, message: L.f("目标目录非空，无法在此创建仓库：%@", String(describing: path.path)))
            }
        } else {
            // svnadmin creates only the final directory, not its parents.
            try fileManager.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let key = path.path
        let ticket = await beginJournal(
            .checkout,
            workingCopy: path,
            summary: L.f("创建本地仓库 %@", String(describing: path.lastPathComponent))
        )
        do {
            let repository = try await gate.withLock(key) {
                let result = try await self.runAdmin(LocalRepositoryArguments.create(path: path))
                return LocalRepository(
                    path: path,
                    url: LocalRepositoryArguments.fileURL(for: path),
                    rawOutput: LogRedactor.redact(result.standardOutput)
                )
            }
            await finishJournal(ticket)
            return repository
        } catch {
            await finishJournal(ticket)
            throw error
        }
    }

    private static func requireMessage(_ message: String) throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SVNError(
                code: .invalidInvocation,
                message: L.t("仓库操作需要提交说明：svn 会把它写进历史，不能留空")
            )
        }
    }

    private static func leafName(of url: String) -> String {
        let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? url : name
    }

    // MARK: - Credentials

    public func storedCredential(for host: String) -> SVNCredential? {
        try? credentials.credential(for: CredentialScope(host: host))
    }

    public func forgetCredential(for host: String) {
        try? credentials.remove(for: CredentialScope(host: host))
    }

    /// Same as the host version, but exact: a realm-specific entry is not the
    /// same item as a bare host entry, and deleting "the host" must not silently
    /// remove a credential for a different realm.
    public func forgetCredential(for scope: CredentialScope) {
        try? credentials.remove(for: scope)
    }

    /// Hosts and realms that have a stored password. Metadata only.
    public func credentialScopes() -> [CredentialScope] {
        (try? credentials.scopes()) ?? []
    }

    public func forgetAllCredentials() throws {
        try credentials.removeAll()
    }

    // MARK: - Execution

    /// Resolves credentials for `repositoryURL`, runs once, classifies failures,
    /// and persists the credential only after a successful authenticated call.
    private func invoke(
        _ arguments: [String],
        workingDirectory: URL?,
        credential: SVNCredential?,
        repositoryURL: String?,
        progress: SVNProgressHandler? = nil
    ) async throws -> SVNProcessResult {
        let scope = repositoryURL.flatMap { CredentialScope(repositoryURL: $0) }

        var effective = credential
        if effective == nil, let scope {
            effective = try? credentials.credential(for: scope)
        }

        let result = try await runOnce(
            arguments,
            workingDirectory: workingDirectory,
            credential: effective,
            progress: progress
        )

        if let error = SVNErrorMapper.error(from: result) {
            if error.code.isAuthenticationRelated {
                if credential == nil, let scope {
                    // A stored password was rejected: drop it so we do not loop.
                    try? credentials.remove(for: scope)
                }
                throw SVNError(
                    code: .authenticationRequired,
                    message: scope.map { L.f("需要登录 %@", String(describing: $0.host)) } ?? L.t("需要登录"),
                    diagnosticOutput: error.diagnosticOutput,
                    svnCode: error.svnCode,
                    exitCode: result.exitCode
                )
            }
            throw error
        }

        if let effective, let scope {
            try? credentials.save(effective, for: scope)
        }
        return result
    }

    /// Runs `svnadmin`, which is a *different binary* from `svn` and does not
    /// accept the client's global `--non-interactive` / `--no-auth-cache`
    /// options that `runOnce` prepends. It still goes through the same
    /// `SVNProcessRunner` abstraction (never a raw `Process`), exactly like
    /// `DemoWorkspace`'s admin calls; credentials are never involved because
    /// `svnadmin` only works on the local filesystem.
    private func runAdmin(_ arguments: [String]) async throws -> SVNProcessResult {
        guard let adminURL = DemoWorkspace.adminTool(nextTo: installation.executableURL) else {
            throw SVNError(
                code: .svnNotFound,
                message: L.t("找不到 svnadmin：它应与 svn 位于同一目录")
            )
        }
        let adminRunner = SVNProcessRunner(executableURL: adminURL, defaultTimeout: defaultTimeout)
        let invocation = SVNInvocation(
            executableURL: adminURL,
            arguments: arguments,
            timeout: defaultTimeout
        )
        let result = try await adminRunner.run(invocation)
        guard result.isSuccess else {
            let text = result.standardError.isEmpty ? result.standardOutput : result.standardError
            throw SVNError(
                code: .commandFailed(exitCode: result.exitCode),
                message: L.t("svnadmin 执行失败"),
                diagnosticOutput: LogRedactor.redact(text)
            )
        }
        AppLog.shared.record(
            .debug,
            "svnadmin \(Self.describe(arguments)) → exit \(result.exitCode)",
            category: "svn"
        )
        return result
    }

    // MARK: - Conflict merge support

    /// The three versions `svn` left behind for a text conflict, or nil when the
    /// path is not in conflict. Read-only: no gate, no journal.
    public func conflictArtifacts(for url: URL) async throws -> ConflictArtifacts? {
        let result = try await runOnce(
            ["info", "--xml", url.path],
            workingDirectory: nil,
            credential: nil,
            progress: nil
        )
        return try ConflictArtifactParser.parse(infoXML: Data(result.standardOutput.utf8))
    }

    /// Takes the pre-resolve backup *without* resolving anything.
    ///
    /// The merge editor writes the merged file and then calls `resolve(.working)`,
    /// which backs up again on its own — but by then the working file already
    /// holds the merged text. The copy worth keeping is the original conflicted
    /// one, so the editor asks for it before writing.
    public func backupConflictArtifacts(for urls: [URL], reason: String) throws -> ConflictBackup? {
        try conflictGuard.backup(paths: urls, reason: reason)
    }

    private func runOnce(
        _ arguments: [String],
        workingDirectory: URL?,
        credential: SVNCredential?,
        progress: SVNProgressHandler?
    ) async throws -> SVNProcessResult {
        // All of these are svn *global* options. They must come before the
        // subcommand and, critically, before any `--` separator in `arguments`:
        // svn treats everything after `--` as a positional path, so appending
        // them at the end used to turn `--username` into a bogus target.
        var globalOptions = ["--non-interactive", "--no-auth-cache"]
        var stdin: Data?

        if let credential {
            guard installation.version >= Self.passwordStdinMinimumVersion else {
                throw SVNError(
                    code: .invalidInvocation,
                    message: L.f("svn %@ 不支持从 stdin 读取密码，需要 1.10 或更高版本", String(describing: installation.version))
                )
            }
            globalOptions += ["--username", credential.username, "--password-from-stdin"]
            stdin = Data((credential.password + "\n").utf8)
        }

        // A fresh store per invocation: one-shot certificate trust must not
        // outlive the single operation the user approved.
        globalOptions += SVNConnectionSettingsStore().resolveSVNTrustArguments(
            svnVersion: installation.version
        )

        let args = globalOptions + arguments

        let invocation = SVNInvocation(
            executableURL: installation.executableURL,
            arguments: args,
            workingDirectory: workingDirectory,
            standardInput: stdin,
            timeout: defaultTimeout
        )

        var lineHandler: (@Sendable (String) -> Void)?
        if let progress {
            lineHandler = { line in
                progress(.running(line))
            }
        }

        // The single place every command passes through, so the log answers
        // "what did the app actually run, and what came back" for all of them.
        let summary = Self.describe(arguments)
        let started = Date()
        do {
            let result = try await runner.run(invocation, onOutputLine: lineHandler)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            AppLog.shared.record(.debug, "svn \(summary) → exit \(result.exitCode)（\(elapsed) ms）", category: "svn")
            if result.exitCode != 0 {
                AppLog.shared.record(
                    .warning,
                    "svn \(summary) 退出码 \(result.exitCode)：\(Self.excerpt(result.standardError))",
                    category: "svn"
                )
            }
            return result
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let message = (error as? SVNError)?.message ?? error.localizedDescription
            AppLog.shared.record(
                .error,
                "svn \(summary) 抛出错误（\(elapsed) ms）：\(message)",
                category: "svn"
            )
            throw error
        }
    }

    /// A log-safe rendering of the command line.
    ///
    /// Commit messages are dropped on purpose: they are the user's content, not
    /// diagnostics, and a log that quotes them becomes a privacy problem the
    /// moment someone attaches it to a bug report. Passwords never reach argv
    /// in the first place (`--password-from-stdin`), but URLs may carry userinfo
    /// and still go through the redactor.
    private static func describe(_ arguments: [String]) -> String {
        var parts: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-m" || argument == "--message" || argument == "-F" || argument == "--file" {
                parts.append(argument)
                parts.append("<\(argument == "-F" || argument == "--file" ? "file" : "message")>")
                index += 2
                continue
            }
            parts.append(argument)
            index += 1
        }
        let redacted = LogRedactor.redact(parts.joined(separator: " "))
        return redacted.count > 300 ? String(redacted.prefix(300)) + "…" : redacted
    }

    private static func excerpt(_ text: String, limit: Int = 1200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    /// Applies the user's "concurrent write operations" setting.
    public func setMaxConcurrentWrites(_ value: Int) async {
        await gate.setMaxConcurrent(value)
    }

    /// Best-effort repository URL for a working-copy path, used to scope
    /// Keychain lookups. Reading `svn info` locally never touches the network.
    private func repositoryURL(for path: String) async -> String? {
        guard !path.contains("://") else { return path }
        guard let report = try? await info(at: path) else { return nil }
        return report.primary?.url
    }
}

extension SVNErrorCode {
    public var isAuthenticationRelated: Bool {
        switch self {
        case .authenticationRequired, .authorizationFailed:
            return true
        default:
            return false
        }
    }

    /// The server did not answer, as opposed to answering with a refusal.
    ///
    /// The distinction decides what the connection indicator claims: a bad
    /// password and an unreachable host need completely different actions, and
    /// showing "不可达" for the first would send the user to check a network
    /// that is working fine.
    public var isReachabilityRelated: Bool {
        switch self {
        case .networkFailure, .timeout, .hostKeyVerificationFailed:
            return true
        default:
            return false
        }
    }
}

/// Builds a service after resolving the `svn` executable.
public enum SVNServiceFactory {
    public struct Options: Sendable {
        public var explicitExecutablePath: String?
        public var bundledCandidates: [URL]
        public var credentialStore: any CredentialStoring
        public var environment: [String: String]
        public var timeout: TimeInterval
        public var journal: OperationJournal?

        public init(
            explicitExecutablePath: String? = nil,
            bundledCandidates: [URL] = [],
            credentialStore: any CredentialStoring = KeychainCredentialStore(),
            environment: [String: String] = ProcessInfo.processInfo.environment,
            timeout: TimeInterval = 300,
            journal: OperationJournal? = nil
        ) {
            self.explicitExecutablePath = explicitExecutablePath
            self.bundledCandidates = bundledCandidates
            self.credentialStore = credentialStore
            self.environment = environment
            self.timeout = timeout
            self.journal = journal
        }
    }

    public static func makeService(_ options: Options) async throws -> SVNService {
        let discovery = SVNDiscovery(
            explicitExecutablePath: options.explicitExecutablePath,
            bundledCandidates: options.bundledCandidates,
            environment: options.environment
        )
        let installation = try await discovery.resolve()
        return SVNService(
            configuration: SVNServiceConfiguration(
                installation: installation,
                credentialStore: options.credentialStore,
                environment: options.environment,
                timeout: options.timeout,
                journal: options.journal
            )
        )
    }

    /// Bundled-runtime locations inside an .app produced by packaging/macos.
    public static func bundledCandidateURLs(bundle: Bundle = .main) -> [URL] {
        bundledCandidateURLs(appBundleURL: bundle.bundleURL, resources: bundle.resourceURL)
    }

    /// Same list, for an arbitrary .app on disk.
    ///
    /// `--app`-style verification tools (opensvn-probe discover) drive this so a
    /// release check exercises the shipping path instead of re-deriving it. A
    /// second copy of these three paths would drift the moment one of them moves.
    public static func bundledCandidateURLs(appBundleURL: URL, resources: URL? = nil) -> [URL] {
        let resourcesURL = resources ?? appBundleURL.appendingPathComponent("Contents/Resources")
        return [
            resourcesURL.appendingPathComponent("svn/bin/svn"),
            resourcesURL.appendingPathComponent("svn/svn"),
            appBundleURL.appendingPathComponent("Contents/Frameworks/svn")
        ]
    }
}
