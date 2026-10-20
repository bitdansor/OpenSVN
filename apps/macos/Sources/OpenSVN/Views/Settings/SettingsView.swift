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
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("密码保存在 macOS 钥匙串")
                        Text("不会写入配置、日志或命令行参数。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("清除全部凭据", role: .destructive) {
                        showingClearConfirmation = true
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
        .onAppear(perform: loadSettings)
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
    }

    private func openLogFolder() {
        let directory = AppLog.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
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
        await appState.apply(settings: settings)
        if let error = appState.startupError {
            statusMessage = "保存失败：\(error.message)"
        } else if let installation = appState.installation {
            statusMessage = "已切换至 svn \(installation.version.description)（\(installation.source.displayName)）。"
        } else {
            statusMessage = "设置已保存。"
        }
    }
}
