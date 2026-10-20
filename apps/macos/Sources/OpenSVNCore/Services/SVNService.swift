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
        includeIgnored: Bool = false
    ) async throws -> StatusSnapshot {
        var args = ["status", "--xml"]
        if includeIgnored { args.append("--no-ignore") }
        args.append(target.path)
        let result = try await invoke(args, workingDirectory: nil, credential: nil, repositoryURL: nil)
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
    /// Two things happen around the svn call, both required by 执行计划 S5-3:
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
        let resources = bundle.resourceURL ?? bundle.bundleURL.appendingPathComponent("Contents/Resources")
        return [
            resources.appendingPathComponent("svn/bin/svn"),
            resources.appendingPathComponent("svn/svn"),
            bundle.bundleURL.appendingPathComponent("Contents/Frameworks/svn")
        ]
    }
}
