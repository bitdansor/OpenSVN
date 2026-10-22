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
        credential: SVNCredential? = nil,
        progress: SVNProgressHandler? = nil
    ) async throws -> LogPage {
        let isURL = target.contains("://")
        let path = isURL ? target : URL(fileURLWithPath: target).standardizedFileURL.path
        var args = ["log", "--xml", "-v", "-l", String(max(1, limit))]
        if let startRevision, let endRevision {
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
            hasMore: entries.count >= limit
        )
    }

    /// Diff of local modifications inside a working copy.
    public func diffWorkingCopy(
        at target: URL,
        contextLines: Int = 3,
        maxBytes: Int = 2_000_000
    ) async throws -> DiffResult {
        let args = [
            "diff", "--internal-diff",
            "-x", "-U\(max(0, contextLines))",
            target.path
        ]
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
            text: prefix + "\n\n… 差异过大，已截断显示（共 \(bytes) 字节）。",
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
            case .infinity: return "完整检出（含子目录）"
            case .immediates: return "仅直接子项"
            case .files: return "仅文件"
            case .empty: return "仅目录本身"
            }
        }
    }

    public func checkout(
        url: String,
        to destination: URL,
        revision: Int64? = nil,
        depth: CheckoutDepth = .infinity,
        credential: SVNCredential? = nil,
        progress: SVNProgressHandler? = nil
    ) async throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SVNError(code: .invalidInvocation, message: "目标已存在且不是目录：\(destination.path)")
            }
            let contents = try fileManager.contentsOfDirectory(atPath: destination.path)
            guard contents.isEmpty else {
                throw SVNError(code: .invalidInvocation, message: "目标目录非空，无法检出：\(destination.path)")
            }
        }

        var arguments = ["checkout", url, destination.path, "--depth", depth.rawValue]
        if let revision {
            arguments += ["-r", String(revision)]
        }
        let checkoutArguments = arguments

        let key = destination.standardizedFileURL.path
        let ticket = await beginJournal(
            .checkout,
            workingCopy: destination,
            summary: "检出到 \(destination.lastPathComponent)"
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

    public func update(
        at target: URL,
        revision: Int64? = nil,
        credential: SVNCredential? = nil,
        progress: SVNProgressHandler? = nil
    ) async throws -> UpdateSummary {
        let key = WorkingCopyLocator.serializationKey(for: target)
        let ticket = await beginJournal(
            .update,
            workingCopy: URL(fileURLWithPath: key),
            summary: "更新 \(target.lastPathComponent)"
        )
        do {
            let summary = try await gate.withLock(key) {
                var args = ["update", "--accept", "postpone"]
                if let revision {
                    args += ["-r", String(revision)]
                }
                args.append(target.standardizedFileURL.path)

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
            summary: "添加 \(paths.count) 个路径"
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
        let targetList = paths.map(\.lastPathComponent).joined(separator: "、")
        return OperationPreview(
            summary: "删除「\(targetList)」并纳入版本控制",
            detail: discarded.isEmpty
                ? "这些文件会从磁盘和下次提交中移除。"
                : "以下 \(discarded.count) 项本地内容会一并丢失：\n" + discarded.prefix(20).joined(separator: "\n"),
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
            summary: "删除 \(paths.count) 个路径"
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
            summary: "还原 \(paths.count) 个路径的本地修改",
            detail: discarded.isEmpty
                ? "所选路径没有可还原的本地修改。"
                : "以下本地修改会被丢弃，且无法恢复：\n" + discarded.prefix(20).joined(separator: "\n"),
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
            summary: "还原 \(paths.count) 个路径"
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

    public func commit(
        _ paths: [URL],
        message: String,
        credential: SVNCredential? = nil,
        progress: SVNProgressHandler? = nil
    ) async throws -> CommitSummary {
        guard !paths.isEmpty else {
            throw SVNError(code: .invalidInvocation, message: "没有选择要提交的路径")
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SVNError(code: .invalidInvocation, message: "提交说明不能为空")
        }

        let key = WorkingCopyLocator.serializationKey(for: paths[0])
        let ticket = await beginJournal(
            .commit,
            workingCopy: URL(fileURLWithPath: key),
            summary: "提交 \(paths.count) 个路径"
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
                            message: "存在未解决的冲突：\(conflicted.path)",
                            diagnosticOutput: "请先解决冲突并标记 resolve 后再提交。"
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
            throw SVNError(code: .invalidInvocation, message: "没有选择要锁定的路径")
        }
        guard !steal || confirmed else {
            throw SVNError(
                code: .confirmationRequired,
                message: "「强制锁定」会抢占他人持有的锁",
                diagnosticOutput: "持有者将无法提交该路径，直到他注意到锁已易主。"
            )
        }

        let key = WorkingCopyLocator.serializationKey(for: paths[0])
        let ticket = await beginJournal(
            .lock,
            workingCopy: URL(fileURLWithPath: key),
            summary: "锁定 \(paths.count) 个路径"
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
            throw SVNError(code: .invalidInvocation, message: "没有选择要解锁的路径")
        }
        guard !breakLock || confirmed else {
            throw SVNError(
                code: .confirmationRequired,
                message: "「强制解除」会移除他人持有的锁",
                diagnosticOutput: "对方可能正在编辑该文件；解除后两人的提交都可能互相覆盖。"
            )
        }

        let key = WorkingCopyLocator.serializationKey(for: paths[0])
        let ticket = await beginJournal(
            .unlock,
            workingCopy: URL(fileURLWithPath: key),
            summary: "解锁 \(paths.count) 个路径"
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
            summary: "清理 \(target.lastPathComponent)"
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
                message: "「\(strategy.title)」会覆盖本地或服务器端内容",
                diagnosticOutput: strategy.consequence
            )
        }

        let key = WorkingCopyLocator.serializationKey(for: paths[0])
        let ticket = await beginJournal(
            .resolve,
            workingCopy: URL(fileURLWithPath: key),
            summary: "解决 \(paths.count) 个冲突"
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
            summary: "设置属性 \(name)"
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
            summary: "删除属性 \(name)"
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
            throw SVNError(code: .invalidInvocation, message: "忽略规则不能为空")
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
                message: "无法写入临时文件来传递属性值：\(error.localizedDescription)"
            )
        }
        return url
    }

    // MARK: - Credentials

    public func storedCredential(for host: String) -> SVNCredential? {
        try? credentials.credential(for: CredentialScope(host: host))
    }

    public func forgetCredential(for host: String) {
        try? credentials.remove(for: CredentialScope(host: host))
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
                    message: scope.map { "需要登录 \($0.host)" } ?? "需要登录",
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
        var args = ["--non-interactive", "--no-auth-cache"] + arguments
        var stdin: Data?

        if let credential {
            guard installation.version >= Self.passwordStdinMinimumVersion else {
                throw SVNError(
                    code: .invalidInvocation,
                    message: "svn \(installation.version) 不支持从 stdin 读取密码，需要 1.10 或更高版本"
                )
            }
            args += ["--username", credential.username, "--password-from-stdin"]
            stdin = Data((credential.password + "\n").utf8)
        }

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
