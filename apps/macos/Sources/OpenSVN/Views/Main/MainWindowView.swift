import SwiftUI
import OpenSVNCore

/// Root layout: repositories on the left, the selected working copy on the right.
struct MainWindowView: View {
    @Environment(AppState.self) private var appState

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
        .animation(.easeOut(duration: 0.18), value: showsRecoveryBanner)
        .toolbar {
            // "Add a working copy" and "check out" live in the sidebar footer,
            // not here. Both of them add a row to the list below, and the list
            // is where the user looks for them; a second copy in the toolbar
            // put the same two glyphs on screen twice, which reads as four
            // different commands instead of two. The File menu still offers
            // both, because menu equivalents are how a Mac app is expected to
            // behave rather than a competing control.
            ToolbarItemGroup(placement: .primaryAction) {
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
            Button("打开设置") { appState.showingSettings = true }
            Button("好", role: .cancel) { appState.startupError = nil }
        } message: { error in
            Text(error.errorDescription ?? error.message)
        }
        .sheet(isPresented: $appState.showingSettings) {
            SettingsView()
                .environment(appState)
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
