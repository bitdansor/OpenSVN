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

    let taskCenter = TaskCenter()
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
        bookmarks = repositoryStore.load()
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
                    timeout: settings.operationTimeout
                )
            )
            self.service = service
            self.installation = await service.installation
            self.startupError = nil
            for session in sessions.values {
                session.attach(service: service, taskCenter: taskCenter)
            }
        } catch let error as SVNError {
            self.service = nil
            self.installation = nil
            self.startupError = error
        } catch {
            self.service = nil
            self.installation = nil
            self.startupError = SVNError(code: .unknown, message: error.localizedDescription)
        }
    }

    func apply(settings newValue: AppSettings) async {
        settings = newValue
        newValue.save()
        for session in sessions.values {
            session.updateTimeout(newValue.operationTimeout)
        }
        await buildService()
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
            onCredentialRequired: { [weak self] host in
                await self?.requestCredential(host: host)
            }
        )
        sessions[id] = session
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
