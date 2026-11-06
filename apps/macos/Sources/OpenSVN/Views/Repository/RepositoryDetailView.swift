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
    @Bindable var session: RepositorySession
    @State private var tab: RepositoryTab = .changes
    @State private var showingMerge = false
    @State private var showingSwitch = false
    @State private var showingDepth = false
    @State private var showingPatch = false

    var body: some View {
        // No band above the content. A 37 pt strip holding the section switcher
        // pushed this column's first row 22 pt below the sidebar's, which made
        // the two halves of the window look like two different layouts stuck
        // together. The switcher lives in the toolbar instead, the way the
        // section switcher does in every other macOS client of this kind, and
        // both columns now start directly under the toolbar.
        //
        // A plain `.frame(maxHeight: .infinity)` is not enough here: the file
        // list inside would size itself from its content, report a much taller
        // ideal height than the window, and scroll to a position that leaves
        // only the tail of the list visible. Giving the column its measured size
        // makes the list a bounded scroll view again.
        //
        // The sheets and dialogs are applied by the modifiers below rather than
        // inline: with them in the same expression the type checker gave up
        // ("unable to type-check this expression in reasonable time") on Swift
        // 6.1, which is the toolchain CI pins. Each piece is now inferred on its
        // own.
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The working copy's identity lives in the window chrome, where the name
        // of the thing you are looking at belongs. The path is not repeated here:
        // the sidebar row already carries it on its second line.
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .modifier(DetailDocumentSheets(session: session))
        .modifier(DetailBranchSheets(
            session: session,
            showingMerge: $showingMerge,
            showingSwitch: $showingSwitch
        ))
        .modifier(DetailWorkingCopySheets(
            session: session,
            showingDepth: $showingDepth,
            showingPatch: $showingPatch
        ))
        .modifier(DetailAlerts(session: session))
        .modifier(DetailBranchDialogs(session: session, tab: $tab))
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Trailing, next to the actions it switches between. Leading (`nav`)
        // puts the tabs before the window title, which makes the title read
        // like a caption for them.
        ToolbarItem(placement: .primaryAction) {
            sectionPicker
        }
        ToolbarItemGroup(placement: .primaryAction) {
            refreshButton
            updateButton
            cleanupButton
            // Branch operations live in a menu rather than three separate
            // buttons: they are used in bursts (merge something, check what is
            // left, maybe switch), not on every visit.
            BranchMenu(
                session: session,
                showingMerge: $showingMerge,
                showingSwitch: $showingSwitch
            )
            WorkingCopyMenu(
                session: session,
                showingDepth: $showingDepth,
                showingPatch: $showingPatch
            )
        }
    }

    private var sectionPicker: some View {
        Picker("分区", selection: $tab) {
            ForEach(RepositoryTab.allCases) { candidate in
                Label(candidate.title, systemImage: candidate.systemImage)
                    .tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("切换工作副本的分区")
    }

    @ViewBuilder
    private var refreshButton: some View {
        Button {
            Task { await session.refresh() }
        } label: {
            // The spinner used to live in the band that is gone; without it a
            // slow re-read looks like a click that did nothing.
            if session.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
        .keyboardShortcut("r", modifiers: .command)
        .help("重新读取工作副本状态")
    }

    private var updateButton: some View {
        Button {
            Task { await session.requestUpdate() }
        } label: {
            Label("更新", systemImage: "arrow.down.circle")
        }
        .help("先看服务器上有什么变化，再决定是否更新")
    }

    private var cleanupButton: some View {
        Button {
            Task { await session.cleanup() }
        } label: {
            Label("清理", systemImage: "bandage")
        }
        .help("清理内部锁（svn cleanup）")
    }

    /// Window subtitle: which revision this working copy is at, and who left it
    /// there.
    ///
    /// The path is deliberately absent — the sidebar row carries it, and a
    /// subtitle that long competes with the section switcher for the same
    /// toolbar space. Connection problems stay out of it too: the sidebar row
    /// already carries that badge.
    private var subtitle: String {
        var parts: [String] = []
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

/// 合并 / 切换分支 / 合并记录, grouped into one toolbar menu.
private struct BranchMenu: View {
    @Bindable var session: RepositorySession
    @Binding var showingMerge: Bool
    @Binding var showingSwitch: Bool

    var body: some View {
        Menu {
            Button {
                showingMerge = true
            } label: {
                Label("合并…", systemImage: "arrow.triangle.branch")
            }
            Button {
                showingSwitch = true
            } label: {
                Label("切换分支…", systemImage: "arrow.triangle.swap")
            }
            Divider()
            Button {
                session.openMergeInfo()
            } label: {
                Label("合并记录…", systemImage: "arrow.triangle.merge")
            }
        } label: {
            Label("分支", systemImage: "arrow.triangle.branch")
        }
        .help("合并、切换分支、查看合并记录")
    }
}

/// 改深度 / 应用补丁, in one menu.
///
/// Neither belongs in the branch menu: depth is about *how much* of the tree is
/// on disk, and a patch is an edit applied to it. Both are also rare enough that
/// a permanent toolbar button would be noise, and both act on the working copy
/// as a whole rather than on a selection, which is what the selection-driven
/// buttons next to it do.
private struct WorkingCopyMenu: View {
    @Bindable var session: RepositorySession
    @Binding var showingDepth: Bool
    @Binding var showingPatch: Bool

    var body: some View {
        Menu {
            Button {
                showingDepth = true
            } label: {
                Label("改深度…", systemImage: "square.stack.3d.down.right")
            }
            Button {
                showingPatch = true
            } label: {
                Label("应用补丁…", systemImage: "doc.badge.plus")
            }
        } label: {
            Label("工作副本", systemImage: "ellipsis.circle")
        }
        .help("改变稀疏工作副本的深度、应用补丁")
    }
}

// MARK: - Sheets
/// The sheets that describe one path or one read-only report.
private struct DetailDocumentSheets: ViewModifier {
    @Bindable var session: RepositorySession

    func body(content: Content) -> some View {
        content
            // Attached here rather than in one tab: properties belong to a
            // path, not to a page, and opening the sheet must not depend on
            // which tab is up.
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
            .sheet(item: $session.mergeInfoSnapshot) { _ in
                MergeInfoSheet(session: session)
            }
    }
}

/// The two sheets that change the working copy's branch.
private struct DetailBranchSheets: ViewModifier {
    @Bindable var session: RepositorySession
    @Binding var showingMerge: Bool
    @Binding var showingSwitch: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingMerge) {
                MergeSheet(session: session)
            }
            .sheet(isPresented: $showingSwitch) {
                SwitchSheet(session: session)
            }
    }
}

/// The two sheets that act on the working copy itself rather than on a branch.
private struct DetailWorkingCopySheets: ViewModifier {
    @Bindable var session: RepositorySession
    @Binding var showingDepth: Bool
    @Binding var showingPatch: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingDepth) {
                DepthSheet(session: session)
            }
            .sheet(isPresented: $showingPatch) {
                PatchSheet(session: session)
            }
    }
}

// MARK: - Dialogs

/// Failures and conflict reports, which carry a message worth reading.
private struct DetailAlerts: ViewModifier {
    @Bindable var session: RepositorySession

    func body(content: Content) -> some View {
        content
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
                Text(presented.detail.isEmpty
                     ? presented.title
                     : "\(presented.title)\n\n\(presented.detail)")
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
    }
}

/// The pending-confirmation prompt and the merge/switch report.
private struct DetailBranchDialogs: ViewModifier {
    @Bindable var session: RepositorySession
    @Binding var tab: RepositoryTab

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                session.confirmation?.title ?? "确认操作",
                isPresented: Binding(
                    get: { session.confirmation != nil },
                    set: { if !$0 { session.confirmation = nil } }
                ),
                presenting: session.confirmation
            ) { confirmation in
                Button(
                    confirmation.confirmLabel,
                    role: confirmation.isDestructive ? .destructive : nil
                ) {
                    session.confirmPending()
                }
                Button("取消", role: .cancel) { session.confirmation = nil }
            } message: { confirmation in
                Text(confirmation.message)
            }
            // A merge or a switch changes many files at once. The alert is where
            // the counts and the "what to do next" sentence live, because a
            // task-centre row is too small to hold them and too easy to miss.
            .alert(
                session.branchReport?.title ?? "分支操作",
                isPresented: Binding(
                    get: { session.branchReport != nil },
                    set: { if !$0 { session.branchReport = nil } }
                ),
                presenting: session.branchReport
            ) { report in
                if report.hasConflicts {
                    Button("查看冲突") {
                        tab = .changes
                        session.branchReport = nil
                    }
                }
                Button("好", role: .cancel) { session.branchReport = nil }
            } message: { report in
                Text(report.message)
            }
    }
}
