import AppKit
import SwiftUI
import OpenSVNCore

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedBookmarkID) {
            Section("工作副本") {
                ForEach(appState.bookmarks) { bookmark in
                    RepositoryRow(
                        bookmark: bookmark,
                        session: appState.sessions[bookmark.id]
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
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Button {
                    appState.presentAddWorkingCopyPanel()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("添加工作副本")

                Button {
                    appState.showingCheckoutSheet = true
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("检出仓库")

                Spacer()

                if let installation = appState.installation {
                    Text("svn \(installation.version.description)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

private struct RepositoryRow: View {
    let bookmark: RepositoryBookmark
    let session: RepositorySession?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.checkmark")
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
        (bookmark.path as NSString).abbreviatingWithTildeInPath
    }
}
