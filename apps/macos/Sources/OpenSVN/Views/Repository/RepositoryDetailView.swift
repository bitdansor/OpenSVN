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

    var body: some View {
        VStack(spacing: 0) {
            sectionBar
            Divider()

            // A plain `.frame(maxHeight: .infinity)` is not enough here: the file
            // list inside would size itself from its content, report a much taller
            // ideal height than the window, and scroll to a position that leaves
            // only the tail of the list visible. Giving the column its measured
            // size makes the list a bounded scroll view again.
            GeometryReader { proxy in
                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The working copy's identity lives in the window chrome, where the name
        // of the thing you are looking at belongs. Repeating it as a card above
        // the file list cost about ninety points of height and said nothing the
        // window title and the sidebar row had not already said.
        .navigationSubtitle(subtitle)
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
                    Task { await session.requestUpdate() }
                } label: {
                    Label("更新", systemImage: "arrow.down.circle")
                }
                .help("先看服务器上有什么变化，再决定是否更新")

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
        // Attached here rather than in one tab: properties belong to a path, not
        // to a page, and opening the sheet must not depend on which tab is up.
        .sheet(item: $session.propertyEditor) { _ in
            PropertyEditorView(session: session)
        }
        .sheet(item: $session.updatePreview) { _ in
            UpdatePreviewSheet(session: session)
        }
        .sheet(item: $session.blameState) { _ in
            BlameSheet(session: session)
        }
        .sheet(item: $session.externalsState) { _ in
            ExternalsSheet(session: session)
        }
        .task {
            if session.status == nil {
                await session.refresh()
            }
            session.startWatching()
            await session.probeConnection()
        }
        // The watcher holds an unretained pointer to itself and burns a file
        // descriptor; only the working copy on screen needs one.
        .onDisappear {
            session.stopWatching()
        }
    }

    /// One thin band: the section switcher on the left, the state of the last
    /// read on the right.
    ///
    /// Two stacked bars above the content (a title card, then a switcher) is one
    /// bar too many on a window that already names the working copy in its
    /// title bar. What is left here is the only thing that has to be visible at
    /// all times — which page you are on, and how old it is.
    private var sectionBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(RepositoryTab.allCases) { candidate in
                    Label(candidate.title, systemImage: candidate.systemImage)
                        .tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .fixedSize()

            Spacer(minLength: 8)

            if session.isLoading {
                ProgressView().controlSize(.small)
            }
            if let refreshed = session.lastRefreshedAt {
                Text("刷新于 \(refreshed.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("自动刷新会更新这个时间；⌘R 手动重读")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Window subtitle: where this working copy is, and which revision it is at.
    ///
    /// Connection problems stay out of it on purpose — the sidebar row already
    /// carries that badge, and a second copy of the same warning in the title
    /// bar only makes the chrome louder.
    private var subtitle: String {
        var parts = [(session.bookmark.path as NSString).abbreviatingWithTildeInPath]
        if let revision = session.info?.revision {
            parts.append("r\(revision)")
        }
        if let author = session.info?.lastChangedAuthor {
            parts.append(author)
        }
        return parts.joined(separator: " · ")
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
