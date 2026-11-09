import AppKit
import SwiftUI
import OpenSVNCore

/// 改深度 — moving one path in a sparse working copy to another depth.
///
/// This is the counterpart to the 检出深度 picker: without it, a working copy
/// checked out at `immediates` could never be widened or narrowed again, because
/// `svn update` alone does not change depth. It is a sheet rather than a menu
/// item with fixed choices because the target path matters: changing depth at
/// the root and changing it on one subdirectory are different operations.
struct DepthSheet: View {
    @Bindable var session: RepositorySession
    @Environment(\.dismiss) private var dismiss

    @State private var target: URL
    @State private var current: WorkingCopyDepth?
    @State private var selected: WorkingCopyDepth = .infinity
    @State private var isLoading = true
    @State private var isRunning = false
    @State private var note: String?

    init(session: RepositorySession) {
        self.session = session
        _target = State(initialValue: session.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section(L.t("目标")) {
                    LabeledContent(L.t("路径")) {
                        HStack(spacing: 6) {
                            Text(displayPath)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            Button(L.t("选择…")) { chooseTarget() }
                                .disabled(isRunning)
                        }
                    }
                    LabeledContent(L.t("当前深度")) {
                        Text(currentLabel)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(L.t("改为")) {
                    Picker(L.t("深度"), selection: $selected) {
                        ForEach(WorkingCopyDepth.allCases, id: \.self) { depth in
                            Text(depth.displayName).tag(depth)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(isRunning)

                    Text(selected.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let warning = selected.warning {
                        Label {
                            Text(warning)
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(selected.removesContent ? .red : .orange)
                        }
                    }
                    if let note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text(L.t("改深度只影响磁盘上有多少内容，不改动仓库，也不需要提交。排除（exclude）是唯一会删除文件的一项：被排除的路径仓库不再记得，要取回得重新设一个深度。被排除过的目录不能靠「完整」自动回来，得在它自己那一层再设一次。"))
                        .font(.caption2)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .task { await loadCurrent() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(L.f("改变「%@」的深度", String(describing: session.displayName)))
                    .font(.headline)
                Text(L.t("决定这个路径在磁盘上保留多少内容（svn update --set-depth）。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isRunning { ProgressView().controlSize(.small) }
            Spacer()
            Button(L.t("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isRunning)
            Button(isRunning ? L.t("应用中…") : L.t("应用")) {
                Task { await apply() }
            }
            .buttonStyle(.borderedProminent)
            .tint(selected.removesContent ? .red : nil)
            .keyboardShortcut(.defaultAction)
            .disabled(isRunning || isLoading || selected == current)
        }
        .padding(14)
    }

    /// Shows the path relative to the working copy when it is inside it, so a
    /// long `/Users/…/trunk/sub` does not hide which part is being changed.
    private var displayPath: String {
        let root = session.path.standardizedFileURL.path
        let path = target.standardizedFileURL.path
        if path == root { return L.t("（工作副本根目录）") }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }

    private var currentLabel: String {
        if isLoading { return L.t("读取中…") }
        return current?.displayName ?? L.t("未知")
    }

    private func loadCurrent() async {
        isLoading = true
        let depth = await session.currentDepth(at: target)
        current = depth
        if let depth { selected = depth }
        isLoading = false
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = target
        panel.message = L.t("选择要改变深度的工作副本目录")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = session.path.standardizedFileURL.path
        let chosen = url.standardizedFileURL.path
        guard chosen == root || chosen.hasPrefix(root + "/") else {
            note = L.t("只能选择这个工作副本里面的目录。")
            return
        }
        note = nil
        target = url.standardizedFileURL
        Task { await loadCurrent() }
    }

    private func apply() async {
        note = nil
        isRunning = true
        defer { isRunning = false }
        let ok = await session.changeDepth(of: target, to: selected)
        if ok {
            dismiss()
        } else {
            // `presentedError` is shown by the window's alert; keep the sheet so
            // the user does not have to re-pick everything after reading it.
            note = L.t("改深度失败，详情见弹窗。")
        }
    }
}
