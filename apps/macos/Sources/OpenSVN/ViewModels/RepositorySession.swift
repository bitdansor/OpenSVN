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

    /// Properties of one path, plus whether they are still loading.
    ///
    /// A snapshot rather than a live query: `svn` is a process, and a view that
    /// re-reads properties on every redraw would spawn one per keystroke.
    struct PropertyEditorState: Identifiable {
        let id = UUID()
        let url: URL
        let displayPath: String
        var targets: [PropertyTarget] = []
        var isLoading = false
        var loadError: String?

        var properties: [SVNProperty] { targets.first?.properties ?? [] }
    }

    /// State of the "锁定" sheet: the paths, the comment, and whether this lock
    /// is meant to replace someone else's.
    struct LockEditorState: Identifiable {
        let id = UUID()
        let paths: [String]
        let displayPaths: [String]
        var comment = ""
        /// Pre-set when the refresh already knows the lock belongs to someone
        /// else; the user still has to confirm again in the dialog.
        var steal = false
        var foreignLockCount = 0
        var ownLockCount = 0

        var isBatch: Bool { paths.count > 1 }
    }

    /// What the update sheet is showing, and whether it is still being fetched.
    ///
    /// A sheet with a loading state rather than a modal spinner: `--show-updates`
    /// talks to the server, and an unresponsive window during a slow handshake is
    /// the worst possible moment to show one.
    struct UpdatePreviewState: Identifiable {
        let id = UUID()
        var isLoading = true
        var preview: RemotePreview?
        var failure: String?
        /// Local entries that are not committed yet — the other half of "will
        /// this update collide with my work?".
        var localChangeCount = 0

        var hasRemoteChanges: Bool { preview?.isEmpty == false }
    }

    /// One file's annotation, shown as a sheet.
    struct BlameState: Identifiable {
        let id = UUID()
        let path: String
        let displayPath: String
        var result: BlameResult?
        var isLoading = true
        var error: String?
    }

    /// Whether the repository behind this working copy answered the last time
    /// anything asked.
    ///
    /// Derived from facts, never guessed: it is set by an `info` that succeeded,
    /// an update preview that reached the server, or the failure of either. A
    /// working copy on `file://` is always reachable and never checked.
    enum ConnectionState: Sendable, Equatable {
        case unknown
        case reachable(Date)
        case needsAuthentication
        case unreachable(String)

        var isProblem: Bool {
            switch self {
            case .unreachable, .needsAuthentication: return true
            case .unknown, .reachable: return false
            }
        }

        /// A bad password is a different problem from a dead host, and the icon
        /// is the only thing distinguishing them in a 20 pt sidebar row.
        var isAuthenticationProblem: Bool {
            if case .needsAuthentication = self { return true }
            return false
        }

        var systemImage: String {
            switch self {
            case .unknown: return "questionmark.circle"
            case .reachable: return "circle.fill"
            case .needsAuthentication: return "person.badge.key"
            case .unreachable: return "bolt.horizontal.circle"
            }
        }

        var summary: String {
            switch self {
            case .unknown:
                return "尚未检查服务器连通性"
            case .reachable(let at):
                return "服务器可达（\(at.formatted(date: .omitted, time: .shortened))）"
            case .needsAuthentication:
                return "服务器需要认证，尚未保存可用的凭据"
            case .unreachable(let reason):
                return "服务器不可达：\(reason)"
            }
        }
    }

    nonisolated let bookmark: RepositoryBookmark
    private(set) var service: SVNService?
    private var taskCenter: TaskCenter?
    private let commitMessages: CommitMessageStore?
    private let logCache: LogCache
    private let onCredentialRequired: (@MainActor (String) async -> SVNCredential?)?

    var credential: SVNCredential?
    var info: RepositoryInfo?
    var status: StatusSnapshot?
    var log: [LogEntry] = []
    var logHasMore = false
    var logPageSize = 50
    /// History limited to one path; `nil` means the whole working copy.
    ///
    /// `svn log` follows copies by default, so a renamed file keeps its history
    /// from before the rename without a special flag.
    var logTarget: String?
    var logFilter = LogFilter()
    /// True when `log` holds a server-side search result rather than history.
    var logIsServerSearch = false
    var logServerSearchText = ""
    var isLogSearching = false
    /// Width of the history page's list pane, in points.
    ///
    /// Kept here rather than in the view because `HistoryView` is rebuilt every
    /// time the section switcher moves: a `@State` would hand back a reset split
    /// each time the user came back to look at history.
    var historyListWidth: CGFloat = 360
    var blameState: BlameState?
    var isLoading = false
    var isLogLoading = false
    var lastRefreshedAt: Date?
    var diff: DiffResult?
    var diffTitle = ""
    var commitMessage = ""
    /// Set after a successful commit so the panel can say "已提交为 r123".
    var lastCommit: CommitSummary?
    /// The file whose diff the commit panel is previewing.
    var commitPreviewPath: String?
    var commitPreviewDiff: DiffResult?
    var selectedPaths: Set<String> = []
    var commitSelection: Set<String> = []
    var presentedError: PresentedError?
    var confirmation: Confirmation?
    var resolveReport: ResolveReport?
    /// Non-nil while the three-way merge editor is open.
    var mergeEditor: MergeEditorState?
    /// Non-nil while the property sheet is open.
    var propertyEditor: PropertyEditorState?
    /// Repository-side locks, including other users'. Only refreshed on demand:
    /// it needs the network, and a local status read must not wait on a server.
    var lockSnapshot = LockSnapshot()
    var isLockLoading = false
    /// Non-nil while the "锁定" sheet is open.
    var lockEditor: LockEditorState?
    /// Non-nil while the update preview sheet is open.
    var updatePreview: UpdatePreviewState?
    /// Case-insensitive filter for the change list. Kept here rather than in the
    /// view so switching tabs and coming back does not lose what was typed.
    var filterText = ""
    /// Reachability of the repository behind this working copy.
    var connection: ConnectionState = .unknown

    var autoRefreshEnabled = true
    var previewBeforeUpdate = true
    /// `svn diff --diff-cmd` value; `nil` uses the built-in differ.
    var externalDiffCommand: String?
    /// True when the diff on screen was produced by an external tool.
    ///
    /// Such a tool usually prints nothing, so an empty pane would otherwise look
    /// like "this file has no changes" instead of "look at the other window".
    var lastDiffUsedExternalTool = false
    private var watcher: WorkingCopyWatcher?
    private var pendingWatchRefresh: Task<Void, Never>?

    init(
        bookmark: RepositoryBookmark,
        service: SVNService?,
        taskCenter: TaskCenter?,
        commitMessages: CommitMessageStore? = nil,
        logCache: LogCache = LogCache(),
        onCredentialRequired: (@MainActor (String) async -> SVNCredential?)? = nil
    ) {
        self.bookmark = bookmark
        self.service = service
        self.taskCenter = taskCenter
        self.commitMessages = commitMessages
        self.logCache = logCache
        self.onCredentialRequired = onCredentialRequired
    }

    nonisolated var id: UUID { bookmark.id }
    var path: URL { bookmark.url }
    var displayName: String { bookmark.name }

    var repositoryHost: String? {
        if let host = info?.host, !host.isEmpty { return host }
        return URL(string: info?.url ?? "")?.host
    }

    /// Entries that can be committed from this working copy.
    ///
    /// Everything under an `svn:externals` mount is excluded: svn reports those
    /// changes here but refuses to commit them, because they belong to another
    /// repository or path. Counting them made the sidebar promise work that the
    /// commit button could not deliver.
    var changedEntries: [StatusEntry] {
        status?.committable ?? []
    }

    /// `svn:externals` mounts inside this working copy.
    var externalEntries: [StatusEntry] {
        (status?.entries ?? []).filter { $0.item == .external }
    }

    /// Changes that live inside an external mount.
    var externalChangeEntries: [StatusEntry] {
        let roots = status?.externalRoots ?? []
        return (status?.entries ?? []).filter { $0.isInsideExternal(roots) }
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

    func refresh(quiet: Bool = false) async {
        guard let service else { return }
        if !quiet { isLoading = true }
        defer { if !quiet { isLoading = false } }
        do {
            let snapshot = try await service.status(at: path)
            status = snapshot
            info = (try? await service.info(at: path.path))?.primary ?? info
            lastRefreshedAt = Date()
            pruneSelections(using: snapshot)
        } catch {
            // A quiet refresh comes from the file watcher, which fires while
            // files are half-written and operations are in flight. Reporting an
            // alert for every one of those would turn ordinary editing into a
            // wall of dialogs; the next manual refresh will report it if it is
            // real.
            if quiet { return }
            handle(error)
        }
    }

    private func pruneSelections(using snapshot: StatusSnapshot) {
        let valid = Set(snapshot.entries.map(\.id))
        selectedPaths.formIntersection(valid)
        let committable = Set(snapshot.committable.map(\.id))
        if commitSelection.isEmpty || !commitSelection.isSubset(of: valid) {
            commitSelection = committable
        } else {
            commitSelection.formIntersection(committable)
        }
    }

    // MARK: - Operations

    /// The 更新 button. Reads the server side first when the setting is on.
    ///
    /// Updating blindly is the one operation here that can mix an unknown
    /// changeset into local edits, and `svn update` has no dry run. `status
    /// --show-updates` is the dry run: it names every incoming path and the
    /// revision it would land on, at the cost of one round trip.
    func requestUpdate() async {
        guard service != nil else { return }
        guard previewBeforeUpdate else {
            await update()
            return
        }
        updatePreview = UpdatePreviewState(localChangeCount: changedEntries.count)
        await loadUpdatePreview()
    }

    /// Fetches (or re-fetches) the preview for the open sheet.
    ///
    /// Keyed on the sheet's identity so a slow answer cannot land in a sheet the
    /// user already closed, or in a newer one opened for the same working copy.
    func loadUpdatePreview() async {
        guard let service, let state = updatePreview else { return }
        var loading = state
        loading.isLoading = true
        loading.failure = nil
        updatePreview = loading

        do {
            let preview = try await withAuthRetry { credential in
                try await service.remotePreview(at: self.path, credential: credential)
            }
            connection = .reachable(Date())
            guard var current = updatePreview, current.id == state.id else { return }
            current.preview = preview
            current.isLoading = false
            updatePreview = current
        } catch {
            let svnError = (error as? SVNError)
                ?? SVNError(code: .unknown, message: error.localizedDescription)
            // The preview is also the cheapest reachability check the app has,
            // so a failure here is what tells the sidebar the host is down.
            if svnError.code.isReachabilityRelated {
                connection = .unreachable(svnError.message)
            } else if svnError.code.isAuthenticationRelated {
                connection = .needsAuthentication
            }
            guard var current = updatePreview, current.id == state.id else { return }
            current.isLoading = false
            current.failure = svnError.message
            updatePreview = current
        }
    }

    func dismissUpdatePreview() {
        updatePreview = nil
    }

    func confirmUpdate() async {
        updatePreview = nil
        await update()
    }

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
                        guard let self else { return }
                        await self.perform("删除 \(urls.count) 项") { _, _ in
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
                        guard let self else { return }
                        await self.perform("还原 \(urls.count) 项") { _, _ in
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
            let external = externalDiffCommand
            let result = try await service.diffWorkingCopy(
                at: entryURL(entry),
                externalDiffCommand: external
            )
            diff = result
            diffTitle = relativePath(entry.path)
            lastDiffUsedExternalTool = external != nil
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

        logIsServerSearch = false
        logServerSearchText = ""

        let key = logCacheKey
        let target = logQueryTarget()

        if reset || log.isEmpty {
            if log.isEmpty {
                // Whatever was cached appears before the network is touched. On a
                // slow link this is the difference between "instant" and two
                // seconds of spinner for a page the user has already seen.
                let cached = await logCache.load(key: key)
                if !cached.entries.isEmpty {
                    log = cached.entries
                    logHasMore = true
                }
            }
            await fetchNewest(key: key, target: target, service: service)
        } else {
            await fetchOlder(key: key, target: target, service: service)
        }
    }

    /// Fetches the newest revision and everything after the newest cached one.
    ///
    /// The cached revision is requested again on purpose (`HEAD:<newest>` rather
    /// than `HEAD:<newest+1>`): it comes back as the last row and is removed by
    /// deduplication, which also proves the cache and the server agree instead of
    /// assuming it — and it keeps the range legal when nothing new was committed,
    /// where `HEAD:<newest+1>` would name a revision that does not exist.
    private func fetchNewest(key: LogCache.Key, target: String, service: SVNService) async {
        let newest = log.map(\.revision).max()
        do {
            let page = try await withAuthRetry { credential in
                try await service.log(
                    at: target,
                    limit: self.logPageSize,
                    newerThanOrEqual: newest,
                    credential: credential
                )
            }
            log = await logCache.merge(page.entries, key: key)
            logHasMore = (log.map(\.revision).min() ?? 1) > 1
        } catch {
            handle(error)
        }
    }

    private func fetchOlder(key: LogCache.Key, target: String, service: SVNService) async {
        guard let oldest = log.map(\.revision).min(), oldest > 1 else {
            logHasMore = false
            return
        }
        do {
            let page = try await withAuthRetry { credential in
                try await service.log(
                    at: target,
                    limit: self.logPageSize,
                    from: oldest - 1,
                    to: 1,
                    credential: credential
                )
            }
            log = await logCache.merge(page.entries, key: key)
            logHasMore = page.entries.count >= logPageSize
        } catch {
            handle(error)
        }
    }

    /// Runs a server-side `svn log --search`.
    ///
    /// Two measured facts shape this. First, `--search` returns **nothing** when
    /// the target is a working-copy path; the same pattern against the repository
    /// URL finds the revisions, so the URL is used here. Second, the result is a
    /// scan of all history rather than a page, so `hasMore` goes false and the
    /// entries are not written to the cache — they are a filtered view, not the
    /// history itself.
    func searchLog(_ text: String) async {
        guard let service else { return }
        let pattern = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        guard let url = logQueryURL() else {
            handle(SVNError(
                code: .notAWorkingCopy,
                message: "无法确定仓库地址，历史搜索需要先读取工作副本信息"
            ))
            return
        }

        isLogSearching = true
        defer { isLogSearching = false }
        do {
            let page = try await withAuthRetry { credential in
                try await service.log(at: url, search: pattern, credential: credential)
            }
            log = page.entries
            logHasMore = false
            logIsServerSearch = true
            logServerSearchText = pattern
        } catch {
            handle(error)
        }
    }

    func clearServerSearch() async {
        logIsServerSearch = false
        logServerSearchText = ""
        await loadLog(reset: true)
    }

    /// Limits history to one path. `svn log` follows copies by default, so a
    /// renamed file keeps the revisions from before the rename.
    func showHistory(for entry: StatusEntry) async {
        logTarget = relativePath(entry.path)
        log = []
        logFilter = LogFilter()
        await loadLog(reset: true)
    }

    func clearLogTarget() async {
        guard logTarget != nil else { return }
        logTarget = nil
        log = []
        logFilter = LogFilter()
        await loadLog(reset: true)
    }

    // MARK: - Blame

    func openBlame(for entry: StatusEntry) {
        blameState = BlameState(
            path: entryURL(entry).path,
            displayPath: relativePath(entry.path)
        )
        Task { await loadBlame() }
    }

    func loadBlame() async {
        guard let service, let state = blameState else { return }
        var loading = state
        loading.isLoading = true
        loading.error = nil
        blameState = loading

        let url = URL(fileURLWithPath: state.path)
        do {
            var result = try await withAuthRetry { credential in
                try await service.blame(at: url, credential: credential)
            }
            // `svn blame` reports the file as it is on disk, including lines that
            // are not committed yet, so the text comes straight from the file.
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            result.attachContents(text)

            guard var current = blameState, current.id == state.id else { return }
            current.result = result
            current.isLoading = false
            blameState = current
        } catch {
            guard var current = blameState, current.id == state.id else { return }
            current.isLoading = false
            current.error = (error as? SVNError)?.message ?? error.localizedDescription
            blameState = current
        }
    }

    func dismissBlame() {
        blameState = nil
    }

    /// Markdown summary of one revision, for a ticket or a chat message.
    func summary(for entry: LogEntry) -> String {
        var lines: [String] = []
        var header = "r\(entry.revision)"
        if let author = entry.author, !author.isEmpty { header += " · \(author)" }
        if let date = entry.date {
            header += " · " + date.formatted(date: .abbreviated, time: .shortened)
        }
        lines.append(header)

        let body = entry.message.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(body.isEmpty ? "（无提交说明）" : body)

        if !entry.changedPaths.isEmpty {
            lines.append("")
            lines.append("变更 \(entry.changedPaths.count) 个路径：")
            for path in entry.changedPaths.prefix(20) {
                lines.append("- `\(path.action.rawValue)` \(path.path)")
            }
            if entry.changedPaths.count > 20 {
                lines.append("- … 其余 \(entry.changedPaths.count - 20) 个")
            }
        }
        return lines.joined(separator: "\n")
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
        lastCommit = nil

        // Not routed through `perform`: that helper swallows the error, and this
        // one needs to know whether to clear the message. Losing a carefully
        // written commit message to a failed commit is a real cost — the text is
        // the user's work, the failure is ours to report.
        do {
            guard let taskCenter else { return }
            let summary = try await withAuthRetry { credential in
                try await taskCenter.run("提交 \(urls.count) 个文件") { progress in
                    try await service.commit(
                        urls,
                        message: message,
                        credential: credential,
                        progress: progress
                    )
                }
            }
            commitMessages?.record(message)
            commitMessage = ""
            lastCommit = summary
            commitPreviewDiff = nil
            await refresh()
            await loadLog(reset: true)
        } catch {
            // Message and checkboxes stay exactly as they were.
            handle(error)
        }
    }

    /// Recent commit messages, newest first.
    var recentCommitMessages: [String] {
        commitMessages?.recent(limit: 10) ?? []
    }

    /// Loads the diff the commit panel shows for one file.
    ///
    /// Only text changes are previewed: a directory entry or a binary has no
    /// useful unified diff, and `svn diff` on a deleted path errors out.
    func previewDiff(for entry: StatusEntry) async {
        guard let service else { return }
        guard entry.item != .unversioned else {
            commitPreviewPath = entry.id
            commitPreviewDiff = nil
            return
        }
        commitPreviewPath = entry.id
        do {
            // Kept apart from `session.diff` so previewing here does not replace
            // what the Diff tab is showing.
            commitPreviewDiff = try await service.diffWorkingCopy(at: entryURL(entry))
        } catch {
            commitPreviewDiff = nil
        }
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

    // MARK: - Properties

    func openProperties(for path: String) {
        propertyEditor = PropertyEditorState(
            url: URL(fileURLWithPath: path),
            displayPath: relativePath(path)
        )
        Task { await reloadProperties() }
    }

    func openProperties(for entry: StatusEntry) {
        openProperties(for: entry.path)
    }

    func closeProperties() {
        propertyEditor = nil
    }

    /// Reads the property list again, keeping the sheet's identity so the UI does
    /// not flicker while a write is in flight.
    func reloadProperties() async {
        guard let service, let editor = propertyEditor else { return }
        propertyEditor?.isLoading = true
        do {
            let targets = try await service.properties(at: editor.url)
            guard var current = propertyEditor, current.id == editor.id else { return }
            current.targets = targets
            current.isLoading = false
            current.loadError = nil
            propertyEditor = current
        } catch {
            guard var current = propertyEditor, current.id == editor.id else { return }
            current.isLoading = false
            current.loadError = (error as? SVNError)?.message ?? error.localizedDescription
            propertyEditor = current
        }
    }

    func setProperty(name: String, value: String) async {
        guard let service, let editor = propertyEditor else { return }
        let url = editor.url
        await runPropertyWrite("设置属性 \(name)") {
            try await service.setProperty(name: name, value: value, on: [url])
        }
    }

    func deleteProperty(name: String) async {
        guard let service, let editor = propertyEditor else { return }
        let url = editor.url
        await runPropertyWrite("删除属性 \(name)") {
            _ = try await service.deleteProperty(name: name, on: [url])
        }
    }

    /// Ignores files by name, each in its own directory (`svn:ignore`).
    func ignore(_ paths: [String]) async {
        guard let service, !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let title = urls.count == 1
            ? "忽略「\(urls[0].lastPathComponent)」"
            : "忽略 \(urls.count) 项"
        await runPropertyWrite(title) {
            _ = try await service.ignore(urls)
        }
    }

    /// Ignores every file with the same extension.
    ///
    /// After ignoring one `*.log`, people almost always want the rest of them
    /// too: the alternative is a context-menu trip per file.
    func ignoreExtension(of entry: StatusEntry) async {
        guard let service else { return }
        let url = URL(fileURLWithPath: entry.path)
        let ext = url.pathExtension
        guard !ext.isEmpty else {
            await ignore([entry.path])
            return
        }
        let pattern = "*.\(ext)"
        let directory = url.deletingLastPathComponent()
        await runPropertyWrite("忽略 \(pattern)") {
            _ = try await service.addIgnorePattern(pattern, in: directory)
        }
    }

    /// Property writes refresh the status *and* the open sheet: the badge in the
    /// file list and the list in the sheet would otherwise disagree the moment
    /// the write lands.
    private func runPropertyWrite(
        _ title: String,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            if let taskCenter {
                _ = try await taskCenter.run(title) { _ in try await operation() }
            } else {
                try await operation()
            }
            await refresh()
            await reloadProperties()
        } catch {
            handle(error)
        }
    }

    // MARK: - Locks

    /// Reads repository-side locks. Separate from `refresh()` on purpose: this is
    /// the only status read that goes over the network.
    func refreshLocks() async {
        guard let service else { return }
        isLockLoading = true
        defer { isLockLoading = false }
        do {
            let target = path
            lockSnapshot = try await withAuthRetry { credential in
                try await service.locks(at: target, credential: credential)
            }
        } catch {
            handle(error)
        }
    }

    func openLockEditor(for paths: [String]) {
        guard !paths.isEmpty else { return }
        let own = paths.filter { lockSnapshot.isOwnLock(for: $0) }
        let foreign = lockSnapshot.foreignLocks(among: paths)
        // Already locked by us: taking it again would only produce W160035, so
        // the menu offers "解除锁定" instead. Reaching here means the snapshot is
        // stale, and the sheet says so rather than failing after a network trip.
        lockEditor = LockEditorState(
            paths: paths,
            displayPaths: paths.map { relativePath($0) },
            foreignLockCount: foreign.count,
            ownLockCount: own.count
        )
    }

    func closeLockEditor() {
        lockEditor = nil
    }

    func confirmLock() async {
        guard let service, let editor = lockEditor, !editor.paths.isEmpty else { return }
        let urls = editor.paths.map { URL(fileURLWithPath: $0) }
        let comment = editor.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let steal = editor.steal
        let title = urls.count == 1
            ? "锁定「\(urls[0].lastPathComponent)」"
            : "锁定 \(urls.count) 项"

        if steal {
            confirmation = Confirmation(
                title: title + "（强制）",
                message: "强制锁定会抢占以下路径上他人持有的锁：\n"
                    + editor.displayPaths.prefix(8).map { "· \($0)" }.joined(separator: "\n")
                    + "\n\n持有者将无法提交，直到他发现锁已易主。",
                confirmLabel: "强制锁定",
                isDestructive: true,
                action: { [weak self] in
                    await self?.runLock(urls: urls, comment: comment, steal: true, title: title, service: service)
                }
            )
            lockEditor = nil
            return
        }

        lockEditor = nil
        await runLock(urls: urls, comment: comment, steal: false, title: title, service: service)
    }

    private func runLock(
        urls: [URL],
        comment: String,
        steal: Bool,
        title: String,
        service: SVNService
    ) async {
        do {
            guard let taskCenter else { return }
            _ = try await withAuthRetry { credential in
                try await taskCenter.run(title) { _ in
                    try await service.lock(
                        urls,
                        comment: comment,
                        steal: steal,
                        confirmed: steal,
                        credential: credential
                    )
                }
            }
            await refresh()
            await refreshLocks()
        } catch {
            handle(namingTheHolder(error))
        }
    }

    /// Turns "path is already locked" into "…by alice".
    ///
    /// svn puts the holder's name in the warning text and nowhere else, so the
    /// generic message ("locked by someone else") would throw away the only
    /// actionable part of the failure — and it can be *our own* name, which is a
    /// different problem with a different fix (unlock, then lock again).
    private func namingTheHolder(_ error: any Error) -> any Error {
        guard let error = error as? SVNError,
              error.code == .pathLocked,
              let owner = LockOutputParser.owner(in: error.diagnosticOutput ?? "") else {
            return error
        }
        return SVNError(
            code: error.code,
            message: "该路径已由 \(owner) 锁定",
            diagnosticOutput: error.diagnosticOutput,
            svnCode: error.svnCode,
            exitCode: error.exitCode
        )
    }

    /// Releases locks through the shared confirmation dialog.
    ///
    /// The dialog carries the one fact that changes the decision: whether any of
    /// these locks belong to someone else. Breaking those needs `--force`, and
    /// that is the service-level `confirmed` gate, not a UI nicety.
    func requestUnlock(_ paths: [String]) {
        guard let service, !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let foreign = lockSnapshot.foreignLocks(among: paths)
        let needsForce = !foreign.isEmpty
        let preview = paths.prefix(8).map { "· \(relativePath($0))" }.joined(separator: "\n")
        let overflow = paths.count > 8 ? "\n… 其余 \(paths.count - 8) 项" : ""

        var lines = ["将解除 \(paths.count) 个路径的锁：", preview + overflow]
        if needsForce {
            lines.append("")
            lines.append("其中 \(foreign.count) 个锁由他人持有。解除需要强制，持有者将失去保护。")
            lines.append("如果只是在本地不想被锁影响，也可以不解除，直接继续编辑。")
        }

        confirmation = Confirmation(
            title: needsForce ? "强制解除 \(paths.count) 个锁" : "解除 \(paths.count) 个锁",
            message: lines.joined(separator: "\n"),
            confirmLabel: needsForce ? "强制解除" : "解除锁定",
            isDestructive: needsForce,
            action: { [weak self] in
                await self?.perform(needsForce ? "强制解除锁" : "解除锁定") { credential, _ in
                    try await service.unlock(
                        urls,
                        breakLock: needsForce,
                        confirmed: needsForce,
                        credential: credential
                    )
                }
                await self?.refreshLocks()
            }
        )
    }

    /// The lock to display for an entry: the one this working copy holds, the
    /// one the last refresh found on the server, or none.
    func lock(for entry: StatusEntry) -> RepositoryLock? {
        entry.effectiveLock ?? lockSnapshot.lock(for: entry.path)
    }

    func isOwnLock(_ entry: StatusEntry) -> Bool {
        if entry.repositoryLock != nil { return true }
        return lockSnapshot.isOwnLock(for: entry.path)
    }

    // MARK: - Settings and background refresh

    /// Applies the switches that change this session's background behaviour.
    func apply(settings: AppSettings) {
        autoRefreshEnabled = settings.autoRefresh
        previewBeforeUpdate = settings.previewBeforeUpdate
        externalDiffCommand = settings.externalDiffCommand
        if autoRefreshEnabled {
            startWatching()
        } else {
            stopWatching()
        }
    }

    /// Starts watching the working copy. Idempotent, and a no-op when the
    /// setting is off or SVN is not ready.
    func startWatching() {
        guard autoRefreshEnabled, watcher == nil, service != nil else { return }
        let watcher = WorkingCopyWatcher(root: path) { [weak self] in
            Task { @MainActor in self?.fileSystemDidChange() }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Stops watching. The stream holds an unretained pointer to itself, so this
    /// must run before the session is deallocated.
    func stopWatching() {
        watcher?.stop()
        watcher = nil
        pendingWatchRefresh?.cancel()
        pendingWatchRefresh = nil
    }

    private func fileSystemDidChange() {
        guard autoRefreshEnabled, service != nil else { return }
        // Reading the working copy while a write holds it would block or fail
        // with `E155004`, and that failure would look like ours rather than the
        // writer's. Skipping is safe: every write refreshes when it finishes.
        guard (taskCenter?.runningCount ?? 0) == 0, !isLoading, updatePreview == nil else { return }

        pendingWatchRefresh?.cancel()
        pendingWatchRefresh = Task { [weak self] in
            // Editors save in bursts — write, truncate, rename — and one status
            // read per burst is the entire point of debouncing.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.refresh(quiet: true)
        }
    }

    // MARK: - Relocate

    /// Repoints this working copy at the same repository over a different URL.
    ///
    /// svn's own UUID check is the safety net: relocating to a different
    /// repository fails, so this cannot silently splice two histories together.
    func relocate(to newURL: String) async {
        guard let service else { return }
        let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("://") else {
            handle(SVNError(code: .invalidInvocation, message: "新的仓库地址需要包含协议"))
            return
        }
        let target = path
        do {
            _ = try await withAuthRetry { credential in
                try await service.relocate(workingCopy: target, to: trimmed, credential: credential)
            }
            await refresh()
            await probeConnection()
        } catch {
            handle(error)
        }
    }

    // MARK: - Connection

    /// Asks the server whether it is there.
    ///
    /// Only called when the session is opened and from the "检查连接" action, and
    /// skipped entirely for `file://` repositories, where "unreachable" is not a
    /// state that can exist.
    func probeConnection() async {
        guard let service else { return }
        guard let url = info?.url, !url.isEmpty else { return }
        if url.hasPrefix("file://") {
            connection = .reachable(Date())
            return
        }
        do {
            _ = try await service.info(at: url)
            connection = .reachable(Date())
        } catch let error as SVNError {
            connection = error.code.isAuthenticationRelated
                ? .needsAuthentication
                : .unreachable(error.message)
        } catch {
            connection = .unreachable(error.localizedDescription)
        }
    }

    // MARK: - Changelists

    /// Filters the change list to one changelist. `nil` shows everything.
    ///
    /// A changelist is a local label, not a server concept — which is why this is
    /// a view filter and not a query: the data is already in the snapshot.
    var changelistFilter: String?

    /// Names present in the working copy, in alphabetical order.
    var changelists: [String] {
        Set((status?.entries ?? []).compactMap(\.changelist))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Puts paths into a changelist, or takes them out when `name` is `nil`.
    func assignChangelist(_ name: String?, to paths: [String]) async {
        guard let service, !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        do {
            try await service.setChangelist(name, on: urls)
            await refresh()
        } catch {
            handle(error)
        }
    }

    // MARK: - Externals

    /// The `svn:externals` definitions of this working copy, read-only.
    struct ExternalsState: Identifiable {
        let id = UUID()
        var isLoading = true
        var targets: [PropertyTarget] = []
        var error: String?
    }

    var externalsState: ExternalsState?

    func openExternals() {
        externalsState = ExternalsState()
        Task { await loadExternals() }
    }

    func loadExternals() async {
        guard let service, let state = externalsState else { return }
        guard let url = info?.url, url.contains("://") else {
            externalsState?.isLoading = false
            externalsState?.error = "无法确定仓库地址（file:// 之外的工作副本需要先读取信息）"
            return
        }
        do {
            let targets = try await withAuthRetry { credential in
                try await service.remoteProperties(at: url, credential: credential)
            }
            guard var current = externalsState, current.id == state.id else { return }
            current.targets = targets.filter { $0.value(of: "svn:externals") != nil }
            current.isLoading = false
            externalsState = current
        } catch {
            guard var current = externalsState, current.id == state.id else { return }
            current.isLoading = false
            current.error = (error as? SVNError)?.message ?? error.localizedDescription
            externalsState = current
        }
    }

    func dismissExternals() {
        externalsState = nil
    }

    // MARK: - History helpers

    /// The entries the local filter lets through.
    var filteredLog: [LogEntry] { logFilter.apply(to: log) }

    private var logCacheKey: LogCache.Key {
        LogCache.Key(
            workingCopy: path.standardizedFileURL.path,
            target: logTarget ?? "",
            repositoryUUID: info?.repositoryUUID
        )
    }

    /// Filesystem path handed to `svn log`: the root, or one path inside it.
    private func logQueryTarget() -> String {
        guard let logTarget, !logTarget.isEmpty else { return path.path }
        return path.appendingPathComponent(logTarget).path
    }

    /// Repository URL handed to `svn log --search`.
    ///
    /// Search has to go to a URL: measured against svn 1.14.5, `--search` on a
    /// working-copy path returns an empty log regardless of the pattern, while the
    /// same pattern against the repository URL finds the revisions.
    private func logQueryURL() -> String? {
        guard let base = info?.url, !base.isEmpty, base.contains("://") else { return nil }
        guard let logTarget, !logTarget.isEmpty else { return base }
        guard let root = URL(string: base) else { return nil }
        return logTarget
            .split(separator: "/")
            .reduce(root) { $0.appendingPathComponent(String($1)) }
            .absoluteString
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
