import AppKit
import SwiftUI
import OpenSVNCore

/// Result of 检查更新.
///
/// It shows three different states rather than collapsing them into "no update":
/// an available update, "you are current", and "the project has never published
/// anything" are not the same answer, and a dialog that says the second when the
/// third is true is telling the user something it does not know.
struct UpdateCheckSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 440)
        .alert(L.t("安装更新并重新启动？"), isPresented: $confirmingInstall) {
            Button(L.t("取消"), role: .cancel) {}
            Button(L.t("重新启动并安装")) {
                appState.installUpdateAndRelaunch()
            }
        } message: {
            Text(L.f("应用会退出，更新包会被复制到 %@ 并重新打开。签名校验已通过，替换失败时会自动恢复旧版本。", String(describing: Bundle.main.bundleURL.path)))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if appState.isCheckingForUpdates {
                ProgressView().controlSize(.small)
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = appState.updateCheckError {
                    Text(error)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L.t("检查更新只读取项目 Releases 的公开信息，不发送任何本机数据。失败不影响工作副本的任何操作。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let result = appState.updateCheckResult {
                    Text(result.message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if case .updateAvailable(_, let release) = result,
                       let page = release.pageURL {
                        Text(page.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if result.isUpdateAvailable {
                        updateStatus
                    }
                } else {
                    Text(L.t("还没有结果。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch appState.updateDownloadPhase {
        case .idle:
            if let blocker = appState.updateInstallBlocker {
                Text(blocker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L.t("安装包会先下载到「应用支持」目录，校验 SHA-256 与发布签名（项目密钥或 Developer ID）之后才允许替换当前应用。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text(downloadDetail(progress))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L.t("正在校验发布清单与更新包…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready(_, let version):
            Label(L.f("%@ 已下载并通过签名校验。", String(describing: version)), systemImage: "checkmark.seal.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L.t("正在安装并重新启动…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func downloadDetail(_ progress: UpdateDownloadProgress) -> String {
        let received = ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)
        guard let expected = progress.expectedBytes else { return L.f("已下载 %@", String(describing: received)) }
        let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        return L.f("已下载 %@ / %@", String(describing: received), String(describing: total))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(L.t("启动时检查"), isOn: launchToggle)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help(L.t("只在启动时询问一次，每天最多一次"))
            Spacer()
            Button(L.t("关闭")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            updateButtons
            if appState.updateCheckError != nil {
                Button(L.t("重试")) {
                    Task { await appState.checkForUpdates(explicitlyRequested: true) }
                }
            }
        }
        .padding(14)
    }

    /// One button at a time, chosen by the phase. Showing "下载并安装" while a
    /// download is already running would invite a second one; showing nothing
    /// during verification would look like a hang.
    @ViewBuilder
    private var updateButtons: some View {
        switch appState.updateDownloadPhase {
        case .downloading:
            Button(L.t("取消下载")) { appState.cancelUpdateDownload() }
        case .verifying, .installing:
            EmptyView()
        case .ready:
            Button(L.t("重新启动并安装")) { confirmingInstall = true }
                .buttonStyle(.borderedProminent)
        case .failed:
            Button(L.t("重试")) { appState.startUpdateDownload() }
                .buttonStyle(.borderedProminent)
        case .idle:
            if appState.canInstallUpdateAutomatically {
                Button(L.t("下载并安装")) { appState.startUpdateDownload() }
                    .buttonStyle(.borderedProminent)
            } else {
                manualDownloadButtons
            }
        }
    }

    @ViewBuilder
    private var manualDownloadButtons: some View {
        if case .updateAvailable(_, let release) = appState.updateCheckResult {
            if let download = release.downloadURL {
                Button(L.t("下载")) { NSWorkspace.shared.open(download) }
                    .buttonStyle(.borderedProminent)
            } else if let page = release.pageURL {
                Button(L.t("打开发布页")) { NSWorkspace.shared.open(page) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Bound straight to the stored setting, so flipping it here and flipping it
    /// in 设置 are the same edit rather than two copies that can drift.
    ///
    /// `rebuildService: false`: this preference only changes what happens on the
    /// next launch, so re-discovering svn for it would interrupt the user's
    /// working copy for nothing.
    private var launchToggle: Binding<Bool> {
        Binding(
            get: { appState.settings.checkForUpdatesOnLaunch },
            set: { newValue in
                var settings = appState.settings
                settings.checkForUpdatesOnLaunch = newValue
                Task { await appState.apply(settings: settings, rebuildService: false) }
            }
        )
    }

    private var title: String {
        if appState.updateCheckError != nil { return L.t("检查更新失败") }
        return appState.updateCheckResult?.title ?? L.t("检查更新")
    }

    private var subtitle: String {
        if appState.isCheckingForUpdates { return L.t("正在查询发布信息…") }
        return L.f("当前版本 %@", String(describing: UpdateChecker.bundleVersion()))
    }

    private var icon: String {
        if appState.updateCheckError != nil { return "exclamationmark.triangle.fill" }
        switch appState.updateCheckResult {
        case .updateAvailable: return "arrow.down.circle.fill"
        case .upToDate: return "checkmark.circle.fill"
        case .noReleases, .none: return "questionmark.circle"
        }
    }

    private var iconColor: Color {
        if appState.updateCheckError != nil { return .orange }
        switch appState.updateCheckResult {
        case .updateAvailable: return .accentColor
        case .upToDate: return .green
        case .noReleases, .none: return .secondary
        }
    }
}
