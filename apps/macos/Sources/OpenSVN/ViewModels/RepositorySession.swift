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
        guard let service else { return }
        let url = entryURL(entry)
        let requiresConfirmation = strategy.isDestructive
        if requiresConfirmation {
            confirmation = Confirmation(
                title: "解决冲突：\(relativePath(entry.path))",
                message: strategy.consequence,
                confirmLabel: "确认解决",
                isDestructive: true,
                action: { [weak self] in
                    await self?.perform("解决冲突") { _, _ in
                        try await service.resolve([url], strategy: strategy, confirmed: true)
                    }
                }
            )
        } else {
            Task {
                await perform("解决冲突") { _, _ in
                    try await service.resolve([url], strategy: strategy, confirmed: false)
                }
            }
        }
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
    private func withAuthRetry<T>(_ operation: (SVNCredential?) async throws -> T) async throws -> T {
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
