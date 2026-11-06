import AppKit
import OpenSVNCore
import SwiftUI

/// Root layout: repositories on the left, the selected working copy on the right.
struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingExtensionsSettings = false
    @State private var quickLookURL: URL?

    /// `safeAreaInset` on a `NavigationSplitView` does not reserve space here:
    /// both columns keep their own scroll views and the inset view is painted
    /// over them. Wrapping the whole split view in a `VStack` is worse — the split
    /// view then reports its own ideal height (1737 pt in practice) and overflows
    /// the window, pushing the sidebar and the file list out of view. So the
    /// banner lives inside the *detail* column, where a plain `VStack` behaves.
    private var showsRecoveryBanner: Bool {
        !appState.recoveryItems.isEmpty || appState.journalQuarantineURL != nil
    }

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if showsRecoveryBanner {
                    RecoveryBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let session = appState.selectedSession {
                    RepositoryDetailView(session: session)
                        .id(session.id)
                } else if let browser = appState.selectedBrowser {
                    // A repository bookmark has no working copy, so it gets the
                    // browser rather than a detail view with five disabled tabs.
                    RepositoryBrowserView(browser: browser)
                        .id(browser.id)
                } else {
                    WelcomeView()
                }
            }
            // The content column puts its own toolbar background back, because
            // the window-level one is off: content is laid out under the titlebar
            // here, and without a background a long list scrolled upwards shows
            // its rows behind the title text. It costs nothing in alignment — the
            // column divider sits at the same x above and below the toolbar.
            // Finder drops are handled on the Changes page itself (see
            // `ChangesView`): attaching a second `onDrop` here would risk two
            // confirmations for one drop. The quick-actions toolbar menu stays
            // as the window-level complement.
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .navigationTitle(appState.selectedBookmark?.name ?? "OpenSVN")
        // Off for the window, so the sidebar's material runs all the way to the
        // top edge (behind the traffic lights) and the column divider is a single
        // line from y=0 down, with no step where the toolbar ends.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .animation(.easeOut(duration: 0.18), value: showsRecoveryBanner)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.presentAddWorkingCopyPanel()
                } label: {
                    Label("添加工作副本", systemImage: "folder.badge.plus")
                }
                .help("添加一个已存在的工作副本")

                Button {
                    appState.showingCheckoutSheet = true
                } label: {
                    Label("检出", systemImage: "square.and.arrow.down")
                }
                .help("从仓库检出新的工作副本")

                Button {
                    appState.showingTaskCenter = true
                } label: {
                    Label("任务", systemImage: appState.taskCenter.runningCount > 0
                          ? "arrow.triangle.2.circlepath.circle.fill"
                          : "list.bullet.rectangle")
                }
                .help("任务中心")

                quickActionsMenu
            }
        }
        .sheet(isPresented: $appState.showingCheckoutSheet) {
            CheckoutSheet()
                .environment(appState)
        }
        .sheet(isPresented: $appState.showingTaskCenter) {
            TaskCenterView()
                .environment(appState)
        }
        .sheet(item: $appState.authPrompt) { prompt in
            CredentialSheet(host: prompt.host, errorMessage: prompt.errorMessage)
                .environment(appState)
        }
        .alert(
            "无法使用 SVN",
            isPresented: Binding(
                get: { appState.startupError != nil },
                set: { if !$0 { appState.startupError = nil } }
            ),
            presenting: appState.startupError
        ) { _ in
            // Settings is a scene with its own window (⌘,). Opening it as a
            // sheet would put the fix for the problem behind a dialog that
            // blocks the window describing it.
            Button("打开设置…") { openSettings() }
            Button("好", role: .cancel) { appState.startupError = nil }
        } message: { error in
            Text(error.errorDescription ?? error.message)
        }
        .sheet(isPresented: $appState.showingDemoSheet) {
            DemoWorkspaceSheet()
                .environment(appState)
        }
        .sheet(isPresented: $appState.showingNewRepositorySheet) {
            NewLocalRepositorySheet()
                .environment(appState)
        }
        .sheet(isPresented: $appState.showingUpdateSheet) {
            UpdateCheckSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showingExtensionsSettings) {
            UIExtensionsSettingsView()
        }
        .sheet(isPresented: Binding(
            get: { quickLookURL != nil },
            set: { if !$0 { quickLookURL = nil } }
        )) {
            if let quickLookURL {
                QuickLookSheet(url: quickLookURL)
            }
        }
        // Ask for notification authorization once and prime the status snapshot
        // so tasks that finished before this window appeared stay silent.
        .task {
            await MainActor.run {
                TaskNotificationBridge.shared.requestAuthorizationIfNeeded()
                TaskNotificationBridge.shared.prime(appState.taskCenter.items)
            }
        }
        .onChange(of: appState.taskCenter.items.map(\.status)) { _, _ in
            Task { @MainActor in
                TaskNotificationBridge.shared.process(appState.taskCenter.items)
            }
        }
    }

    // MARK: - Quick actions

    /// Acts on the files selected in the Changes list (or on the working copy
    /// itself when nothing is selected). Kept here so every tab can reach these
    /// commands without each of them owning a menu.
    private var quickActionsMenu: some View {
        Menu {
            Button("快速查看") {
                if let url = selectedFileURLs.first { quickLookURL = url }
            }
            .disabled(selectedFileURLs.isEmpty)

            Button("在终端打开") {
                if let directory = terminalDirectory {
                    FileActions.openInTerminal(directory)
                }
            }
            .disabled(terminalDirectory == nil)

            Button("在 Finder 中显示") {
                FileActions.revealInFinder(finderURLs)
            }
            .disabled(finderURLs.isEmpty)

            Divider()

            Button("导出所选…") { exportSelected() }
                .disabled(appState.selectedSession == nil)

            Button("新建本地仓库…") {
                appState.showingNewRepositorySheet = true
            }
            .help("用 svnadmin 在这台 Mac 上创建仓库，不需要服务器")

            Button("用外部工具解决冲突…") {
                if let session = appState.selectedSession,
                   let entry = session.conflictedEntries.first {
                    session.resolveWithExternalTool(entry)
                }
            }
            .disabled(appState.selectedSession?.conflictedEntries.isEmpty ?? true)

            Divider()

            Button("新建窗口") { openWindow(id: "main") }
            Button("扩展设置…") { showingExtensionsSettings = true }
        } label: {
            Label("快捷操作", systemImage: "ellipsis.circle")
        }
        .help("快速查看、在终端打开、导出、外部合并、扩展设置与新建窗口")
    }

    private var selectedFileURLs: [URL] {
        guard let session = appState.selectedSession else { return [] }
        return session.selectedPaths.compactMap { raw in
            let url = raw.hasPrefix("/")
                ? URL(fileURLWithPath: raw)
                : session.path.appendingPathComponent(raw)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private var terminalDirectory: URL? {
        if let first = selectedFileURLs.first {
            return first.deletingLastPathComponent()
        }
        return appState.selectedSession?.path
    }

    private var finderURLs: [URL] {
        if !selectedFileURLs.isEmpty { return selectedFileURLs }
        return [appState.selectedSession?.path].compactMap { $0 }
    }

    /// `svn export` needs a destination directory, which a Finder drop cannot
    /// name; the panel asks for one explicitly and reuses the existing service.
    private func exportSelected() {
        guard let session = appState.selectedSession else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到此处"
        panel.message = "选择目标目录：svn export 不会覆盖已有文件"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let paths = Array(session.selectedPaths)
        Task { await session.export(to: directory, paths: paths) }
    }
}

private struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("OpenSVN")
                .font(.largeTitle.weight(.semibold))
            Text("选择左侧的工作副本，或添加一个新的。")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("添加工作副本…") { appState.presentAddWorkingCopyPanel() }
                Button("检出仓库…") { appState.showingCheckoutSheet = true }
                    .buttonStyle(.borderedProminent)
            }

            Button("在这台 Mac 上新建一个本地仓库（不需要服务器）") {
                appState.showingNewRepositorySheet = true
            }
            .buttonStyle(.link)
            .font(.callout)

            Button("想先试试三方合并？用一份带冲突的演示数据") {
                appState.showingDemoSheet = true
            }
            .buttonStyle(.link)
            .font(.callout)

            if let installation = appState.installation {
                Text("使用 svn \(installation.version.description) · \(installation.source.displayName)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if appState.isStarting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
