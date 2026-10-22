import SwiftUI
import OpenSVNCore

@main
struct OpenSVNApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("OpenSVN") {
            MainWindowView()
                .environment(appState)
                .frame(minWidth: 1040, minHeight: 680)
                .task { await appState.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加工作副本…") {
                    appState.presentAddWorkingCopyPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("检出仓库…") {
                    appState.showingCheckoutSheet = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("仓库") {
                Button("刷新状态") {
                    if let session = appState.selectedSession {
                        Task { await session.refresh() }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("更新") {
                    if let session = appState.selectedSession {
                        Task { await session.requestUpdate() }
                    }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Divider()

                Button("清理工作副本") {
                    if let session = appState.selectedSession {
                        Task { await session.cleanup() }
                    }
                }
            }
            CommandMenu("任务") {
                Button("任务中心…") { appState.showingTaskCenter = true }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("取消全部任务") { appState.taskCenter.clear() }
            }
            CommandGroup(replacing: .help) {
                Button("试一次三方合并…") { appState.showingDemoSheet = true }
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
