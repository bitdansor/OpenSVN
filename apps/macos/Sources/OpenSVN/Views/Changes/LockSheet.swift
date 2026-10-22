import SwiftUI
import OpenSVNCore

/// The "锁定" sheet: which paths, an optional comment, and whether to take the
/// lock away from its current holder.
///
/// A sheet rather than a bare confirmation because the comment is stored in the
/// repository and read by whoever is blocked — it is the only place the reason
/// for the lock can live.
struct LockSheet: View {
    @Bindable var session: RepositorySession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            pathList

            if let editor = session.lockEditor, editor.foreignLockCount > 0 {
                foreignLockNotice(editor)
            }

            stealToggle
            commentField
            footer
        }
        .padding(20)
        .frame(width: 480)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text("锁定会阻止其他人提交这些路径，直到锁被解除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var pathList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array((session.lockEditor?.displayPaths ?? []).prefix(50).enumerated()), id: \.offset) { _, path in
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 140)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    private func foreignLockNotice(_ editor: RepositorySession.LockEditorState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(editor.foreignLockCount) 个路径已被他人锁定")
                    .font(.callout.weight(.medium))
            }
            Text("普通锁定会失败。要拿到这些路径，必须勾选下面的「强制抢占」。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Always visible, never pre-checked.
    ///
    /// The known-locks list is a snapshot from the last refresh; if it is stale,
    /// hiding this toggle would leave "the lock is taken and the app offers no way
    /// forward" with no explanation. A visible, unchecked option plus a
    /// confirmation dialog is both safer and more honest about the uncertainty.
    private var stealToggle: some View {
        Toggle(isOn: Binding(
            get: { session.lockEditor?.steal ?? false },
            set: { session.lockEditor?.steal = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("强制抢占（--force）")
                    .font(.callout)
                Text("移除当前持有人在这个路径上的锁。只有确认对方不再需要时才勾选。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var commentField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("锁定说明（可选）")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("例如：正在修复登录问题", text: Binding(
                get: { session.lockEditor?.comment ?? "" },
                set: { session.lockEditor?.comment = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            Text("说明会保存在仓库里，其他人看得到。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            if let editor = session.lockEditor, editor.ownLockCount > 0 {
                Text("其中 \(editor.ownLockCount) 项已由本工作副本锁定")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") { session.closeLockEditor() }
                .keyboardShortcut(.cancelAction)
            Button("锁定") {
                Task { await session.confirmLock() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(session.lockEditor == nil)
        }
    }

    private var title: String {
        guard let editor = session.lockEditor else { return "锁定" }
        return editor.isBatch ? "锁定 \(editor.paths.count) 项" : "锁定「\(editor.displayPaths.first ?? "")」"
    }
}
