import AppKit
import SwiftUI
import OpenSVNCore

/// The `Settings` scene's content.
///
/// Three macOS conventions shape this file, and all three were being broken by
/// the previous version:
///
/// 1. Settings live in their own window, reached with ⌘, — never in a sheet over
///    the window whose behaviour they change.
/// 2. Changes apply as they are made. There is no OK / Cancel, and no "save and
///    re-detect": a preferences window that can be dismissed without applying is
///    a form, not settings.
/// 3. Panes are separated by a tab picker in the window's toolbar, because eight
///    groups stacked in one scroll view is a list of everything, which is the
///    same as no organisation at all.
struct SettingsView: View {
    var body: some View {
        TabView {
            SVNSettingsPane()
                .tabItem { Label("SVN", systemImage: "arrow.triangle.branch") }
            BehaviorSettingsPane()
                .tabItem { Label("操作", systemImage: "slider.horizontal.3") }
            ToolsSettingsPane()
                .tabItem { Label("工具", systemImage: "wrench.and.screwdriver") }
            CredentialsSettingsPane()
                .tabItem { Label("凭据", systemImage: "key") }
            AboutSettingsPane()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        // No `.navigationTitle` here: a `Settings` scene takes its window title
        // from the selected tab's label regardless, so the title bar reads "SVN"
        // or "操作". Naming the pane is not wrong — it matches where you are.
        // Fixed so the window does not resize as the user moves between panes.
        // Panes that outgrow it scroll inside their own form.
        .frame(width: 520, height: 380)
    }
}

// MARK: - Write path

/// Applies one setting immediately.
///
/// Every pane funnels through here so there is exactly one write path: mutate a
/// copy, persist it, and let `AppState` push it into the open sessions. Callers
/// that touch the binary path pass `rebuildService: true`; everything else is a
/// live value and costs nothing.
@MainActor
private func applySettings(
    _ appState: AppState,
    rebuildService: Bool = false,
    _ mutate: (inout AppSettings) -> Void
) {
    var settings = appState.settings
    mutate(&settings)
    Task { await appState.apply(settings: settings, rebuildService: rebuildService) }
}

/// Section footer text: the house style for "why", kept in one place so the
/// panes read as one document rather than five.
///
/// `Form` gives a footer its own centred text container, and a three-line
/// caption inside it comes out ragged-right. Pinning it to the leading edge is
/// what makes the footers look like one block of prose rather than five
/// different alignments.
private struct SettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A label-and-control row for a control that wants the rest of the line.
///
/// `LabeledContent` right-aligns its value, which is right for a short figure and
/// wrong for a field that has to hold a path: the field would start at a
/// different place on every row. Starting the label at the leading edge keeps
/// the column straight and gives the field the whole remainder.
private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            content
        }
    }
}

/// A text field for a settings row.
///
/// Deliberately placeholdless. A `TextField` placeholder in a macOS form row is
/// painted from an earlier layout pass than the field's own frame, so it lands
/// above or beside the border instead of inside it as soon as the row reflows
/// (picking a path, revealing the clear button). The hint it carried belongs in
/// the section footer, which is where the rest of the explanation already lives.
private struct SettingsTextField: View {
    @Binding var text: String
    var width: CGFloat?

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
    }
}

// MARK: - SVN runtime

private struct SVNSettingsPane: View {
    @Environment(AppState.self) private var appState

    @State private var pathDraft = ""
    @State private var autoRefresh = true
    @State private var previewBeforeUpdate = true
    @FocusState private var pathFocused: Bool

    var body: some View {
        Form {
            Section {
                SettingsRow(title: "可执行文件") {
                    SettingsTextField(text: $pathDraft)
                        .focused($pathFocused)
                        .onSubmit(commitPath)
                    Button("选择…") { chooseExecutable() }
                    if !pathDraft.isEmpty {
                        Button("清除") {
                            pathDraft = ""
                            commitPath()
                        }
                    }
                }

                LabeledContent("当前使用") { currentRuntime }
            } header: {
                Text("svn 运行时")
            } footer: {
                SettingsFooter("留空则按「应用内置 → PATH → 常见位置」的顺序查找。从 Finder 启动的应用不继承 Homebrew 的 PATH，所以显式路径优先。")
            }

            Section {
                Toggle("自动刷新（监听文件变化）", isOn: $autoRefresh)
                Toggle("更新前先查看服务器上的变更", isOn: $previewBeforeUpdate)
            } header: {
                Text("刷新与更新")
            } footer: {
                SettingsFooter("自动刷新只监听当前打开的工作副本，.svn 内部的改动会被忽略——否则每次刷新都会触发下一次刷新。更新前预览多花一次网络往返，换回一份「将要发生什么」的清单。")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: pathFocused) { _, focused in
            // A path is only meaningful once it is finished. Committing per
            // keystroke would spawn `svn --version` once per character.
            if !focused { commitPath() }
        }
        .onChange(of: autoRefresh) { _, value in
            applySettings(appState) { $0.autoRefresh = value }
        }
        .onChange(of: previewBeforeUpdate) { _, value in
            applySettings(appState) { $0.previewBeforeUpdate = value }
        }
    }

    @ViewBuilder
    private var currentRuntime: some View {
        if let installation = appState.installation {
            Text("\(installation.version.description) · \(installation.source.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help(installation.executableURL.path)
        } else if appState.isStarting {
            ProgressView().controlSize(.small)
        } else {
            Text(appState.startupError?.message ?? "尚未检测到可用的 svn")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    private func load() {
        let settings = appState.settings
        pathDraft = settings.explicitSVNPath ?? ""
        autoRefresh = settings.autoRefresh
        previewBeforeUpdate = settings.previewBeforeUpdate
    }

    private func commitPath() {
        let trimmed = pathDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != (appState.settings.explicitSVNPath ?? "") else { return }
        applySettings(appState, rebuildService: true) { settings in
            settings.explicitSVNPath = trimmed.isEmpty ? nil : trimmed
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 svn 可执行文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathDraft = url.path
        commitPath()
    }
}

// MARK: - Behaviour

private struct BehaviorSettingsPane: View {
    @Environment(AppState.self) private var appState

    @State private var timeoutDraft = ""
    @State private var confirmDestructive = true
    @State private var maxConcurrentWrites = AppSettings.defaultMaxConcurrentWrites
    @FocusState private var timeoutFocused: Bool

    var body: some View {
        Form {
            Section {
                SettingsRow(title: "单次操作超时") {
                    SettingsTextField(text: $timeoutDraft, width: 72)
                        .focused($timeoutFocused)
                        .onSubmit(commitTimeout)
                    Text("秒")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                LabeledContent("同时进行的写操作") {
                    Stepper(value: $maxConcurrentWrites, in: AppSettings.maxConcurrentWritesRange) {
                        Text("\(maxConcurrentWrites) 个")
                            .monospacedDigit()
                    }
                }

                Toggle("危险操作前要求确认", isOn: $confirmDestructive)
            } header: {
                Text("执行")
            } footer: {
                SettingsFooter("确认在服务层强制执行，这个开关只决定界面是否提前展示预览。写操作上限约束的是不同工作副本之间的并行度——同一个工作副本上的两个写操作始终排队，与上限无关。")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: timeoutFocused) { _, focused in
            if !focused { commitTimeout() }
        }
        .onChange(of: confirmDestructive) { _, value in
            applySettings(appState) { $0.confirmBeforeDestructiveAction = value }
        }
        .onChange(of: maxConcurrentWrites) { _, value in
            applySettings(appState) { $0.maxConcurrentWrites = value }
        }
    }

    private func load() {
        let settings = appState.settings
        timeoutDraft = String(Int(settings.operationTimeout))
        confirmDestructive = settings.confirmBeforeDestructiveAction
        maxConcurrentWrites = settings.maxConcurrentWrites
    }

    private func commitTimeout() {
        // Shorter than half a minute would time out a working copy on a slow
        // server; the value is clamped here rather than rejected, because a
        // number that quietly snaps back is easier to understand than an error.
        let seconds = TimeInterval(Int(timeoutDraft.trimmingCharacters(in: .whitespaces)) ?? 0)
        let clamped = max(30, seconds)
        timeoutDraft = String(Int(clamped))
        guard clamped != appState.settings.operationTimeout else { return }
        applySettings(appState) { $0.operationTimeout = clamped }
    }
}

// MARK: - Tools

private struct ToolsSettingsPane: View {
    @Environment(AppState.self) private var appState

    @State private var diffDraft = ""
    @State private var logLevel: LogLevel = .info
    @FocusState private var diffFocused: Bool

    var body: some View {
        Form {
            Section {
                SettingsRow(title: "外部 diff 命令") {
                    SettingsTextField(text: $diffDraft)
                        .focused($diffFocused)
                        .onSubmit(commitDiff)
                    Button("选择…") { chooseDiffCommand() }
                    if !diffDraft.isEmpty {
                        Button("清除") {
                            diffDraft = ""
                            commitDiff()
                        }
                    }
                }
            } header: {
                Text("外部 diff")
            } footer: {
                SettingsFooter("留空则使用内置差异视图。填了会传给 svn diff --diff-cmd，应填包装脚本而不是 GUI 程序本身：svn 会等子进程退出，直接指向 GUI 会让操作卡到窗口关闭为止。")
            }

            Section {
                Picker("记录级别", selection: $logLevel) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }

                LabeledContent("日志文件夹") {
                    HStack(spacing: 6) {
                        Text(AppLog.defaultDirectory.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("打开") { openLogFolder() }
                    }
                }
            } header: {
                Text("日志")
            } footer: {
                SettingsFooter("\(logLevel.explanation) 超过 2 MB 自动轮转，最多保留 2 个旧文件；凭据在写入前统一脱敏。")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: diffFocused) { _, focused in
            if !focused { commitDiff() }
        }
        .onChange(of: logLevel) { _, value in
            applySettings(appState) { $0.logLevel = value }
        }
    }

    private func load() {
        diffDraft = appState.settings.externalDiffCommand ?? ""
        logLevel = appState.settings.logLevel
    }

    private func commitDiff() {
        let trimmed = diffDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (appState.settings.externalDiffCommand ?? "") else { return }
        applySettings(appState) { settings in
            settings.externalDiffCommand = trimmed.isEmpty ? nil : trimmed
        }
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
        diffDraft = url.path
        commitDiff()
    }
}

// MARK: - Credentials

private struct CredentialsSettingsPane: View {
    @Environment(AppState.self) private var appState

    @State private var scopes: [CredentialScope] = []
    @State private var showingClearConfirmation = false

    var body: some View {
        Form {
            Section {
                if scopes.isEmpty {
                    Text("钥匙串中没有保存的仓库密码。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scopes, id: \.storageKey) { scope in
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
                        Button("清除全部凭据…", role: .destructive) {
                            showingClearConfirmation = true
                        }
                    }
                }
            } header: {
                Text("已保存的密码")
            } footer: {
                SettingsFooter("密码保存在 macOS 钥匙串，不会写入配置、日志或命令行参数。删除后只影响本机，不影响服务器上的账号。")
            }
        }
        .formStyle(.grouped)
        .task { scopes = await appState.credentialScopes() }
        .confirmationDialog(
            "清除所有已保存的仓库凭据？",
            isPresented: $showingClearConfirmation
        ) {
            Button("清除", role: .destructive) {
                Task {
                    await appState.clearAllCredentials()
                    scopes = await appState.credentialScopes()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次访问需要认证的仓库时需要重新输入用户名与密码。")
        }
    }

    private func remove(_ scope: CredentialScope) async {
        await appState.forgetCredential(scope)
        scopes = await appState.credentialScopes()
    }
}

// MARK: - About

private struct AboutSettingsPane: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tint)
                    Text("OpenSVN")
                        .font(.title3.weight(.semibold))
                    Text("版本 \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section {
                LabeledContent("工作副本格式", value: "1.10 – 1.x（不自动升级未知格式）")
                LabeledContent("App Sandbox", value: "关闭（需要任意路径访问与子进程）")
                LabeledContent("诊断") {
                    Button("显示日志文件夹") {
                        let directory = AppLog.defaultDirectory
                        try? FileManager.default.createDirectory(
                            at: directory,
                            withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(directory)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0-dev"
    }
}
