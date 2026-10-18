import AppKit
import SwiftUI
import OpenSVNCore

struct RepositoryOverviewView: View {
    @Bindable var session: RepositorySession
    @State private var copying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let info = session.info {
                    card("仓库") {
                        row("URL", info.url, selectable: true)
                        row("仓库根", info.repositoryRoot ?? "—", selectable: true)
                        row("UUID", info.repositoryUUID ?? "—", selectable: true)
                    }

                    card("工作副本") {
                        row("路径", info.workingCopyRoot ?? session.bookmark.path)
                        row("当前修订", info.revision.map { "r\($0)" } ?? "—")
                        row("节点类型", info.kind.rawValue)
                        row("深度", info.depth ?? "—")
                        row("计划", info.schedule ?? "—")
                    }

                    card("最后修改") {
                        row("修订", info.lastChangedRevision.map { "r\($0)" } ?? "—")
                        row("作者", info.lastChangedAuthor ?? "—")
                        row("时间", RelativeTime.absolute(info.lastChangedDate))
                    }

                    if let lock = info.repositoryLock {
                        card("文件锁") {
                            row("持有者", lock.owner ?? "—")
                            row("说明", lock.comment ?? "—")
                            row("创建时间", RelativeTime.absolute(lock.createdAt))
                        }
                    }
                } else if session.isLoading {
                    ProgressView("正在读取信息…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ContentUnavailableView {
                        Label("暂无信息", systemImage: "info.circle")
                    } description: {
                        Text("刷新以读取工作副本信息。")
                    } actions: {
                        Button("刷新") { Task { await session.refresh() } }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await session.update() }
                    } label: {
                        Label("更新工作副本", systemImage: "arrow.down.circle")
                    }
                    Button {
                        Task { await session.cleanup() }
                    } label: {
                        Label("清理内部锁", systemImage: "bandage")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([session.path])
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    private func row(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(.callout)
            .lineLimit(2)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
