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
                        // The "refreshed at HH:MM" caption used to sit in the tab
                        // band; the band is gone, and this is where a fact about
                        // the working copy belongs.
                        row("最后刷新", session.lastRefreshedAt.map(RelativeTime.absolute) ?? "—")
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
                        Task { await session.requestUpdate() }
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
                    Button {
                        promptRelocate()
                    } label: {
                        Label("切换仓库地址…", systemImage: "arrow.triangle.swap")
                    }
                    .help("svn relocate：仓库换了地址（协议/主机/路径）但内容还是同一个")
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A URL edit needs a text field, and `NSAlert` is the shortest path to one
    /// that blocks until answered.
    private func promptRelocate() {
        let alert = NSAlert()
        alert.messageText = "切换仓库地址"
        alert.informativeText = "只用于仓库换了地址但内容没变的情况（换协议、换主机、换路径）。换到另一个仓库会被 svn 拒绝。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = session.info?.url ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "切换")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        Task { await session.relocate(to: url) }
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
