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
            ConnectionSettingsPane()
                .tabItem { Label("连接", systemImage: "network") }
            AboutSettingsPane()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        // No `.navigationTitle` here: a `Settings` scene takes its window title
        // from the selected tab's label regardless, so the title bar reads "SVN"
        // or "操作". Naming the pane is not wrong — it matches where you are.
        //
        // Fixed size so the window does not resize as the user moves between
        // panes. Panes that outgrow it scroll inside their own form.
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
    @State private var checkForUpdates = false
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
                SettingsFooter(runtimeFooter)
            }

            Section {
                Toggle("自动刷新（监听文件变化）", isOn: $autoRefresh)
                Toggle("更新前先查看服务器上的变更", isOn: $previewBeforeUpdate)
            } header: {
                Text("刷新与更新")
            } footer: {
                SettingsFooter("自动刷新只监听当前打开的工作副本，.svn 内部的改动会被忽略——否则每次刷新都会触发下一次刷新。更新前预览多花一次网络往返，换回一份「将要发生什么」的清单。")
            }

            Section {
                Toggle("启动时检查新版本", isOn: $checkForUpdates)
                HStack {
                    Text(appState.isCheckingForUpdates ? "正在检查…" : "手动检查")
                    Spacer()
                    Button("检查更新…") {
                        Task { await appState.checkForUpdates(explicitlyRequested: true) }
                    }
                    .disabled(appState.isCheckingForUpdates)
                }
            } header: {
                Text("版本")
            } footer: {
                SettingsFooter("启动时检查默认关闭：这是本应用唯一会主动连接项目服务器的请求（GitHub 的 Releases 接口），只读取公开的版本信息，不携带任何本机数据，每天最多一次。关了也不影响菜单里的「检查更新…」。检查到新版本时只会给出下载页，不会自行下载或替换应用。")
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
        .onChange(of: checkForUpdates) { _, value in
            // `rebuildService: false`: this only changes what the next launch
            // does, so there is nothing to re-discover now.
            applySettings(appState, rebuildService: false) { $0.checkForUpdatesOnLaunch = value }
        }
    }

    @ViewBuilder
    private var currentRuntime: some View {
        if let installation = appState.installation {
            Text("\(installation.version.description) · \(installation.source.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else if appState.isStarting {
            ProgressView().controlSize(.small)
        } else {
            Text(appState.startupError?.message ?? "尚未检测到可用的 svn")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    /// The one place that says which `svn` is actually running.
    ///
    /// This used to be a permanent `svn 1.14.5` strip in the sidebar's bottom
    /// corner. A build number parked in the corner of the navigation is a fact
    /// you cannot act on; here it sits next to the control that decides it, and
    /// the full path comes with it.
    private var runtimeFooter: String {
        let hint = "留空则按「应用内置 → PATH → 常见位置」的顺序查找——从 Finder 启动的应用不继承 Homebrew 的 PATH，所以显式路径优先。"
        guard let installation = appState.installation else { return hint }
        return "当前使用 \(installation.executableURL.path)。" + hint
    }

    private func load() {
        let settings = appState.settings
        pathDraft = settings.explicitSVNPath ?? ""
        autoRefresh = settings.autoRefresh
        previewBeforeUpdate = settings.previewBeforeUpdate
        checkForUpdates = settings.checkForUpdatesOnLaunch
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

    // UI-extension key (Support/UIExtensionSettings.swift). Hard-coded here so
    // the Settings scene has no compile-time dependency on that layer.
    @AppStorage("cn.opensvn.taskNotificationsEnabled")
    private var taskNotificationsEnabled = true

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
                Toggle("任务成功 / 失败时发送通知", isOn: $taskNotificationsEnabled)
            } header: {
                Text("执行")
            } footer: {
                SettingsFooter("确认在服务层强制执行，这个开关只决定界面是否提前展示预览。写操作上限约束的是不同工作副本之间的并行度——同一个工作副本上的两个写操作始终排队，与上限无关。任务通知在任务中心的任务成功或失败时发送本地通知；未签名或未获通知授权时会自动跳过。")
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

    // UI-extension keys (Support/UIExtensionSettings.swift). Hard-coded here so
    // the Settings scene has no compile-time dependency on that layer; the
    // defaults match that type so an unset key behaves identically.
    @AppStorage("cn.opensvn.ticketURLTemplate")
    private var ticketURLTemplate = "https://example.com/browse/{id}"
    @AppStorage("cn.opensvn.mergeExecutablePath")
    private var mergeExecutablePath = ""
    @AppStorage("cn.opensvn.mergeArgumentTemplate")
    private var mergeArgumentTemplate = "{base} {mine} {theirs} {merged}"

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
                SettingsRow(title: "URL 模板") {
                    SettingsTextField(text: $ticketURLTemplate)
                }
            } header: {
                Text("工单链接")
            } footer: {
                SettingsFooter("识别 #123、PROJ-123、issue 123，生成可点击链接。占位符可用 {id}、{number}、{key}。")
            }

            Section {
                SettingsRow(title: "可执行文件") {
                    SettingsTextField(text: $mergeExecutablePath)
                    Button("选择…") { chooseMergeExecutable() }
                    if !mergeExecutablePath.isEmpty {
                        Button("清除") { mergeExecutablePath = "" }
                    }
                }
                SettingsRow(title: "参数模板") {
                    SettingsTextField(text: $mergeArgumentTemplate)
                }
            } header: {
                Text("外部合并")
            } footer: {
                SettingsFooter("命令按参数数组执行，不使用 shell 字符串拼接。占位符：{base}、{mine}、{theirs}、{merged}、{file}。")
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

    private func chooseMergeExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择外部合并工具"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mergeExecutablePath = url.path
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

// MARK: - Connection & certificates

/// Certificate trust and proxy configuration.
///
/// These settings deliberately bypass `AppState`: `SVNConnectionSettingsStore`
/// owns dedicated `UserDefaults` keys so the process launcher can read them
/// directly, and the one-shot "connect anyway" flag is consumed by the next svn
/// invocation rather than pushed into open sessions.
private struct ConnectionSettingsPane: View {
    @State private var store = SVNConnectionSettingsStore()

    // Certificate trust
    @State private var trustMode: TrustMode = .strict
    @State private var selectedFailures: Set<ServerCertificateFailure> = []
    @State private var pendingOneShotNote = false
    @State private var showingOneShotConfirmation = false

    // Proxy
    @State private var serversConfig = ServersConfig()
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var proxyUsername = ""
    @State private var proxyExceptions = ""
    @State private var backupNote = ""
    @State private var errorMessage: String?
    @State private var showingProxySaveConfirmation = false

    /// Local, UI-only representation of `CertificateTrustPolicy`.
    private enum TrustMode: String, CaseIterable, Identifiable {
        case strict, specified, all
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            certificateSection
            oneShotSection
            proxySection
            authenticationSection
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: trustMode) { _, _ in persistPolicy() }
        .onChange(of: selectedFailures) { _, _ in persistPolicy() }
        .confirmationDialog("临时放宽证书校验？", isPresented: $showingOneShotConfirmation) {
            Button("仍要连接（仅此一次）") { armOneShot() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅对紧接着的一次 svn 操作生效，之后自动恢复为上方的策略。svn 在 --non-interactive 模式下不会逐张证书询问，本次操作将静默接受带有这些问题的证书。请确认你信任目标服务器。")
        }
        .confirmationDialog("修改 ~/.subversion/servers？", isPresented: $showingProxySaveConfirmation) {
            Button("备份并保存") { saveProxy() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存前会先把现有文件备份为 servers.opensvn-backup-<时间戳>，只改动 [global] 段中的 4 个代理字段，其余内容与注释保持不变。该文件是 svn 的全局配置，会影响使用此用户目录的所有 svn 客户端。")
        }
    }

    // MARK: Certificate trust

    private var certificateSection: some View {
        Section {
            Picker("证书校验", selection: $trustMode) {
                Text("严格校验（推荐）").tag(TrustMode.strict)
                Text("信任指定问题").tag(TrustMode.specified)
                Text("信任所有未知证书（高风险）").tag(TrustMode.all)
            }

            Text("失败类型（同时用于一次性的「仍要连接」）：")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(ServerCertificateFailure.allCases, id: \.self) { failure in
                Toggle(failure.label, isOn: binding(for: failure))
            }

            if trustMode == .all {
                Text("将下发全部 5 种失败类型，接受任何未知、过期或域名不匹配的证书。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("HTTPS 服务器证书")
        } footer: {
            SettingsFooter("默认严格校验：遇到无效证书时 svn 会直接失败。勾选失败类型后，svn 会在 --non-interactive 下静默接受对应问题的证书——攻击者可借此冒充服务器、窃取或篡改提交内容。仅在你确认是自签名/内网证书时启用，并尽量只勾选一项。本应用改用全量 --trust-server-cert-failures（可填 unknown-ca / cn-mismatch / expired / not-yet-valid / other 的逗号组合）：旧参数 --trust-server-cert 已废弃、仅等价于 unknown-ca，且可能往 stderr 打警告污染错误分类，因此不会下发。该选项仅在 svn 1.14 及以上生效，旧版本自动保持严格校验。")
        }
    }

    private var oneShotSection: some View {
        Section {
            HStack {
                Button("为下一次连接临时放宽…") { showingOneShotConfirmation = true }
                    .disabled(selectedFailures.isEmpty)
                Spacer()
                if pendingOneShotNote {
                    Text("已就绪，等待下一次连接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if selectedFailures.isEmpty {
                Text("请先在上方勾选至少一种失败类型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("一次性的「仍要连接」")
        } footer: {
            SettingsFooter("「仍要连接」不会永久降低校验强度：它使用上方勾选的失败类型，只对紧接着的一次 svn 操作生效，操作后自动清除。适用于偶发的内网自签名证书，避免把宽松策略长期留在设置里。")
        }
    }

    // MARK: Proxy

    private var proxySection: some View {
        Section {
            LabeledContent("配置文件") {
                HStack(spacing: 6) {
                    Text(store.serversFileURL.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("打开") { openServersFile() }
                }
            }

            if serversConfig.fileExists {
                LabeledContent("当前代理（只读）") {
                    Text(currentProxySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text("该文件尚不存在，保存代理设置时会新建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsRow(title: "主机") { SettingsTextField(text: $proxyHost) }
            SettingsRow(title: "端口") {
                SettingsTextField(text: $proxyPort, width: 88)
                Text("1–65535").font(.caption).foregroundStyle(.secondary)
            }
            SettingsRow(title: "用户名") { SettingsTextField(text: $proxyUsername) }
            SettingsRow(title: "排除列表") { SettingsTextField(text: $proxyExceptions) }

            HStack {
                Spacer()
                Button("保存代理设置…") { showingProxySaveConfirmation = true }
            }
            if !backupNote.isEmpty {
                Text(backupNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("代理（~/.subversion/servers）")
        } footer: {
            SettingsFooter("http-proxy-password 不在此处编辑：明文写进共享配置文件会抵消钥匙串的保护。保存前会自动备份原文件，且只改动 [global] 段的这 4 个字段。")
        }
    }

    // MARK: Authentication / SASL (read-only)

    private var authenticationSection: some View {
        Section {
            if serversConfig.displayEntries.isEmpty {
                Text("servers 文件中没有生效的认证 / TLS 相关字段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(serversConfig.displayEntries.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) {
                        Text(serversConfig.displayEntries[key] ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            if !serversConfig.groupEntries.isEmpty {
                Text("[groups] 段（只读）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(serversConfig.groupEntries.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) {
                        Text(serversConfig.groupEntries[key] ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Button("打开 ~/.subversion 文件夹") { openSubversionFolder() }
        } header: {
            Text("认证与 SASL")
        } footer: {
            SettingsFooter("认证 / TLS 字段与 [groups] 段只读展示，不做修改；http-proxy-password 等密码值一律脱敏，且不会被写入设置存储或日志。svnserve 的 SASL 与 svn+ssh 认证由系统 SASL 库、SSH 配置与 SSH_ASKPASS 管理，不通过这个配置文件控制；本应用的 svn 子进程是非交互的（--non-interactive），无法弹出终端密码提示，也不提供 iCloud 钥匙串同步。")
        }
    }

    // MARK: Behaviour

    private var currentProxySummary: String {
        let proxy = serversConfig.proxy
        guard !proxy.host.isEmpty else { return "未配置（注释或未设置）" }
        var summary = proxy.port.map { "\(proxy.host):\($0)" } ?? proxy.host
        if let user = proxy.username { summary += " · 用户 \(user)" }
        if let exceptions = proxy.exceptions { summary += " · 排除 \(exceptions)" }
        return summary
    }

    private func binding(for failure: ServerCertificateFailure) -> Binding<Bool> {
        Binding(
            get: { selectedFailures.contains(failure) },
            set: { isOn in
                if isOn { selectedFailures.insert(failure) } else { selectedFailures.remove(failure) }
            }
        )
    }

    private func load() {
        switch store.persistentPolicy {
        case .strict:
            trustMode = .strict
        case .specifiedFailures(let failures):
            trustMode = .specified
            selectedFailures = failures
        case .trustAllCertificates:
            trustMode = .all
        }

        let config = (try? store.readServersConfig()) ?? ServersConfig()
        serversConfig = config
        let proxy = config.proxy
        proxyHost = proxy.host
        proxyPort = proxy.port.map { String($0) } ?? ""
        proxyUsername = proxy.username ?? ""
        proxyExceptions = proxy.exceptions ?? ""
        pendingOneShotNote = store.hasPendingOneShotTrust
    }

    private func persistPolicy() {
        let policy: CertificateTrustPolicy
        switch trustMode {
        case .strict:
            policy = .strict
        case .specified:
            policy = selectedFailures.isEmpty ? .strict : .specifiedFailures(selectedFailures)
        case .all:
            policy = .trustAllCertificates
        }
        store.persistentPolicy = policy
    }

    private func armOneShot() {
        store.armOneShotTrust(.specifiedFailures(selectedFailures))
        pendingOneShotNote = true
    }

    private func saveProxy() {
        let trimmedPort = proxyPort.trimmingCharacters(in: .whitespaces)
        let port: Int?
        if trimmedPort.isEmpty {
            port = nil
        } else if let value = Int(trimmedPort), (1...65535).contains(value) {
            port = value
        } else {
            errorMessage = "代理端口无效：应为 1–65535 的整数"
            return
        }

        let proxy = ProxySettings(
            host: proxyHost,
            port: port,
            username: proxyUsername.isEmpty ? nil : proxyUsername,
            exceptions: proxyExceptions.isEmpty ? nil : proxyExceptions
        )
        do {
            let backup = try store.writeProxySettings(proxy)
            backupNote = backup.map { "已备份原文件：\($0.lastPathComponent)" }
                ?? "已新建 servers 文件（原文件不存在，无需备份）"
            errorMessage = nil
            serversConfig = (try? store.readServersConfig()) ?? ServersConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openServersFile() {
        let url = store.serversFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            openSubversionFolder()
        }
    }

    private func openSubversionFolder() {
        let directory = store.serversFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}

/// Chinese labels for the svn certificate-failure tokens.
private extension ServerCertificateFailure {
    var label: String {
        switch self {
        case .unknownCA: return "颁发机构未知（unknown-ca）"
        case .cnMismatch: return "域名不匹配（cn-mismatch）"
        case .expired: return "证书已过期（expired）"
        case .notYetValid: return "证书尚未生效（not-yet-valid）"
        case .other: return "其它校验失败（other）"
        }
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
