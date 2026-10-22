import AppKit
import Foundation
import Observation
import OpenSVNCore

/// Global application state: the SVN service, the bookmark list, the task center,
/// and the credential prompt.
///
/// Nothing here persists secrets. The only credential copies are (a) the
/// Keychain, written by `SVNService` after a successful authenticated call, and
/// (b) the in-memory value the user just typed.
@MainActor
@Observable
final class AppState {
    struct AuthPrompt: Identifiable {
        let id = UUID()
        let host: String
        var errorMessage: String?
    }

    /// Progress of the "try a merge" demo builder. Kept on `AppState` rather than
    /// in the sheet's `@State` so that closing the sheet mid-build does not strand
    /// the operation or lose its failure message.
    enum DemoPhase: Equatable {
        case idle
        case building
        case failed(String)
    }

    private(set) var bookmarks: [RepositoryBookmark] = []
    private(set) var sessions: [UUID: RepositorySession] = [:]
    var selectedBookmarkID: UUID?
    var settings: AppSettings
    private(set) var installation: SVNInstallation?
    private(set) var service: SVNService?
    private(set) var isStarting = true
    var startupError: SVNError?
    var authPrompt: AuthPrompt?
    var showingCheckoutSheet = false
    var showingTaskCenter = false
    var showingSettings = false
    var showingDemoSheet = false
    private(set) var demoPhase: DemoPhase = .idle
    /// Set when a previously generated demo working copy is still on disk, so the
    /// sheet can offer "open" instead of "generate".
    private(set) var demoWorkingCopy: URL?

    /// Writes that were running when a previous launch died. Empty during a
    /// healthy session; the banner only appears when this is non-empty.
    private(set) var recoveryItems: [OperationJournal.Entry] = []
    /// Set when the journal file could not be read and was moved aside.
    private(set) var journalQuarantineURL: URL?
    /// Last recovery action failure, shown inside the banner rather than in the
    /// "SVN unavailable" alert (which would be the wrong story).
    var recoveryError: String?

    let taskCenter = TaskCenter()
    let journal = OperationJournal()
    /// Shared across every repository: the messages describe the person's work,
    /// not one checkout.
    let commitMessages = CommitMessageStore()
    private let repositoryStore = RepositoryStore()
    private var authContinuation: CheckedContinuation<SVNCredential?, Never>?

    init() {
        self.settings = AppSettings.load()
        self.bookmarks = repositoryStore.load()
    }

    var selectedBookmark: RepositoryBookmark? {
        bookmarks.first { $0.id == selectedBookmarkID }
    }

    var selectedSession: RepositorySession? {
        guard let selectedBookmarkID else { return nil }
        return session(for: selectedBookmarkID)
    }

    // MARK: - Lifecycle

    func start() async {
        isStarting = true
        defer { isStarting = false }

        // Configure logging before anything that can fail. A support request
        // without a log turns every diagnosis into guesswork.
        await AppLog.shared.configure(
            directory: AppLog.defaultDirectory,
            level: settings.logLevel
        )
        AppLog.shared.record(.info, "启动 OpenSVN，日志级别 \(settings.logLevel.rawValue)，日志位置 \(AppLog.defaultDirectory.path)")

        bookmarks = repositoryStore.load()

        // Read the journal *before* building the service: a previous crash is the
        // first thing the user needs to know about, and it is independent of
        // whether svn can be found right now.
        recoveryItems = await journal.unfinished()
        journalQuarantineURL = await journal.quarantineURL()
        if !recoveryItems.isEmpty {
            AppLog.shared.record(.warning, "发现 \(recoveryItems.count) 项上次未正常结束的写操作", category: "recovery")
        }

        await buildService()

        if selectedBookmarkID == nil, let first = bookmarks.first {
            selectedBookmarkID = first.id
        }
        if let session = selectedSession {
            await session.refresh()
        }
    }

    func buildService() async {
        do {
            let service = try await SVNServiceFactory.makeService(
                .init(
                    explicitExecutablePath: settings.explicitSVNPath,
                    bundledCandidates: SVNServiceFactory.bundledCandidateURLs(),
                    credentialStore: KeychainCredentialStore(),
                    environment: ProcessInfo.processInfo.environment,
                    timeout: settings.operationTimeout,
                    journal: journal
                )
            )
            self.service = service
            // `installation` is a `nonisolated let` on the actor.
            self.installation = service.installation
            self.startupError = nil
            await service.setMaxConcurrentWrites(settings.maxConcurrentWrites)
            AppLog.shared.record(
                .info,
                "使用 svn \(service.installation.version.description)（\(service.installation.source.displayName)）：\(service.installation.executableURL.path)",
                category: "svn"
            )
            for session in sessions.values {
                session.attach(service: service, taskCenter: taskCenter)
            }
        } catch let error as SVNError {
            self.service = nil
            self.installation = nil
            self.startupError = error
            AppLog.shared.record(.error, "无法初始化 SVN：\(error.message)", category: "svn")
        } catch {
            self.service = nil
            self.installation = nil
            self.startupError = SVNError(code: .unknown, message: error.localizedDescription)
            AppLog.shared.record(.error, "无法初始化 SVN：\(error.localizedDescription)", category: "svn")
        }
    }

    func apply(settings newValue: AppSettings) async {
        settings = newValue
        newValue.save()
        await AppLog.shared.configure(level: newValue.logLevel)
        AppLog.shared.record(.info, "设置已更新：日志级别 \(newValue.logLevel.rawValue)，写操作并发上限 \(newValue.maxConcurrentWrites)")
        // Rebuild first: `apply` may start the file watcher, which needs a
        // ready service to be worth anything.
        await buildService()
        for session in sessions.values {
            session.updateTimeout(newValue.operationTimeout)
            session.apply(settings: newValue)
        }
    }

    // MARK: - Tasks

    /// Re-runs a failed task, then refreshes every open session.
    ///
    /// The refresh is not optional: the retry bypasses the per-view code path
    /// that normally refreshes after an operation, so without this the sidebar
    /// and file list would still show the state from the failure.
    func retryTask(_ id: UUID) async {
        let succeeded = await taskCenter.retry(id)
        guard succeeded else { return }
        for session in sessions.values {
            await session.refresh()
        }
    }

    // MARK: - Bookmarks

    func session(for id: UUID) -> RepositorySession? {
        guard let bookmark = bookmarks.first(where: { $0.id == id }) else { return nil }
        if let existing = sessions[id] {
            return existing
        }
        let session = RepositorySession(
            bookmark: bookmark,
            service: service,
            taskCenter: taskCenter,
            commitMessages: commitMessages,
            onCredentialRequired: { [weak self] host in
                await self?.requestCredential(host: host)
            }
        )
        sessions[id] = session
        session.apply(settings: settings)
        return session
    }

    @discardableResult
    func addRepository(at url: URL) -> RepositorySession? {        guard WorkingCopyLocator.isWorkingCopy(url) else {
            startupError = SVNError(
                code: .notAWorkingCopy,
                message: "所选目录不是 SVN 工作副本：\(url.path)"
            )
            return nil
        }
        if let existing = bookmarks.first(where: { $0.path == url.path }) {
            selectedBookmarkID = existing.id
            return session(for: existing.id)
        }
        let bookmark = RepositoryBookmark(path: url.path, lastOpenedAt: Date())
        bookmarks.append(bookmark)
        repositoryStore.save(bookmarks)
        selectedBookmarkID = bookmark.id
        let session = session(for: bookmark.id)
        Task { await session?.refresh() }
        return session
    }

    func removeRepository(id: UUID) {        bookmarks.removeAll { $0.id == id }
        sessions[id] = nil
        repositoryStore.save(bookmarks)
        if selectedBookmarkID == id {
            selectedBookmarkID = bookmarks.first?.id
        }
    }

    func moveBookmark(_ id: UUID, to index: Int) {
        guard let current = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let bookmark = bookmarks.remove(at: current)
        let clamped = min(max(0, index), bookmarks.count)
        bookmarks.insert(bookmark, at: clamped)
        repositoryStore.save(bookmarks)
    }

    /// Native folder picker for "add existing working copy".
    func presentAddWorkingCopyPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "选择 SVN 工作副本目录（包含 .svn 的目录）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addRepository(at: url)
    }

    // MARK: - Merge demo
    //
    // The merge editor is the hardest thing in the app to evaluate without data:
    // it needs two working copies, a committed edit, a conflicting local edit, and
    // a working `svnadmin`. Nobody does that to try a feature. This builds the
    // whole setup locally, then opens it — the shortest path from "what is this?"
    // to "I see what it does".

    func refreshDemoAvailability() {
        demoWorkingCopy = WorkingCopyLocator.isWorkingCopy(DemoWorkspace.defaultWorkingCopy)
            ? DemoWorkspace.defaultWorkingCopy
            : nil
    }

    func createDemoWorkspace() async {
        guard let installation else {
            demoPhase = .failed("svn 还没有就绪，无法生成演示。")
            return
        }
        guard let svnadmin = DemoWorkspace.adminTool(nextTo: installation.executableURL) else {
            demoPhase = .failed(
                "找不到 svnadmin（应当与 svn 在同一目录）。请安装完整版 Subversion，"
                + "或在终端运行 scripts/create-conflict-demo.sh。"
            )
            return
        }

        demoPhase = .building
        let workspace = DemoWorkspace(svn: installation.executableURL, svnadmin: svnadmin)
        do {
            // Building writes files and waits on several processes; keep it off the
            // main actor so the sheet keeps animating.
            let result = try await Task.detached(priority: .userInitiated) {
                try await workspace.build()
            }.value
            demoPhase = .idle
            demoWorkingCopy = result.workingCopy
            showingDemoSheet = false
            addRepository(at: result.workingCopy)
            if let session = selectedSession {
                await session.refresh()
            }
        } catch let error as SVNError {
            demoPhase = .failed(error.message)
        } catch {
            demoPhase = .failed(error.localizedDescription)
        }
    }

    func openExistingDemo() {
        refreshDemoAvailability()
        guard let demoWorkingCopy else { return }
        showingDemoSheet = false
        addRepository(at: demoWorkingCopy)
    }

    func dismissDemoFailure() {
        demoPhase = .idle
    }

    // MARK: - Credentials

    /// Presents the credential sheet and suspends until the user answers.
    func requestCredential(host: String) async -> SVNCredential? {
        if authContinuation != nil {
            // Only one prompt at a time; a second request fails fast.
            return nil
        }
        return await withCheckedContinuation { continuation in
            authContinuation = continuation
            authPrompt = AuthPrompt(host: host)
        }
    }

    func submitCredential(username rawUsername: String, password: String) {
        guard var prompt = authPrompt else { return }
        let username = rawUsername.trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else {
            prompt.errorMessage = "请输入用户名"
            authPrompt = prompt
            return
        }
        let credential = SVNCredential(username: username, password: password)
        // Clear the typed password from UI state immediately.
        authPrompt = nil
        authContinuation?.resume(returning: credential)
        authContinuation = nil
    }

    func cancelCredentialPrompt() {
        authPrompt = nil
        authContinuation?.resume(returning: nil)
        authContinuation = nil
    }

    func clearAllCredentials() async {
        do {
            try await service?.forgetAllCredentials()
            for session in sessions.values {
                session.credential = nil
            }
        } catch {
            startupError = SVNError(code: .unknown, message: error.localizedDescription)
        }
    }

    /// Every host (and realm) that currently has a password in the Keychain.
    ///
    /// Metadata only — no secret is read. `all` is separate from `scopes` so the
    /// settings screen can show "saved for these servers" without inventing an
    /// entry when the Keychain cannot be listed.
    func credentialScopes() async -> [CredentialScope] {
        await service?.credentialScopes() ?? []
    }

    /// Removes one stored credential, and forgets the in-memory copy in every
    /// session that was using it.
    ///
    /// The in-memory half matters: without it, a session would keep committing
    /// with a password the user just deleted, which is the opposite of what
    /// deleting it was meant to achieve.
    func forgetCredential(_ scope: CredentialScope) async {
        await service?.forgetCredential(for: scope)
        for session in sessions.values where session.repositoryHost == scope.host {
            session.credential = nil
        }
    }

    // MARK: - Interrupted operations

    /// Runs `svn cleanup` for an operation that a previous launch left unfinished.
    ///
    /// Cleanup, not "retry": a half-finished commit must never be blindly
    /// repeated, and a locked working copy is the usual symptom. Retrying is the
    /// user's decision, made after the state is readable again.
    func recover(_ entry: OperationJournal.Entry) async {
        guard let service else {
            recoveryError = "SVN 服务尚未就绪，暂时无法清理。"
            return
        }
        let url = URL(fileURLWithPath: entry.workingCopy)
        guard FileManager.default.fileExists(atPath: url.path) else {
            recoveryError = "目录已不存在：\(entry.workingCopy)"
            return
        }
        do {
            _ = try await taskCenter.run("清理 \(url.lastPathComponent)") { _ in
                try await service.cleanup(at: url)
            }
            await journal.discard(entry.id)
            recoveryItems = await journal.unfinished()
            recoveryError = nil

            let standardized = url.standardizedFileURL.path
            if let session = sessions.values.first(where: {
                URL(fileURLWithPath: $0.bookmark.path).standardizedFileURL.path == standardized
            }) {
                await session.refresh()
            }
        } catch {
            let svnError = (error as? SVNError)
                ?? SVNError(code: .unknown, message: error.localizedDescription)
            recoveryError = "清理失败：\(svnError.message)"
        }
    }

    func dismissRecovery(_ entry: OperationJournal.Entry) async {
        await journal.discard(entry.id)
        recoveryItems = await journal.unfinished()
        recoveryError = nil
    }

    func dismissAllRecovery() async {
        await journal.discardAll()
        recoveryItems = await journal.unfinished()
        recoveryError = nil
    }

    /// Hides the "journal was unreadable" notice. The corrupt file itself stays
    /// on disk (`journal.corrupt-*.json`); only the banner is dismissed.
    func acknowledgeJournalCorruption() {
        journalQuarantineURL = nil
    }

    // MARK: - Checkout

    func checkout(url: String, destination: URL, depth: SVNService.CheckoutDepth, revision: Int64?) async throws {
        guard let service else { throw SVNError(code: .svnNotFound, message: "SVN 服务尚未就绪") }

        func attempt(_ credential: SVNCredential?) async throws {
            _ = try await taskCenter.run("检出 \(url)") { progress in
                try await service.checkout(
                    url: url,
                    to: destination,
                    revision: revision,
                    depth: depth,
                    credential: credential,
                    progress: progress
                )
            }
        }

        do {
            try await attempt(nil)
        } catch let error as SVNError where error.code.isAuthenticationRelated {
            guard let host = URL(string: url)?.host,
                  let credential = await requestCredential(host: host) else {
                throw error
            }
            try await attempt(credential)
        }
        addRepository(at: destination)
    }
}
