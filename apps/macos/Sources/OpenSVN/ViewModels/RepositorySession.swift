import Foundation
import Observation
import OpenSVNCore

/// All state for one working copy: its status, history, current diff, staging
/// selection, and any pending confirmation.
///
/// The session never talks to `svn` directly; it goes through `SVNService` so
/// serialization and credential handling stay in one place.
@MainActor
@Observable
final class RepositorySession: Identifiable {
    struct PresentedError: Identifiable {
        let id = UUID()
        let error: SVNError

        var title: String { error.message }
        var detail: String {
            [error.code.remediation, error.diagnosticOutput]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
    }

    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let isDestructive: Bool
        let action: @MainActor () async -> Void
    }

    /// Non-fatal outcome of a resolve: where the backup went, and whether the
    /// file still contains conflict markers. Shown as an alert, not an error.
    struct ResolveReport: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// Present when a backup was taken, so the alert can reveal it in Finder.
        let backupDirectory: URL?
    }

    nonisolated let bookmark: RepositoryBookmark
    private(set) var service: SVNService?
    private var taskCenter: TaskCenter?
    private let onCredentialRequired: (@MainActor (String) async -> SVNCredential?)?

    var credential: SVNCredential?
    var info: RepositoryInfo?
    var status: StatusSnapshot?
    var log: [LogEntry] = []
    var logHasMore = false
    var logPageSize = 50
    var isLoading = false
    var isLogLoading = false
    var lastRefreshedAt: Date?
    var diff: DiffResult?
    var diffTitle = ""
    var commitMessage = ""
    var selectedPaths: Set<String> = []
    var commitSelection: Set<String> = []
    var presentedError: PresentedError?
    var confirmation: Confirmation?
    var resolveReport: ResolveReport?
    /// Non-nil while the three-way merge editor is open.
    var mergeEditor: MergeEditorState?

    init(
        bookmark: RepositoryBookmark,
        service: SVNService?,
        taskCenter: TaskCenter?,
        onCredentialRequired: (@MainActor (String) async -> SVNCredential?)? = nil
    ) {
        self.bookmark = bookmark
        self.service = service
        self.taskCenter = taskCenter
        self.onCredentialRequired = onCredentialRequired
    }

    nonisolated var id: UUID { bookmark.id }
    var path: URL { bookmark.url }
    var displayName: String { bookmark.name }

    var repositoryHost: String? {
        if let host = info?.host, !host.isEmpty { return host }
        return URL(string: info?.url ?? "")?.host
    }

    var changedEntries: [StatusEntry] {
        (status?.entries ?? []).filter {
            $0.item.isCommittableChange || $0.properties == .modified
        }
    }

    var conflictedEntries: [StatusEntry] {
        status?.conflicted ?? []
    }

    func attach(service: SVNService?, taskCenter: TaskCenter?) {
        self.service = service
        self.taskCenter = taskCenter
    }

    func updateTimeout(_ timeout: TimeInterval) {
        // Timeout is baked into the service; a service rebuild happens in AppState.
        _ = timeout
    }

    func entryURL(_ entry: StatusEntry) -> URL {
        if entry.path.hasPrefix("/") {
            return URL(fileURLWithPath: entry.path)
        }
        return path.appendingPathComponent(entry.path)
    }

    func relativePath(_ rawPath: String) -> String {
        let root = path.standardizedFileURL.path
        var value = rawPath
        if value.hasPrefix(root) {
            value = String(value.dropFirst(root.count))
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Loading

    func refresh() async {
        guard let service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await service.status(at: path)
            status = snapshot
            info = (try? await service.info(at: path.path))?.primary ?? info
            lastRefreshedAt = Date()
            pruneSelections(using: snapshot)
        } catch {
            handle(error)
        }
    }

    private func pruneSelections(using snapshot: StatusSnapshot) {
        let valid = Set(snapshot.entries.map(\.id))
        selectedPaths.formIntersection(valid)
        let committable = Set(
            snapshot.entries
                .filter { ($0.item.isCommittableChange || $0.properties == .modified) && !$0.hasConflicts }
                .map(\.id)
        )
        if commitSelection.isEmpty || !commitSelection.isSubset(of: valid) {
            commitSelection = committable
        } else {
            commitSelection.formIntersection(committable)
        }
    }

    // MARK: - Operations

    func update() async {
        guard let service else { return }
        let target = path
        await perform("更新 \(displayName)") { credential, progress in
            try await service.update(at: target, credential: credential, progress: progress)
        }
        await loadLog(reset: true)
    }

    func cleanup() async {
        guard let service else { return }
        let target = path
        await perform("清理 \(displayName)") { _, _ in
            try await service.cleanup(at: target)
        }
    }

    func add(_ paths: [String]) async {
        guard let service, !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        await perform("添加到版本控制") { _, _ in
            try await service.add(urls)
        }
    }

    func requestDelete(_ paths: [String]) {
        guard let service, !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        Task {
            do {
                let preview = try await service.previewDelete(urls)
                confirmation = Confirmation(
                    title: preview.summary,
                    message: preview.detail,
                    confirmLabel: "删除",
                    isDestructive: true,
                    action: { [weak self] in
                        await self?.perform("删除 \(urls.count) 项") { _, _ in
                            try await service.delete(urls, confirmed: true)
                        }
                    }
                )
            } catch {
                handle(error)
            }
        }
    }

    func requestRevert(_ paths: [String]) {
        guard let service, !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        Task {
            do {
                let preview = try await service.previewRevert(urls)
                confirmation = Confirmation(
                    title: preview.summary,
                    message: preview.detail,
                    confirmLabel: "还原",
                    isDestructive: true,
                    action: { [weak self] in
                        await self?.perform("还原 \(urls.count) 项") { _, _ in
                            try await service.revert(urls, confirmed: true)
                        }
                    }
                )
            } catch {
                handle(error)
            }
        }
    }

    func confirmPending() {
        guard let confirmation else { return }
        self.confirmation = nil
        Task { await confirmation.action() }
    }

    func loadDiff(for entry: StatusEntry) async {
        guard let service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.diffWorkingCopy(at: entryURL(entry))
            diff = result
            diffTitle = relativePath(entry.path)
        } catch {
            handle(error)
        }
    }

    func loadDiffForRevision(_ revision: Int64, entry: LogEntry) async {
        guard let service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            diffTitle = "r\(revision) · \(entry.author ?? "unknown")"
            let target = path
            diff = try await withAuthRetry { credential in
                try await service.diff(at: target, revision: revision, credential: credential)
            }
        } catch {
            handle(error)
        }
    }

    func loadLog(reset: Bool = true) async {
        guard let service else { return }
        if isLogLoading { return }
        isLogLoading = true
        defer { isLogLoading = false }

        let from: Int64? = reset ? nil : log.last.map { $0.revision - 1 }
        if let from, from < 1 { logHasMore = false; return }
        let target = path.path

        do {
            let page = try await withAuthRetry { credential in
                try await service.log(
                    at: target,
                    limit: self.logPageSize,
                    from: from,
                    credential: credential
                )
            }
            if reset {
                log = page.entries
            } else {
                let existing = Set(log.map(\.revision))
                log.append(contentsOf: page.entries.filter { !existing.contains($0.revision) })
            }
            logHasMore = page.entries.count >= logPageSize
        } catch {
            handle(error)
        }
    }

    func commit() async {
        guard let service else { return }
        let paths = Array(commitSelection).sorted()
        guard !paths.isEmpty else {
            presentedError = PresentedError(error: SVNError(
                code: .invalidInvocation,
                message: "请先勾选要提交的文件"
            ))
            return
        }
        let message = commitMessage
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentedError = PresentedError(error: SVNError(
                code: .invalidInvocation,
                message: "提交说明不能为空"
            ))
            return
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        await perform("提交 \(urls.count) 个文件") { credential, progress in
            try await service.commit(urls, message: message, credential: credential, progress: progress)
        }
        commitMessage = ""
        await loadLog(reset: true)
    }

    func resolve(_ entry: StatusEntry, strategy: ResolveStrategy) {
        resolve([entry], strategy: strategy)
    }

    /// Resolves several conflicts with one strategy.
    ///
    /// Any batch (two or more files) asks for confirmation even with the
    /// non-destructive `working` strategy: a bulk `resolve --accept=working`
    /// marks *everything* resolved, including files the user never opened.
    func resolve(_ entries: [StatusEntry], strategy: ResolveStrategy) {
        guard let service, !entries.isEmpty else { return }
        let urls = entries.map(entryURL)
        let isBatch = urls.count > 1

        if strategy.isDestructive || isBatch {
            confirmation = Confirmation(
                title: isBatch
                    ? "解决 \(urls.count) 个冲突"
                    : "解决冲突：\(relativePath(entries[0].path))",
                message: confirmationMessage(for: entries, strategy: strategy, isBatch: isBatch),
                confirmLabel: "确认解决",
                isDestructive: strategy.isDestructive,
                action: { [weak self] in
                    await self?.performResolve(urls, strategy: strategy, service: service)
                }
            )
        } else {
            Task { await performResolve(urls, strategy: strategy, service: service) }
        }
    }

    /// Entry point for "resolve everything", used by the Changes toolbar.
    func resolveAllConflicts(strategy: ResolveStrategy) {
        resolve(conflictedEntries, strategy: strategy)
    }

    func dismissResolveReport() {
        resolveReport = nil
    }

    // MARK: - Three-way merge editor

    /// Opens the merge editor for a text conflict.
    ///
    /// The three versions come from `svn info --xml`, not from guessing file
    /// names: which `.r<N>` is the ancestor depends on the operation that
    /// produced the conflict.
    func beginMerge(_ entry: StatusEntry) {
        guard let service else { return }
        let url = entryURL(entry)
        Task {
            do {
                guard let artifacts = try await service.conflictArtifacts(for: url) else {
                    presentedError = PresentedError(error: SVNError(
                        code: .conflictRemains,
                        message: "该路径当前没有冲突副本，无法进行三方合并"
                    ))
                    return
                }
                guard artifacts.supportsMerge,
                      let baseURL = artifacts.base,
                      let mineURL = artifacts.mine,
                      let theirsURL = artifacts.theirs else {
                    presentedError = PresentedError(error: SVNError(
                        code: .conflictRemains,
                        message: artifacts.kind == "text"
                            ? "冲突副本不完整（可能是树冲突或已被清理），请改用「解决冲突」菜单"
                            : "只有文本冲突支持三方合并；这是\(artifacts.kind ?? "非文本")冲突"
                    ))
                    return
                }

                let base = try String(contentsOf: baseURL, encoding: .utf8)
                let mine = try String(contentsOf: mineURL, encoding: .utf8)
                let theirs = try String(contentsOf: theirsURL, encoding: .utf8)

                mergeEditor = MergeEditorState(
                    path: entry.path,
                    url: url,
                    artifacts: artifacts,
                    result: ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs),
                    mineText: mine,
                    theirsText: theirs
                )
            } catch {
                handle(error)
            }
        }
    }

    func cancelMerge() {
        mergeEditor = nil
    }

    /// Writes the merged result and marks the file resolved.
    ///
    /// Order matters. The backup is taken **before** the write, so it holds the
    /// original conflicted file rather than the merge output; without that, a
    /// wrong decision could only be undone by re-doing the update. The resolve
    /// then uses `--accept=working`, which means "the file on disk is the
    /// answer" — it does not overwrite what was just written.
    func applyMerge() {
        guard let service, let editor = mergeEditor, let taskCenter else { return }
        guard let text = editor.renderedText else { return }
        let url = editor.url
        let path = editor.path

        Task {
            do {
                let backup = try await service.backupConflictArtifacts(
                    for: [url],
                    reason: "merge-editor"
                )
                try text.write(to: url, atomically: true, encoding: .utf8)
                let outcome = try await taskCenter.run("写入合并结果") { _ in
                    try await service.resolve([url], strategy: .working, confirmed: true)
                }
                mergeEditor = nil
                await refresh()
                var report = makeReport(outcome, strategy: .working)
                if let backup {
                    report = ResolveReport(
                        title: report.title,
                        message: report.message + "\n\n合并前的内容已备份到：\n"
                            + (backup.directory.path as NSString).abbreviatingWithTildeInPath,
                        backupDirectory: backup.directory
                    )
                }
                resolveReport = report
                _ = path
            } catch {
                handle(error)
            }
        }
    }

    private func confirmationMessage(
        for entries: [StatusEntry],
        strategy: ResolveStrategy,
        isBatch: Bool
    ) -> String {
        var lines: [String] = [strategy.consequence]
        if isBatch {
            lines.append("")
            lines.append("将一次处理 \(entries.count) 个文件：")
            for entry in entries.prefix(8) {
                lines.append("· \(relativePath(entry.path))")
            }
            if entries.count > 8 {
                lines.append("… 其余 \(entries.count - 8) 个")
            }
        }
        lines.append("")
        lines.append("解决前会把冲突相关文件备份到应用支持目录，出问题可以从那里取回。")
        return lines.joined(separator: "\n")
    }

    private func performResolve(
        _ urls: [URL],
        strategy: ResolveStrategy,
        service: SVNService
    ) async {
        guard let taskCenter else { return }
        let title = urls.count == 1 ? "解决冲突" : "解决 \(urls.count) 个冲突"
        do {
            let outcome = try await taskCenter.run(title) { _ in
                try await service.resolve(urls, strategy: strategy, confirmed: true)
            }
            await refresh()
            resolveReport = makeReport(outcome, strategy: strategy)
        } catch {
            handle(error)
        }
    }

    private func makeReport(_ outcome: ResolveOutcome, strategy: ResolveStrategy) -> ResolveReport {
        var lines: [String] = []
        if let backup = outcome.backup {
            let path = (backup.directory.path as NSString).abbreviatingWithTildeInPath
            lines.append("已备份 \(backup.entries.count) 个冲突文件到：\n\(path)")
        } else {
            lines.append("没有需要备份的冲突副本（可能已被他人解决或文件已删除）。")
        }

        let residual = outcome.scans.filter(\.hasUnresolvedMarkers)
        guard !residual.isEmpty else {
            let skipped = outcome.scans.filter { scan in
                if case .skipped = scan.result { return true }
                return false
            }
            if !skipped.isEmpty {
                lines.append("\(skipped.count) 个文件无法扫描（二进制或超过 8 MB）。")
            }
            return ResolveReport(
                title: "已解决 \(outcome.resolvedPaths.count) 个冲突",
                message: lines.joined(separator: "\n\n"),
                backupDirectory: outcome.backup?.directory
            )
        }

        lines.append("以下文件仍含冲突标记（`<<<<<<<` / `>>>>>>>`），直接提交会把标记写进仓库：")
        for scan in residual {
            guard case .unresolved(let markers) = scan.result else { continue }
            let sample = markers.prefix(5).map(String.init).joined(separator: "、")
            let suffix = markers.count > 5 ? "…" : ""
            lines.append("· \(relativePath(scan.path))（第 \(sample)\(suffix) 行）")
        }
        lines.append("请手工编辑这些文件，或在「变更」页改用其它解决方式。")
        return ResolveReport(
            title: "已标记为已解决，但仍有 \(residual.count) 个文件含冲突标记",
            message: lines.joined(separator: "\n\n"),
            backupDirectory: outcome.backup?.directory
        )
    }

    // MARK: - Plumbing

    private func perform<T: Sendable>(
        _ title: String,
        _ operation: @escaping @Sendable (SVNCredential?, SVNProgressHandler) async throws -> T
    ) async {
        guard let taskCenter else { return }
        do {
            _ = try await withAuthRetry { credential in
                try await taskCenter.run(title) { progress in
                    try await operation(credential, progress)
                }
            }
            await refresh()
        } catch {
            handle(error)
        }
    }

    /// Runs the operation; on an authentication failure asks the UI for
    /// credentials once and retries exactly once.
    ///
    /// The closure is `@MainActor` and the result is required to be `Sendable`
    /// on purpose. Without both, Swift 6.1 rejects the call with
    /// "non-sendable result type 'T' cannot be sent from nonisolated context":
    /// a plain async closure parameter is treated as nonisolated there, so the
    /// result would cross an isolation boundary on the way back. Swift 6.2
    /// runs nonisolated async functions on the caller's actor by default
    /// (SE-0461) and no longer diagnoses it, which is why this compiled locally
    /// on 6.4 while CI on 6.1.2 failed.
    private func withAuthRetry<T: Sendable>(
        _ operation: @MainActor (SVNCredential?) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(credential)
        } catch let error as SVNError where error.code.isAuthenticationRelated {
            guard let host = repositoryHost,
                  let provider = onCredentialRequired,
                  let fresh = await provider(host) else {
                throw error
            }
            credential = fresh
            return try await operation(fresh)
        }
    }

    private func handle(_ error: any Error) {
        if let error = error as? SVNError, case .cancelled = error.code {
            return
        }
        if let error = error as? SVNError {
            presentedError = PresentedError(error: error)
        } else {
            presentedError = PresentedError(error: SVNError(code: .unknown, message: error.localizedDescription))
        }
    }
}
