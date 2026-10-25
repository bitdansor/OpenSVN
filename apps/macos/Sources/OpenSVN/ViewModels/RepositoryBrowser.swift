import Foundation
import Observation
import OpenSVNCore

/// A repository opened without a working copy.
///
/// Deliberately not a `RepositorySession`: that type is built around a local tree
/// — status, staging, diff against disk — and none of it applies here. What this
/// needs is a URL, a listing, and immediate commits, which is a different shape of
/// state rather than a subset of the other one.
@MainActor
@Observable
final class RepositoryBrowser: Identifiable {
    /// One pending remote write, shown as a sheet before it runs.
    struct ActionRequest: Identifiable {
        enum Kind: Equatable {
            case makeDirectory
            case tag
            case copy
            case move
            case delete
        }

        let id = UUID()
        var kind: Kind
        /// What the operation acts on (a copy source, a delete target).
        var sourceURL: String?
        /// Final URL for the new or moved path; the sheet edits the trailing name.
        var destination: String
        var message: String

        var isDestructive: Bool { kind == .delete }
        var needsMessage: Bool { true }

        var title: String {
            switch kind {
            case .makeDirectory: return "新建目录"
            case .tag: return "创建 tag"
            case .copy: return "复制到"
            case .move: return "移动到"
            case .delete: return "删除仓库路径"
            }
        }

        var confirmLabel: String {
            switch kind {
            case .makeDirectory: return "创建"
            case .tag: return "创建 tag"
            case .copy: return "复制"
            case .move: return "移动"
            case .delete: return "删除"
            }
        }
    }

    nonisolated let bookmark: RepositoryBookmark
    private(set) var service: SVNService?
    private var taskCenter: TaskCenter?
    private let onCredentialRequired: (@MainActor (String) async -> SVNCredential?)?

    /// Where the browser currently is.
    var location: RepositoryPath
    var listing: RepositoryListing?
    var isLoading = false
    var isPerforming = false
    var presentedError: String?
    var lastMessage: String?
    var revision: Int64?
    /// Non-nil while an action sheet is open.
    var actionRequest: ActionRequest?

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
        let start = bookmark.repositoryURL ?? ""
        self.location = RepositoryPath(url: start)
    }

    nonisolated var id: UUID { bookmark.id }
    var displayName: String { bookmark.name }

    func attach(service: SVNService?, taskCenter: TaskCenter?) {
        self.service = service
        self.taskCenter = taskCenter
    }

    // MARK: - Navigation

    func loadRoot() async {
        guard let service, let url = bookmark.repositoryURL, !url.isEmpty else { return }
        // `info` on a repository URL is what turns "some URL the user typed" into
        // "a directory inside a known repository": the root feeds the breadcrumb
        // and the UUID lets us notice the repository being recreated.
        if location.rootURL == nil {
            if let report = try? await service.info(at: url) {
                location = RepositoryPath(url: url, rootURL: report.primary?.repositoryRoot)
                revision = report.primary?.revision
            }
        }
        await refresh()
    }

    func refresh() async {
        guard let service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            listing = try await withAuthRetry { credential in
                try await service.list(at: location.url, credential: credential)
            }
            presentedError = nil
        } catch {
            presentedError = (error as? SVNError)?.message ?? error.localizedDescription
            listing = nil
        }
    }

    func navigate(into entry: RemoteEntry) async {
        guard entry.isDirectory else { return }
        location = location.appending(entry.name)
        listing = nil
        await refresh()
    }

    func navigate(to path: RepositoryPath) async {
        location = path
        listing = nil
        await refresh()
    }

    func goUp() async {
        guard let parent = location.parent() else { return }
        location = parent
        listing = nil
        await refresh()
    }

    // MARK: - Actions

    func beginMakeDirectory() {
        actionRequest = ActionRequest(
            kind: .makeDirectory,
            destination: location.url + "/",
            message: ""
        )
    }

    /// Tagging is `svn copy` with a convention: the destination lives under
    /// `tags/`. Offered as its own command because that convention is the whole
    /// reason people copy directories, and typing the URL by hand is where it
    /// goes wrong.
    func beginTag(from entry: RemoteEntry?) {
        let source = entry.map { location.appending($0.name).url } ?? location.url
        let name = entry?.name ?? location.lastComponent
        let tagBase = (location.rootURL ?? location.baseURL) + "/tags"
        actionRequest = ActionRequest(
            kind: .tag,
            sourceURL: source,
            destination: tagBase + "/" + name + "-tag",
            message: ""
        )
    }

    func beginCopy(of entry: RemoteEntry) {
        let source = location.appending(entry.name).url
        actionRequest = ActionRequest(
            kind: .copy,
            sourceURL: source,
            destination: location.url + "/" + entry.name + "-copy",
            message: ""
        )
    }

    func beginMove(of entry: RemoteEntry) {
        let source = location.appending(entry.name).url
        actionRequest = ActionRequest(
            kind: .move,
            sourceURL: source,
            destination: location.url + "/" + entry.name + "-moved",
            message: ""
        )
    }

    func beginDelete(_ entry: RemoteEntry) {
        actionRequest = ActionRequest(
            kind: .delete,
            sourceURL: location.appending(entry.name).url,
            destination: "",
            message: ""
        )
    }

    func cancelAction() {
        actionRequest = nil
    }

    /// Runs the pending action and refreshes the listing.
    ///
    /// Every one of these is a commit of its own — svn has no staging for URL
    /// targets — so success is reported with the revision it produced rather than
    /// with a "done" that hides what changed in history.
    func perform(_ request: ActionRequest) async {
        guard let service else { return }
        let destination = request.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        isPerforming = true
        defer { isPerforming = false }

        do {
            let commit: RemoteCommit
            switch request.kind {
            case .makeDirectory:
                guard !destination.isEmpty else { throw Self.missingTarget() }
                commit = try await withAuthRetry { credential in
                    try await service.makeDirectory(
                        at: destination,
                        message: message,
                        parents: true,
                        credential: credential
                    )
                }
            case .tag, .copy:
                guard let source = request.sourceURL, !destination.isEmpty else {
                    throw Self.missingTarget()
                }
                let parents = request.kind == .tag
                commit = try await withAuthRetry { credential in
                    try await service.copy(
                        from: source,
                        to: destination,
                        message: message,
                        parents: parents,
                        credential: credential
                    )
                }
            case .move:
                guard let source = request.sourceURL, !destination.isEmpty else {
                    throw Self.missingTarget()
                }
                commit = try await withAuthRetry { credential in
                    try await service.moveRemote(
                        from: source,
                        to: destination,
                        message: message,
                        credential: credential
                    )
                }
            case .delete:
                guard let source = request.sourceURL else { throw Self.missingTarget() }
                commit = try await withAuthRetry { credential in
                    try await service.deleteRemote(
                        at: source,
                        message: message,
                        confirmed: true,
                        credential: credential
                    )
                }
            }

            actionRequest = nil
            lastMessage = commit.revision.map { "\(commit.summary)，提交为 r\($0)" } ?? commit.summary
            await refresh()
        } catch {
            // The sheet stays open: a failed remote write is worth retrying with a
            // corrected path, and closing it would throw away what was typed.
            presentedError = (error as? SVNError)?.message ?? error.localizedDescription
        }
    }

    func dismissError() {
        presentedError = nil
    }

    func dismissLastMessage() {
        lastMessage = nil
    }

    // MARK: - Export

    /// Exports a directory to disk at the revision on screen.
    ///
    /// `export` rather than `checkout`: the result is a snapshot, not a working
    /// copy, which is what "give me what this tag looked like" actually asks for.
    func export(from url: String, to destination: URL, revision: Int64?) async {
        guard let service else { return }
        do {
            _ = try await withAuthRetry { credential in
                try await service.export(
                    from: url,
                    to: destination,
                    revision: revision,
                    credential: credential
                )
            }
            lastMessage = "已导出到 \(destination.path)"
        } catch {
            presentedError = (error as? SVNError)?.message ?? error.localizedDescription
        }
    }

    func exportCurrent(to destination: URL) async {
        await export(from: location.url, to: destination, revision: revision)
    }

    /// Uploads a local directory into the current repository directory.
    func importDirectory(from localPath: URL, name: String, message: String) async {
        guard let service else { return }
        let destination = location.url + "/" + name
        isPerforming = true
        defer { isPerforming = false }
        do {
            let commit = try await withAuthRetry { credential in
                try await service.importDirectory(
                    from: localPath,
                    to: destination,
                    message: message,
                    credential: credential
                )
            }
            lastMessage = commit.revision.map { "\(commit.summary)，提交为 r\($0)" } ?? commit.summary
            await refresh()
        } catch {
            presentedError = (error as? SVNError)?.message ?? error.localizedDescription
        }
    }

    // MARK: - Plumbing

    private static func missingTarget() -> SVNError {
        SVNError(code: .invalidInvocation, message: "目标路径不能为空")
    }

    private func withAuthRetry<T: Sendable>(
        _ operation: @MainActor (SVNCredential?) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(nil)
        } catch let error as SVNError where error.code.isAuthenticationRelated {
            guard let host = URL(string: location.url)?.host,
                  let provider = onCredentialRequired,
                  let fresh = await provider(host) else {
                throw error
            }
            return try await operation(fresh)
        }
    }
}
