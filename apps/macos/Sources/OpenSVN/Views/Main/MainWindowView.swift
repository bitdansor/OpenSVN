import SwiftUI
import OpenSVNCore

/// Root layout: repositories on the left, the selected working copy on the right.
struct MainWindowView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            if let session = appState.selectedSession {
                RepositoryDetailView(session: session)
                    .id(session.id)
            } else {
                WelcomeView()
            }
        }
        .navigationTitle(appState.selectedBookmark?.name ?? "OpenSVN")
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
                    Label("检出", systemImage: "arrow.down.circle")
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
            Button("打开设置") { appState.showingSettings = true }
            Button("好", role: .cancel) { appState.startupError = nil }
        } message: { error in
            Text(error.errorDescription ?? error.message)
        }
        .sheet(isPresented: $appState.showingSettings) {
            SettingsView()
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
