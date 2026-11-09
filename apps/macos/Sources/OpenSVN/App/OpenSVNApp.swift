import SwiftUI
import OpenSVNCore

@main
struct OpenSVNApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        // An id lets the "新建窗口" command open another instance of this scene.
        // All windows share the same AppState (bookmarks, sessions, task center),
        // so opening a second window never re-reads or resets existing data.
        WindowGroup("OpenSVN", id: "main") {
            MainWindowView()
                .environment(appState)
                .frame(minWidth: 1040, minHeight: 680)
                // A new identity rebuilds the window's whole view tree, which is
                // what makes every literal inside it re-resolve. It sits before
                // `.task` so the rebuild does not restart the launch work; the
                // task's own view identity is unchanged.
                .id(appState.interfaceLanguage)
                .task { await appState.startOnce() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            // The conventional place for this item: right under 关于 OpenSVN.
            CommandGroup(after: .appInfo) {
                Button(L.t("检查更新…")) {
                    Task { await appState.checkForUpdates(explicitlyRequested: true) }
                }
                .disabled(appState.isCheckingForUpdates)
            }
            // Appending (rather than replacing) keeps the system "新建窗口" ⌘N
            // item, which is what opens another window of the WindowGroup.
            CommandGroup(after: .newItem) {
                Button(L.t("添加工作副本…")) {
                    appState.presentAddWorkingCopyPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(L.t("检出仓库…")) {
                    appState.showingCheckoutSheet = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                // Browsing a repository costs no working copy, so it belongs
                // next to the two actions that do create one — not hidden
                // behind a checkbox in a checkout dialog.
                Button(L.t("只看仓库（不检出）…")) {
                    appState.promptForRepositoryBookmark()
                }
            }
            CommandMenu(L.t("仓库")) {
                Button(L.t("刷新状态")) {
                    if let session = appState.selectedSession {
                        Task { await session.refresh() }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(L.t("更新")) {
                    if let session = appState.selectedSession {
                        Task { await session.requestUpdate() }
                    }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Divider()

                Button(L.t("清理工作副本")) {
                    if let session = appState.selectedSession {
                        Task { await session.cleanup() }
                    }
                }
            }
            CommandMenu(L.t("任务")) {
                Button(L.t("任务中心…")) { appState.showingTaskCenter = true }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button(L.t("取消全部任务")) { appState.taskCenter.clear() }
            }
            CommandGroup(replacing: .help) {
                Button(L.t("试一次三方合并…")) { appState.showingDemoSheet = true }
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
                .id(appState.interfaceLanguage)
        }
    }
}
