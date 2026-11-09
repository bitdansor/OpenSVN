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
    /// Repository bookmarks, which have no working copy behind them.
    private(set) var browsers: [UUID: RepositoryBrowser] = [:]
    var selectedBookmarkID: UUID?
    var settings: AppSettings
    /// The language the interface is drawn in, resolved from `settings.language`
    /// once at launch and again whenever the choice changes.
    ///
    /// This exists only so SwiftUI can notice. `Localization` holds the value the
    /// string lookups read, but a static in another module is invisible to
    /// observation, so views would keep the old text until something else
    /// invalidated them. Views that must re-render carry `.id(interfaceLanguage)`
    /// (or read it), which turns a language change into a fresh view identity —
    /// the one reliable way to make every literal in the tree re-resolve at once.
    private(set) var interfaceLanguage: InterfaceLanguage
    private(set) var installation: SVNInstallation?
    private(set) var service: SVNService?
    private(set) var isStarting = true
    var startupError: SVNError?
    var authPrompt: AuthPrompt?
    var showingCheckoutSheet = false
    var showingNewRepositorySheet = false
    var showingTaskCenter = false
    var showingDemoSheet = false
    var showingUpdateSheet = false
    /// Result of the most recent version check, when it succeeded.
    private(set) var updateCheckResult: UpdateCheckResult?
    /// Message from the most recent check, when it did not.
    private(set) var updateCheckError: String?
    private(set) var isCheckingForUpdates = false
    /// Where the in-app update path has got to. Kept on `AppState` rather than in
    /// the sheet so closing the sheet during a download neither cancels it nor
    /// loses the failure message.
    enum UpdateDownloadPhase: Equatable {
        case idle
        case downloading(UpdateDownloadProgress)
        case verifying
        case ready(stagedBundle: URL, version: AppVersion)
        case installing
        case failed(String)
    }
    private(set) var updateDownloadPhase: UpdateDownloadPhase = .idle
    /// The Developer ID team of the *running* bundle. `nil` for an ad-hoc build,
    /// which is the normal state of a build made from source without a
    /// certificate. It is not a blocker by itself: an ad-hoc build can install a
    /// release whose manifest is signed by a key compiled into the app. It only
    /// matters for releases that offer GitHub's digest and nothing else, where
    /// the team is the only identity available to compare.
    private(set) var runningTeamIdentifier: String?
    private var updateDownloadTask: Task<Void, Never>?
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
    private var hasStarted = false

    init() {
        let loaded = AppSettings.load()
        self.settings = loaded
        self.bookmarks = repositoryStore.load()
        // Before the first view is built: a launch that resolved the language a
        // moment later would paint one frame in the wrong one.
        self.interfaceLanguage = Localization.apply(loaded.language)
    }

    var selectedBookmark: RepositoryBookmark? {
        bookmarks.first { $0.id == selectedBookmarkID }
    }

    var selectedSession: RepositorySession? {
        guard let selectedBookmarkID else { return nil }
        return session(for: selectedBookmarkID)
    }

    var selectedBrowser: RepositoryBrowser? {
        guard let selectedBookmarkID else { return nil }
        return browser(for: selectedBookmarkID)
    }

    var workingCopyBookmarks: [RepositoryBookmark] { bookmarks.filter { !$0.isRepository } }
    var repositoryBookmarks: [RepositoryBookmark] { bookmarks.filter(\.isRepository) }

    // MARK: - Lifecycle

    /// `start()` for the scene, at most once per process.
    ///
    /// The window is rebuilt when the interface language changes, so its `.task`
    /// can fire again; discovery and the recovery-journal read are launch work,
    /// not refresh work, and must not repeat.
    func startOnce() async {
        guard !hasStarted else { return }
        hasStarted = true
        await start()
    }

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

        // Last, and only when the user asked for it. A launch that begins with a
        // network request to a server the user never mentioned is the behaviour
        // this project refuses everywhere else.
        if settings.checkForUpdatesOnLaunch {
            await checkForUpdates(explicitlyRequested: false)
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
            for browser in browsers.values {
                browser.attach(service: service, taskCenter: taskCenter)
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

    /// Applies settings and pushes them into everything already running.
    ///
    /// Rebuilding the service re-runs discovery and can drop `installation` for a
    /// moment, so it is reserved for the one change that can actually pick a
    /// different binary. A timeout, a toggle or a diff command is a live value on
    /// the existing service; re-discovering `svn` for those would interrupt the
    /// working copies on screen for nothing.
    func apply(settings newValue: AppSettings, rebuildService: Bool = true) async {
        let previousPath = settings.explicitSVNPath
        if newValue.language != settings.language {
            interfaceLanguage = Localization.apply(newValue.language)
        }
        settings = newValue
        newValue.save()
        await AppLog.shared.configure(level: newValue.logLevel)
        AppLog.shared.record(.info, "设置已更新：日志级别 \(newValue.logLevel.rawValue)，写操作并发上限 \(newValue.maxConcurrentWrites)")
        // Rebuild first: starting the file watcher needs a ready service to be
        // worth anything.
        if rebuildService || newValue.explicitSVNPath != previousPath {
            await buildService()
        } else if let service {
            await service.setMaxConcurrentWrites(newValue.maxConcurrentWrites)
        }
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
        guard let bookmark = bookmarks.first(where: { $0.id == id }), !bookmark.isRepository else {
            return nil
        }
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
                message: L.f("所选目录不是 SVN 工作副本：%@", String(describing: url.path))
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
        browsers[id] = nil
        repositoryStore.save(bookmarks)
        if selectedBookmarkID == id {
            selectedBookmarkID = bookmarks.first?.id
        }
    }

    /// Asks for a repository URL and bookmarks it.
    ///
    /// An `NSAlert` because the answer is one line of text and a sheet would need
    /// a whole view for it; the URL is validated by `addRepositoryBookmark`.
    func promptForRepositoryBookmark() {
        let alert = NSAlert()
        alert.messageText = L.t("只看仓库（不检出）")
        alert.informativeText = L.t("输入仓库地址。浏览、建目录、打 tag 都不需要把文件拉到本地。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://svn.example.com/repo/trunk"
        alert.accessoryView = field
        alert.addButton(withTitle: L.t("添加"))
        alert.addButton(withTitle: L.t("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        addRepositoryBookmark(url: url)
    }

    /// Adds a repository bookmark and returns its browser.
    ///
    /// A repository can be bookmarked without checking anything out — that is the
    /// point of having it: looking at `trunk` or a tag should not cost a copy of
    /// the whole tree.
    @discardableResult
    func addRepositoryBookmark(url: String, name: String? = nil) -> RepositoryBrowser? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("://") || trimmed.hasPrefix("/") else {
            startupError = SVNError(
                code: .invalidInvocation,
                message: L.f("仓库地址需要包含协议（例如 https:// 或 svn://）：%@", String(describing: trimmed))
            )
            return nil
        }
        if let existing = bookmarks.first(where: { $0.repositoryURL == trimmed }) {
            selectedBookmarkID = existing.id
            return browser(for: existing.id)
        }
        let bookmark = RepositoryBookmark.repository(url: trimmed, name: name)
        bookmarks.append(bookmark)
        repositoryStore.save(bookmarks)
        selectedBookmarkID = bookmark.id
        let browser = browser(for: bookmark.id)
        Task { await browser?.loadRoot() }
        return browser
    }

    func browser(for id: UUID) -> RepositoryBrowser? {
        guard let bookmark = bookmarks.first(where: { $0.id == id }), bookmark.isRepository else {
            return nil
        }
        if let existing = browsers[id] { return existing }
        let browser = RepositoryBrowser(
            bookmark: bookmark,
            service: service,
            taskCenter: taskCenter,
            onCredentialRequired: { [weak self] host in
                await self?.requestCredential(host: host)
            }
        )
        browsers[id] = browser
        return browser
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
        panel.prompt = L.t("添加")
        panel.message = L.t("选择 SVN 工作副本目录（包含 .svn 的目录）")
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
            demoPhase = .failed(L.t("svn 还没有就绪，无法生成演示。"))
            return
        }
        guard let svnadmin = DemoWorkspace.adminTool(nextTo: installation.executableURL) else {
            demoPhase = .failed(
                L.t("找不到 svnadmin（应当与 svn 在同一目录）。请安装完整版 Subversion，")
                + L.t("或在终端运行 scripts/create-conflict-demo.sh。")
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
            prompt.errorMessage = L.t("请输入用户名")
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
            recoveryError = L.t("SVN 服务尚未就绪，暂时无法清理。")
            return
        }
        let url = URL(fileURLWithPath: entry.workingCopy)
        guard FileManager.default.fileExists(atPath: url.path) else {
            recoveryError = L.f("目录已不存在：%@", String(describing: entry.workingCopy))
            return
        }
        do {
            _ = try await taskCenter.run(L.f("清理 %@", String(describing: url.lastPathComponent))) { _ in
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
            recoveryError = L.f("清理失败：%@", String(describing: svnError.message))
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

    func checkout(
        url: String,
        destination: URL,
        depth: SVNService.CheckoutDepth,
        revision: Int64?,
        storePristines: Bool = true
    ) async throws {
        guard let service else { throw SVNError(code: .svnNotFound, message: L.t("SVN 服务尚未就绪")) }

        func attempt(_ credential: SVNCredential?) async throws {
            _ = try await taskCenter.run(L.f("检出 %@", String(describing: url))) { progress in
                try await service.checkout(
                    url: url,
                    to: destination,
                    revision: revision,
                    depth: depth,
                    storePristines: storePristines,
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

    // MARK: - Local repository creation

    /// `svnadmin create`, run through the task centre like every other write so
    /// it is visible, cancellable and retryable.
    ///
    /// Errors are thrown rather than turned into an alert here: the sheet that
    /// asked is still open and owns the field the user needs to fix.
    func createLocalRepository(at location: URL) async throws -> LocalRepository {
        guard let service else {
            throw SVNError(code: .svnNotFound, message: L.t("SVN 服务尚未就绪"))
        }
        return try await taskCenter.run(L.f("创建本地仓库 %@", String(describing: location.lastPathComponent))) { _ in
            try await service.createLocalRepository(at: location)
        }
    }

    /// Creates the repository and checks out its (empty) root next to it, so the
    /// flow ends with a working copy in the sidebar instead of a URL the user has
    /// to paste into the checkout sheet.
    ///
    /// `-wc` next to the repository, not inside it: a working copy inside the
    /// repository directory would be added to the repository on the next
    /// `svn add`, which is never what anyone wants.
    func createLocalRepositoryAndCheckout(at location: URL) async throws -> LocalRepository {
        let repository = try await createLocalRepository(at: location)
        let workingCopy = location.deletingLastPathComponent()
            .appendingPathComponent(location.lastPathComponent + "-wc", isDirectory: true)
        try await checkout(
            url: repository.url,
            destination: workingCopy,
            depth: .infinity,
            revision: nil
        )
        return repository
    }

    // MARK: - Update check

    /// Key for the last successful check, so a launch check cannot hammer the
    /// feed. GitHub allows 60 unauthenticated requests per hour per address.
    private static let lastUpdateCheckKey = "cn.opensvn.lastUpdateCheckAt"
    private static let updateCheckInterval: TimeInterval = 24 * 60 * 60

    /// Asks the release feed whether a newer version exists.
    ///
    /// - Parameter explicitlyRequested: `true` when the user picked 检查更新…
    ///   from the menu. That changes two things: the daily de-duplication is
    ///   skipped, and a "no update" or an error is shown rather than staying
    ///   silent. A launch check only speaks up when there is something to say.
    func checkForUpdates(explicitlyRequested: Bool) async {
        guard !isCheckingForUpdates else { return }
        if !explicitlyRequested, let last = lastUpdateCheck,
           Date().timeIntervalSince(last) < Self.updateCheckInterval {
            return
        }

        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        updateCheckError = nil
        resetUpdateDownload()
        let checker = UpdateChecker(currentVersion: UpdateChecker.bundleVersion())
        do {
            let result = try await checker.check()
            updateCheckResult = result
            lastUpdateCheck = Date()
            AppLog.shared.record(
                .info,
                "检查更新：当前 \(checker.currentVersion)，结果 \(result.title)",
                category: "update"
            )
            if result.isUpdateAvailable {
                // Asked once per check rather than per download: the answer is a
                // property of the running bundle and cannot change while it runs.
                runningTeamIdentifier = (try? await UpdateInstaller()
                    .teamIdentifier(of: Bundle.main.bundleURL)) ?? nil
            }
            if explicitlyRequested || result.isUpdateAvailable {
                showingUpdateSheet = true
            }
            if settings.autoDownloadUpdates, canInstallUpdateAutomatically {
                startUpdateDownload()
            }
        } catch {
            // A failed check must never look like "you are up to date".
            let message = (error as? UpdateCheckError)?.errorDescription
                ?? error.localizedDescription
            updateCheckError = message
            updateCheckResult = nil
            AppLog.shared.record(.warning, "检查更新失败：\(message)", category: "update")
            if explicitlyRequested {
                showingUpdateSheet = true
            }
        }
    }

    // MARK: - In-app update

    /// The release as something installable, when the feed carried a verifiable
    /// archive. `nil` means "download it yourself".
    var updatePackage: UpdatePackage? {
        guard case .updateAvailable(_, let release) = updateCheckResult else { return nil }
        return release.package
    }

    /// Why the automatic path is unavailable, phrased for the sheet. `nil` when
    /// it is available.
    ///
    /// Three independent reasons, kept apart because each calls for a different
    /// action: a build with no trusted key (rebuild it, or use a release that
    /// carries a Developer ID), a release with no verifiable digest at all (the
    /// publisher fixes it), and an unsigned build looking at a release that only
    /// offers GitHub's digest (nothing to compare identity against).
    var updateInstallBlocker: String? {
        guard let package = updatePackage else {
            return L.t("这个版本没有提供可校验的安装包，只能下载后手动安装。")
        }
        if package.hasSignedManifest {
            guard UpdateSigningKey.isConfigured else {
                return L.t("这个发布用项目密钥签了摘要，但当前构建没有内置对应的公钥，无法校验，只能手动下载。")
            }
            // Identity comes from the manifest key, so an ad-hoc build can
            // install this without a Developer ID certificate. That is the
            // point: the project's own key is the anchor.
            return nil
        }
        guard package.archive.sha256 != nil else {
            return L.t("发布方既没有提供签名清单，也没有提供 SHA-256 摘要，无法校验，只能手动下载。")
        }
        guard runningTeamIdentifier != nil else {
            return L.t("这个发布没有附带签名清单，而当前构建不是 Developer ID 签名，无法确认发布者，因此不会自动安装。")
        }
        return nil
    }

    var canInstallUpdateAutomatically: Bool {
        updateInstallBlocker == nil
    }

    func resetUpdateDownload() {
        updateDownloadTask?.cancel()
        updateDownloadTask = nil
        updateDownloadPhase = .idle
    }

    func cancelUpdateDownload() {
        updateDownloadTask?.cancel()
        updateDownloadTask = nil
        if case .installing = updateDownloadPhase { return }
        updateDownloadPhase = .idle
    }

    /// Downloads, verifies and unpacks, stopping short of the swap.
    ///
    /// Every step is a refusal waiting to happen: a manifest whose signature
    /// does not verify, a digest that disagrees with the feed, a size mismatch, a
    /// bundle that is not an app, a version that is not the one announced, or a
    /// bundle whose identifier is not this application. Nothing is written
    /// outside the staging directory until the user confirms the install.
    func startUpdateDownload() {
        guard updateDownloadTask == nil else { return }
        guard let package = updatePackage, updateInstallBlocker == nil else { return }
        let team = runningTeamIdentifier

        updateDownloadTask = Task { [weak self] in
            await self?.performUpdateDownload(package: package, team: team)
            await MainActor.run { self?.updateDownloadTask = nil }
        }
    }

    private func performUpdateDownload(package: UpdatePackage, team: String?) async {
        let updates = UpdateInstaller.updatesDirectory()
        let staging = UpdateInstaller.stagingDirectory(for: package.version, in: updates)
        let archive = staging.appendingPathComponent(package.archive.name)
        let throttle = UpdateProgressThrottle()

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            // The digest is resolved before a byte is downloaded: asking for the
            // archive first and then looking for something to compare it against
            // would waste the transfer and invite skipping the check.
            let expectedDigest: String
            if package.hasSignedManifest {
                updateDownloadPhase = .verifying
                expectedDigest = try await UpdateManifestLoader().verifiedDigest(for: package)
            } else if let digest = package.archive.sha256 {
                expectedDigest = digest
            } else {
                throw UpdateManifestError.manifestMissing
            }

            var asset = package.archive
            asset.sha256 = expectedDigest
            updateDownloadPhase = .downloading(UpdateDownloadProgress(
                receivedBytes: 0,
                expectedBytes: package.archive.byteCount
            ))

            _ = try await UpdateDownloader().download(asset, to: archive) { progress in
                guard throttle.shouldReport(progress) else { return }
                Task { @MainActor [weak self] in
                    // A late callback must not overwrite the result of a
                    // download that has already finished.
                    guard let self, case .downloading = self.updateDownloadPhase else { return }
                    self.updateDownloadPhase = .downloading(progress)
                }
            }

            try Task.checkCancellation()
            updateDownloadPhase = .verifying

            let installer = UpdateInstaller()
            let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
            let bundle = try await installer.unpack(archive: archive, into: expanded)
            try await installer.verify(stagedBundle: bundle, version: package.version, team: team)

            guard !Task.isCancelled else { return }
            updateDownloadPhase = .ready(stagedBundle: bundle, version: package.version)
            AppLog.shared.record(
                .info,
                "更新 \(package.version) 已下载并通过校验，等待用户确认安装",
                category: "update"
            )
        } catch is CancellationError {
            updateDownloadPhase = .idle
        } catch let error as UpdateDownloadError {
            if case .cancelled = error {
                updateDownloadPhase = .idle
            } else {
                updateDownloadPhase = .failed(error.errorDescription ?? L.t("下载失败。"))
                AppLog.shared.record(.warning, "更新下载失败：\(error.errorDescription ?? "")", category: "update")
            }
        } catch let error as UpdateManifestError {
            updateDownloadPhase = .failed(error.errorDescription ?? L.t("发布清单校验失败。"))
            AppLog.shared.record(.warning, "发布清单校验失败：\(error.errorDescription ?? "")", category: "update")
        } catch let error as UpdateInstallError {
            updateDownloadPhase = .failed(error.errorDescription ?? L.t("更新包校验失败。"))
            AppLog.shared.record(.warning, "更新包校验失败：\(error.errorDescription ?? "")", category: "update")
        } catch {
            updateDownloadPhase = .failed(error.localizedDescription)
            AppLog.shared.record(.warning, "更新处理失败：\(error.localizedDescription)", category: "update")
        }
    }

    /// Hands the swap to a helper that waits for this process to exit.
    func installUpdateAndRelaunch() {
        guard case .ready(let stagedBundle, let version) = updateDownloadPhase else { return }
        let destination = Bundle.main.bundleURL
        let helper = UpdateInstaller.updatesDirectory().appendingPathComponent("install.sh")
        do {
            _ = try UpdateInstaller().install(
                stagedBundle: stagedBundle,
                destination: destination,
                helper: helper,
                relaunch: true
            )
            updateDownloadPhase = .installing
            AppLog.shared.record(
                .info,
                "已启动安装助手，退出后替换 \(destination.path) 为 \(version)",
                category: "update"
            )
            NSApp.terminate(nil)
        } catch let error as UpdateInstallError {
            updateDownloadPhase = .failed(error.errorDescription ?? L.t("无法启动安装。"))
            AppLog.shared.record(.error, "安装更新失败：\(error.errorDescription ?? "")", category: "update")
        } catch {
            updateDownloadPhase = .failed(error.localizedDescription)
            AppLog.shared.record(.error, "安装更新失败：\(error.localizedDescription)", category: "update")
        }
    }

    private var lastUpdateCheck: Date? {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.lastUpdateCheckKey)
            return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.lastUpdateCheckKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastUpdateCheckKey)
            }
        }
    }
}
