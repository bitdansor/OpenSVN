import AppKit
import SwiftUI
import OpenSVNCore

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var explicitPath = ""
    @State private var timeoutSeconds = AppSettings.defaultTimeout
    @State private var confirmDestructive = true
    @State private var logLevel: LogLevel = .info
    @State private var maxConcurrentWrites = AppSettings.defaultMaxConcurrentWrites
    @State private var autoRefresh = true
    @State private var previewBeforeUpdate = true
    @State private var externalDiffCommand = ""
    @State private var credentialScopes: [CredentialScope] = []
    @State private var statusMessage: String?
    @State private var showingClearConfirmation = false

    var body: some View {
        Form {
            Section("SVN 运行时") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("自定义 svn 可执行文件路径")
                        .font(.callout)
                    HStack {
                        TextField("留空则自动发现（应用内置 → PATH → 常见位置）", text: $explicitPath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseExecutable() }
                        if !explicitPath.isEmpty {
                            Button("清除") { explicitPath = "" }
                        }
                    }
                    Text("从 Finder 启动的应用不会继承 Homebrew 的 PATH，因此显式路径优先。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let installation = appState.installation {
                    LabeledContent("当前使用") {
                        Text("\(installation.executableURL.path) · \(installation.version.description) · \(installation.source.displayName)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                } else {
                    LabeledContent("当前使用") {
                        Text(appState.startupError?.message ?? "尚未检测")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("操作") {
                LabeledContent("单次操作超时") {
                    HStack {
                        TextField("秒", value: $timeoutSeconds, format: .number)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        Text("秒")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("危险操作前要求确认（还原、删除、覆盖式解决冲突）", isOn: $confirmDestructive)
                Text("确认在服务层强制执行，界面开关只决定是否提前展示预览。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LabeledContent("同时进行的写操作") {
                    HStack {
                        Stepper(
                            value: $maxConcurrentWrites,
                            in: AppSettings.maxConcurrentWritesRange
                        ) {
                            Text("\(maxConcurrentWrites) 个")
                                .monospacedDigit()
                        }
                    }
                }
                Text("限制的是不同工作副本之间的并行度。同一个工作副本上的两个写操作始终排队执行，这与上限无关。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("刷新与更新") {
                Toggle("自动刷新（监听文件变化）", isOn: $autoRefresh)
                Text("监听当前打开的工作副本，文件被外部编辑器改动后自动重读状态。.svn 内部变化被忽略（否则每次刷新都会触发下一次刷新），因此只在终端里改属性的情况需要手动刷新。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("更新前先查看服务器上的变更", isOn: $previewBeforeUpdate)
                Text("更新前读取一次远端状态，列出将新增 / 修改 / 删除的路径，并标出与本地未提交修改冲突的风险。代价是多一次网络往返。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("外部工具") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("外部 diff 命令")
                        .font(.callout)
                    HStack {
                        TextField("留空则使用内置差异视图", text: $externalDiffCommand)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseDiffCommand() }
                        if !externalDiffCommand.isEmpty {
                            Button("清除") { externalDiffCommand = "" }
                        }
                    }
                    Text("传给 `svn diff --diff-cmd`。应填一个包装脚本而不是 GUI 程序本身：svn 会等子进程退出，直接指向 GUI 会让操作卡到窗口关闭为止。脚本可以 `open -a` 启动工具后立即返回。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("日志") {
                Picker("记录级别", selection: $logLevel) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Text(logLevel.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLog.defaultDirectory.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text("超过 2 MB 自动轮转，最多保留 2 个旧文件。凭据在写入前统一脱敏。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开日志文件夹") { openLogFolder() }
                }
            }

            Section("凭据") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("密码保存在 macOS 钥匙串")
                    Text("不会写入配置、日志或命令行参数。下面按服务器列出已保存的条目。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if credentialScopes.isEmpty {
                    Text("钥匙串中没有保存的仓库密码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(credentialScopes, id: \.storageKey) { scope in
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(scope.host)
                                if let realm = scope.realm {
                                    Text("认证域：\(realm)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            // No confirmation: the only consequence of deleting a
                            // password is typing it once more. A dialog here
                            // would train the user to dismiss dialogs.
                            Button("删除", role: .destructive) {
                                Task { await remove(scope) }
                            }
                            .buttonStyle(.borderless)
                            .help("删除 \(scope.host) 的已保存密码，下次访问时需要重新输入")
                        }
                    }
                    HStack {
                        Spacer()
                        Button("清除全部凭据", role: .destructive) {
                            showingClearConfirmation = true
                        }
                    }
                }
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
                LabeledContent("工作副本格式支持", value: "SVN 1.10 – 1.x（不自动升级未知格式）")
                LabeledContent("App Sandbox", value: "关闭（需要任意路径访问与子进程）")
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 660)
        .onAppear {
            loadSettings()
            Task { credentialScopes = await appState.credentialScopes() }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存并重新检测") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .confirmationDialog(
            "清除所有已保存的仓库凭据？",
            isPresented: $showingClearConfirmation
        ) {
            Button("清除", role: .destructive) {
                Task {
                    await appState.clearAllCredentials()
                    credentialScopes = []
                    statusMessage = "已清除钥匙串中的 OpenSVN 凭据。"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次访问需要认证的仓库时需要重新输入用户名与密码。")
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0-dev"
    }

    private func loadSettings() {
        let settings = appState.settings
        explicitPath = settings.explicitSVNPath ?? ""
        timeoutSeconds = settings.operationTimeout
        confirmDestructive = settings.confirmBeforeDestructiveAction
        logLevel = settings.logLevel
        maxConcurrentWrites = settings.maxConcurrentWrites
        autoRefresh = settings.autoRefresh
        previewBeforeUpdate = settings.previewBeforeUpdate
        externalDiffCommand = settings.externalDiffCommand ?? ""
    }

    private func remove(_ scope: CredentialScope) async {
        await appState.forgetCredential(scope)
        credentialScopes = await appState.credentialScopes()
        statusMessage = "已删除 \(scope.host) 的已保存密码，下次访问时会重新询问。"
    }

    private func openLogFolder() {
        let directory = AppLog.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func chooseDiffCommand() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择用于 svn diff 的脚本或程序"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        externalDiffCommand = url.path
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 svn 可执行文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        explicitPath = url.path
    }

    private func save() async {
        var settings = appState.settings
        settings.explicitSVNPath = explicitPath.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : explicitPath.trimmingCharacters(in: .whitespaces)
        settings.operationTimeout = max(30, timeoutSeconds)
        settings.confirmBeforeDestructiveAction = confirmDestructive
        settings.logLevel = logLevel
        settings.maxConcurrentWrites = min(
            max(AppSettings.maxConcurrentWritesRange.lowerBound, maxConcurrentWrites),
            AppSettings.maxConcurrentWritesRange.upperBound
        )
        settings.autoRefresh = autoRefresh
        settings.previewBeforeUpdate = previewBeforeUpdate
        let diffCommand = externalDiffCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.externalDiffCommand = diffCommand.isEmpty ? nil : diffCommand
        await appState.apply(settings: settings)
        credentialScopes = await appState.credentialScopes()
        if let error = appState.startupError {
            statusMessage = "保存失败：\(error.message)"
        } else if let installation = appState.installation {
            statusMessage = "已切换至 svn \(installation.version.description)（\(installation.source.displayName)）。"
        } else {
            statusMessage = "设置已保存。"
        }
    }
}
