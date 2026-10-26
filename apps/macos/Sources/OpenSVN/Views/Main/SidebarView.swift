import AppKit
import SwiftUI
import OpenSVNCore

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedBookmarkID) {
            if !appState.workingCopyBookmarks.isEmpty {
                Section("工作副本") {
                    ForEach(appState.workingCopyBookmarks) { bookmark in
                        RepositoryRow(
                            bookmark: bookmark,
                            session: appState.sessions[bookmark.id],
                            browser: nil
                        )
                        .tag(bookmark.id)
                        .contextMenu {
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([bookmark.url])
                            }
                            Button("检查连接") {
                                Task { await appState.session(for: bookmark.id)?.probeConnection() }
                            }
                            Divider()
                            Button("移除", role: .destructive) {
                                appState.removeRepository(id: bookmark.id)
                            }
                        }
                    }
                }
            }

            if !appState.repositoryBookmarks.isEmpty {
                Section("仓库") {
                    ForEach(appState.repositoryBookmarks) { bookmark in
                        RepositoryRow(
                            bookmark: bookmark,
                            session: nil,
                            browser: appState.browsers[bookmark.id]
                        )
                        .tag(bookmark.id)
                        .contextMenu {
                            Button("复制地址") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    bookmark.repositoryURL ?? "",
                                    forType: .string
                                )
                            }
                            Divider()
                            Button("移除", role: .destructive) {
                                appState.removeRepository(id: bookmark.id)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if appState.bookmarks.isEmpty {
                ContentUnavailableView {
                    Label("没有工作副本", systemImage: "tray")
                } description: {
                    Text("添加一个已存在的工作副本，或从仓库检出。")
                } actions: {
                    Button("添加…") { appState.presentAddWorkingCopyPanel() }
                    Button("检出…") { appState.showingCheckoutSheet = true }
                    Button("只看仓库…") { appState.promptForRepositoryBookmark() }
                }
            }
        }
        // No command buttons in this strip. A row of 16pt glyphs tucked into
        // the bottom corner of the sidebar is where a command goes to be
        // missed: adding a working copy, checking one out and browsing a
        // repository all belong in the toolbar with the rest of the window's
        // actions. What is left here reports something instead of doing
        // something — which svn this app is actually running.
        .safeAreaInset(edge: .bottom) {
            if let installation = appState.installation {
                HStack(spacing: 0) {
                    Spacer()
                    Text("svn \(installation.version.description)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("当前使用的 svn：\(installation.executableURL.path)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }
}

private struct RepositoryRow: View {
    let bookmark: RepositoryBookmark
    let session: RepositorySession?
    let browser: RepositoryBrowser?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: bookmark.isRepository ? "shippingbox" : "externaldrive.badge.checkmark")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.name)
                    .lineLimit(1)
                Text(abbreviatedPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let count = session?.changedEntries.count, count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
            if let conflicts = session?.conflictedEntries.count, conflicts > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("\(conflicts) 个冲突")
            }
            // Only problems get an icon. A green dot on every row would be
            // noise; a missing icon means "nothing to report".
            if let connection = session?.connection, connection.isProblem {
                Image(systemName: connection.systemImage)
                    .foregroundStyle(connection.isAuthenticationProblem ? Color.orange : Color.red)
                    .help(connection.summary)
            }
        }
        .padding(.vertical, 2)
    }

    private var abbreviatedPath: String {
        if bookmark.isRepository {
            return URL(string: bookmark.repositoryURL ?? "")?.host
                ?? bookmark.repositoryURL
                ?? ""
        }
        return (bookmark.path as NSString).abbreviatingWithTildeInPath
    }
}
