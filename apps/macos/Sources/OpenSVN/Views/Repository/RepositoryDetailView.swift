import AppKit
import SwiftUI
import OpenSVNCore

enum RepositoryTab: String, CaseIterable, Identifiable {
    case changes
    case commit
    case history
    case diff
    case overview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changes: return "变更"
        case .commit: return "提交"
        case .history: return "历史"
        case .diff: return "差异"
        case .overview: return "信息"
        }
    }

    var systemImage: String {
        switch self {
        case .changes: return "list.bullet.rectangle"
        case .commit: return "arrow.up.doc"
        case .history: return "clock.arrow.circlepath"
        case .diff: return "plus.forwardslash.minus"
        case .overview: return "info.circle"
        }
    }
}

struct RepositoryDetailView: View {
    @Environment(AppState.self) private var appState
    @Bindable var session: RepositorySession
    @State private var tab: RepositoryTab = .changes
    @State private var showingTaskCenter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(RepositoryTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await session.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("重新读取工作副本状态")

                Button {
                    Task { await session.update() }
                } label: {
                    Label("更新", systemImage: "arrow.down.circle")
                }
                .help("svn update")

                Button {
                    Task { await session.cleanup() }
                } label: {
                    Label("清理", systemImage: "bandage")
                }
                .help("清理内部锁（svn cleanup）")
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { session.presentedError != nil },
                set: { if !$0 { session.presentedError = nil } }
            ),
            presenting: session.presentedError
        ) { _ in
            Button("好", role: .cancel) { session.presentedError = nil }
        } message: { presented in
            Text(presented.detail.isEmpty ? presented.title : "\(presented.title)\n\n\(presented.detail)")
        }
        .alert(
            session.resolveReport?.title ?? "解决冲突",
            isPresented: Binding(
                get: { session.resolveReport != nil },
                set: { if !$0 { session.dismissResolveReport() } }
            ),
            presenting: session.resolveReport
        ) { report in
            if let directory = report.backupDirectory {
                Button("在 Finder 中显示备份") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                    session.dismissResolveReport()
                }
            }
            Button("好", role: .cancel) { session.dismissResolveReport() }
        } message: { report in
            Text(report.message)
        }
        .confirmationDialog(
            session.confirmation?.title ?? "确认操作",
            isPresented: Binding(
                get: { session.confirmation != nil },
                set: { if !$0 { session.confirmation = nil } }
            ),
            presenting: session.confirmation
        ) { confirmation in
            Button(confirmation.confirmLabel, role: confirmation.isDestructive ? .destructive : nil) {
                session.confirmPending()
            }
            Button("取消", role: .cancel) { session.confirmation = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .task {
            if session.status == nil {
                await session.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName)
                    .font(.title3.weight(.semibold))
                Text((session.bookmark.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let info = session.info {
                    Text("r\(info.revision.map(String.init) ?? "?")")
                        .font(.system(.body, design: .monospaced))
                    if let author = info.lastChangedAuthor {
                        Text("最后修改：\(author)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if session.isLoading {
                    ProgressView().controlSize(.small)
                }
                if let refreshed = session.lastRefreshedAt {
                    Text("刷新于 \(refreshed.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .changes:
            ChangesView(session: session, tab: $tab)
        case .commit:
            CommitView(session: session)
        case .history:
            HistoryView(session: session, tab: $tab)
        case .diff:
            DiffView(session: session)
        case .overview:
            RepositoryOverviewView(session: session)
        }
    }
}
