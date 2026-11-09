import SwiftUI
import OpenSVNCore

/// The `svn switch` sheet.
///
/// Deliberately next to 切换仓库地址 (relocate) and deliberately worded
/// differently: `switch` moves the working copy to another path *inside the same
/// repository* (a branch), while `relocate` keeps the same path and only changes
/// the address. Confusing the two is the classic way to break a working copy, so
/// the wording and the help text both spell out the difference.
struct SwitchSheet: View {
    @Bindable var session: RepositorySession
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var revisionText = ""
    @State private var ignoreExternals = false
    @State private var force = false
    @State private var isRunning = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section(L.t("目标")) {
                    LabeledContent(L.t("切换到的 URL")) {
                        TextField("https://…/branches/feature", text: $url)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    LabeledContent(L.t("修订版本")) {
                        TextField(L.t("留空表示 HEAD"), text: $revisionText)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                }

                Section(L.t("选项")) {
                    Toggle(L.t("外挂工作副本保持不动（--ignore-externals）"), isOn: $ignoreExternals)
                    Toggle(L.t("覆盖未纳入版本控制的同名文件（--force）"), isOn: $force)
                    if force {
                        Text(L.t("--force 会让未纳入版本控制的同名文件被切换后的内容替换掉，那些文件没有任何备份。"))
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    if let note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text(L.f("当前地址：%@", String(describing: session.info?.url ?? "—")))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } footer: {
                    Text(L.t("只想换协议、主机或路径、而内容还是同一个仓库？那是「信息」页的「切换仓库地址」（relocate），不是这里。svn 会校验仓库 UUID，切到另一个仓库会失败。"))
                        .font(.caption2)
                }
            }
            .formStyle(.grouped)
            Divider()
            previewSection
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onAppear(perform: suggestURL)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(L.f("切换「%@」", String(describing: session.displayName)))
                    .font(.headline)
                Text(L.t("把工作副本整体指向同一仓库内的另一个 URL。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: riskIcon)
                    .foregroundStyle(riskColor)
                Text(preview?.summary ?? L.t("填写目标 URL 后这里会显示这次切换做什么"))
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer()
            }
            if let detail = preview?.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isRunning { ProgressView().controlSize(.small) }
            Spacer()
            Button(L.t("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isRunning)
            Button(isRunning ? L.t("切换中…") : L.t("切换")) {
                Task { await runSwitch() }
            }
            .buttonStyle(.borderedProminent)
            .tint(force ? .red : nil)
            .keyboardShortcut(.defaultAction)
            .disabled(isRunning || request == nil)
        }
        .padding(14)
    }

    private var request: SwitchRequest? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SwitchRequest(
            url: trimmed,
            target: session.path,
            revision: Int64(revisionText.trimmingCharacters(in: .whitespaces)),
            ignoreExternals: ignoreExternals,
            force: force
        )
    }

    private var preview: OperationPreview? {
        request.map { session.previewSwitch($0) }
    }

    private var riskIcon: String {
        switch preview?.risk {
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.triangle"
        default: return "info.circle"
        }
    }

    private var riskColor: Color {
        switch preview?.risk {
        case .high: return .red
        case .medium: return .orange
        default: return .secondary
        }
    }

    private func suggestURL() {
        // Branch names differ from the current URL by more than a prefix, so
        // there is nothing reliable to prefill — only the current value, which
        // the user can edit, is worth showing.
        if url.isEmpty { url = session.info?.url ?? "" }
    }

    private func runSwitch() async {
        guard let request else { return }
        do {
            try request.validate()
        } catch let error as SVNError {
            note = error.message
            return
        } catch {
            note = error.localizedDescription
            return
        }
        note = nil
        isRunning = true
        defer { isRunning = false }
        session.branchReport = nil
        await session.switchWorkingCopy(to: request)
        if session.branchReport != nil { dismiss() }
    }
}
