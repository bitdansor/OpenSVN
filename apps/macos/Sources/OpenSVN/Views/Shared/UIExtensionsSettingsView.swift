import AppKit
import SwiftUI
import OpenSVNCore

/// Self-contained settings for the UI extensions.
///
/// The app's main Settings scene is owned by another part of the project; this
/// panel reads and writes the very same UserDefaults keys, so configuring a
/// value here or there is equivalent. It is reachable from the main window's
/// toolbar so the features stay configurable even if the Settings scene has not
/// been extended yet.
struct UIExtensionsSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UIExtensionSettings.ticketURLTemplateKey)
    private var ticketTemplate = UIExtensionSettings.defaultTicketURLTemplate
    @AppStorage(UIExtensionSettings.taskNotificationsEnabledKey)
    private var notificationsEnabled = true
    @AppStorage(UIExtensionSettings.mergeExecutableKey)
    private var mergeExecutable = ""
    @AppStorage(UIExtensionSettings.mergeArgumentTemplateKey)
    private var mergeArguments = UIExtensionSettings.defaultMergeArgumentTemplate

    @State private var authorizationHint: String?

    var body: some View {
        Form {
            Section {
                TextField(L.t("URL 模板"), text: $ticketTemplate)
                    .textFieldStyle(.roundedBorder)
                Button(L.t("恢复默认模板")) {
                    ticketTemplate = UIExtensionSettings.defaultTicketURLTemplate
                }
                .buttonStyle(.link)
            } header: {
                Text(L.t("工单号链接"))
            } footer: {
                footer(L.t("提交说明与历史消息里的 #123、PROJ-123、issue 123 会变成可点击链接。占位符：{id} 规范化编号、{number} 纯数字、{key} 项目前缀。"))
            }

            Section {
                Toggle(L.t("任务完成或失败时发送通知"), isOn: $notificationsEnabled)
                HStack {
                    Button(L.t("现在请求通知授权")) {
                        Task { @MainActor in
                            TaskNotificationBridge.shared.requestAuthorizationIfNeeded(force: true)
                        }
                        authorizationHint = L.t("已请求授权；若系统未弹出对话框，说明当前构建未签名或已授权过。")
                    }
                    if let authorizationHint {
                        Text(authorizationHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L.t("操作通知"))
            } footer: {
                footer(L.t("使用系统本地通知。未签名、未授权或开关关闭时会自动跳过，不会中断任何操作。"))
            }

            Section {
                HStack {
                    TextField(L.t("可执行文件路径"), text: $mergeExecutable)
                        .textFieldStyle(.roundedBorder)
                    Button(L.t("选择…")) { chooseMergeExecutable() }
                }
                TextField(L.t("参数模板"), text: $mergeArguments)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text(L.t("外部合并工具"))
            } footer: {
                footer(L.t("冲突解决入口提供「用外部工具解决」。占位符 {base}、{mine}、{theirs}、{merged}、{file} 会替换为文件路径；命令按参数数组执行，不会拼接 shell 字符串。工具需在 {merged} 写出结果并以 0 退出。"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("完成")) { dismiss() }
            }
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseMergeExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L.t("选择")
        panel.message = L.t("选择用于三方合并的程序")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mergeExecutable = url.path
    }
}
