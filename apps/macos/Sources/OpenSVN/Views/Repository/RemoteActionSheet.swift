import SwiftUI
import OpenSVNCore

/// Confirms and parameterises one remote write.
///
/// Every operation here commits immediately — svn has no staging for URL targets
/// — so the sheet is the last place a wrong path can be caught. It therefore shows
/// the full URL, not just the trailing name.
struct RemoteActionSheet: View {
    @Bindable var browser: RepositoryBrowser
    @State private var request: RepositoryBrowser.ActionRequest

    init(browser: RepositoryBrowser, request: RepositoryBrowser.ActionRequest) {
        self.browser = browser
        _request = State(initialValue: request)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 560, height: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundStyle(request.isDestructive ? Color.red : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title)
                    .font(.headline)
                Text("这是一次提交，会立刻写进仓库历史。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var iconName: String {
        switch request.kind {
        case .makeDirectory: return "folder.badge.plus"
        case .tag: return "tag"
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        case .delete: return "trash"
        }
    }

    private var form: some View {
        Form {
            if let source = request.sourceURL, request.kind != .makeDirectory {
                LabeledContent("源") {
                    Text(source)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            if request.kind == .delete {
                LabeledContent("将删除") {
                    Text(request.sourceURL ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            } else {
                LabeledContent("目标") {
                    TextField("完整 URL", text: $request.destination)
                        .textFieldStyle(.roundedBorder)
                }
            }

            LabeledContent("提交说明") {
                TextField("会显示在历史里", text: $request.message)
                    .textFieldStyle(.roundedBorder)
            }

            if request.kind == .tag {
                Text("tag 就是一次目录 copy：`svn copy trunk tags/v1.0`。svn 没有单独的 tag 命令，这个约定就是全部。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if request.isDestructive {
                Text("删除后路径会从 HEAD 消失，所有工作副本下次更新时都会收到删除。svn 保留历史，但找回它需要知道修订号并执行命令。")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if browser.isPerforming {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("取消") {
                browser.cancelAction()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(browser.isPerforming)

            Button(request.confirmLabel) {
                Task { await browser.perform(request) }
            }
            .buttonStyle(.borderedProminent)
            .tint(request.isDestructive ? .red : nil)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
        .padding(14)
    }

    private var canSubmit: Bool {
        guard !browser.isPerforming else { return false }
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }
        if request.kind == .delete { return true }
        return !request.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
