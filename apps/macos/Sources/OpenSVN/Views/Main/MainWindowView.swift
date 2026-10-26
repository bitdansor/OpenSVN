import SwiftUI
import OpenSVNCore

/// Root layout: repositories on the left, the selected working copy on the right.
struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

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

        NavigationSplitView {
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
        }
        .navigationTitle(appState.selectedBookmark?.name ?? "OpenSVN")
        // One material across the whole toolbar, so the two columns meet on one
        // line at the top.
        //
        // By default the toolbar draws a sidebar-shaped background that stops
        // 2 pt short of the sidebar column, while the divider between the
        // columns only starts below the toolbar. Measured on screen: the colour
        // change at the top sat at x=496 and the divider below it at x=500, so
        // the seam stepped sideways exactly at the toolbar's bottom edge.
        //
        // Painting the toolbar with a single material makes that top edge one
        // surface with nothing to line up against, and the divider simply begins
        // below it the way it does in Finder.
        //
        // It has to be a material, not `.hidden`: the content really does live
        // under the toolbar (AppKit insets it, the toolbar's background is what
        // hides it). Hiding the background let the split view's divider and its
        // drag zone reach up into the titlebar, so dragging the history
        // splitter painted a line across the toolbar icons and stole their
        // clicks.
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
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
