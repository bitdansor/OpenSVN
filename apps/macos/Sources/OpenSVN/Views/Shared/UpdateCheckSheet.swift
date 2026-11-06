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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 440)
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
                    Text("检查更新只读取项目 Releases 的公开信息，不发送任何本机数据。失败不影响工作副本的任何操作。")
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
                } else {
                    Text("还没有结果。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("启动时检查", isOn: launchToggle)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("只在启动时询问一次，每天最多一次")
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if case .updateAvailable(_, let release) = appState.updateCheckResult {
                if let download = release.downloadURL {
                    Button("下载") { NSWorkspace.shared.open(download) }
                        .buttonStyle(.borderedProminent)
                } else if let page = release.pageURL {
                    Button("打开发布页") { NSWorkspace.shared.open(page) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if appState.updateCheckError != nil {
                Button("重试") {
                    Task { await appState.checkForUpdates(explicitlyRequested: true) }
                }
            }
        }
        .padding(14)
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
        if let error = appState.updateCheckError { return "检查更新失败" }
        return appState.updateCheckResult?.title ?? "检查更新"
    }

    private var subtitle: String {
        if appState.isCheckingForUpdates { return "正在查询发布信息…" }
        return "当前版本 \(UpdateChecker.bundleVersion())"
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
