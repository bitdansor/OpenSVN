import AppKit
import SwiftUI
import OpenSVNCore

/// Creates a brand-new local repository with `svnadmin create`.
///
/// This is the one place in the app that does not need a server: a repository on
/// disk is enough to try merging, branching and history on, and the `file://`
/// URL it returns is a fully working repository. The sheet therefore offers to
/// check the new repository out immediately — ending with a working copy in the
/// sidebar rather than a URL to paste somewhere else.
struct NewLocalRepositorySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var location = NSHomeDirectory() + "/OpenSVN/repositories/"
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var created: LocalRepository?
    @State private var checkedOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("新建本地仓库"))
                        .font(.headline)
                    Text(L.t("在这台 Mac 上创建仓库，不需要服务器。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                HStack {
                    TextField(L.t("仓库目录"), text: $location)
                        .textFieldStyle(.roundedBorder)
                        .disabled(created != nil)
                    Button(L.t("选择…")) { chooseLocation() }
                        .disabled(created != nil)
                }
                if let created {
                    LabeledContent(L.t("仓库 URL")) {
                        Text(created.url)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }

            Text(L.t("这会执行 `svnadmin create`。目标目录必须不存在或为空——已存在非空目录会被拒绝，不会覆盖任何东西。勾选下面的选项时会同时检出这个仓库，得到一个可提交的工作副本（与其同级的 `<名称>-wc` 目录）。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if checkedOut {
                    Label(L.t("已创建并检出"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(created == nil ? L.t("取消") : L.t("完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(buttonTitle) {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || trimmedLocation.isEmpty || created != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var buttonTitle: String {
        if isRunning { return L.t("创建中…") }
        return L.t("创建并检出")
    }

    private var trimmedLocation: String {
        location.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L.t("在此新建")
        panel.message = L.t("选择新仓库的父目录，仓库会建在里面")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let parent = chosen.path.hasSuffix("/") ? chosen.path : chosen.path + "/"
        location = parent + "repository"
    }

    private func create() async {
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            let repository = try await appState.createLocalRepositoryAndCheckout(
                at: URL(fileURLWithPath: trimmedLocation)
            )
            created = repository
            checkedOut = true
        } catch let error as SVNError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
