import SwiftUI
import OpenSVNCore

/// Side-by-side merge editor for one text conflict: my version, the common
/// ancestor, and the incoming version, with one decision per conflicting region.
///
/// It deliberately does not let the user free-edit the result. A free-form editor
/// makes "which side did I keep here?" unanswerable after the fact, and the
/// question a merge has to answer is exactly that. Decisions are per region;
/// "write" produces the file.
struct MergeEditorView: View {
    @Bindable var session: RepositorySession
    @Bindable var editor: MergeEditorState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if editor.conflicts.isEmpty {
                ContentUnavailableView {
                    Label("没有需要决定的冲突", systemImage: "checkmark.seal")
                } description: {
                    Text("两边的改动互不重叠，直接写入即可。")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(editor.conflicts) { conflict in
                            conflictCard(conflict)
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 880, idealWidth: 940, minHeight: 560, idealHeight: 620)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(editor.path)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !editor.conflicts.isEmpty {
                Button("全部用我的") { editor.chooseAll(.mine) }
                Button("全部用服务器") { editor.chooseAll(.theirs) }
            }
        }
        .padding(14)
    }

    private var subtitle: String {
        let operation = editor.artifacts.operation ?? "冲突"
        let total = editor.conflicts.count
        let pending = editor.unresolved.count
        if total == 0 { return "\(operation) · 无冲突区域" }
        return "\(operation) · 共 \(total) 处冲突，\(pending) 处待决定"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("写入前会把当前的冲突文件备份到应用支持目录。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("写入并标记已解决") {
                session.applyMerge()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!editor.isReadyToWrite)
            .help(editor.isReadyToWrite ? "写入合并结果并以 --accept=working 解决冲突" : "还有冲突未决定")
        }
        .padding(14)
    }

    // MARK: - One conflict

    private func conflictCard(_ conflict: MergeConflict) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("冲突 \(conflict.id + 1)")
                    .font(.subheadline.weight(.semibold))
                Text("基线 \(conflict.baseLines.count) 行 · 我的 \(conflict.mineLines.count) 行 · 服务器 \(conflict.theirsLines.count) 行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if editor.choice(for: conflict.id) == nil {
                    Label("待决定", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                sidePanel("我的", lines: conflict.mineLines, tint: .blue)
                sidePanel("基线", lines: conflict.baseLines, tint: .secondary)
                sidePanel("服务器", lines: conflict.theirsLines, tint: .purple)
            }

            Picker("采用", selection: Binding(
                get: { editor.choice(for: conflict.id) },
                set: { if let value = $0 { editor.choose(value, for: conflict.id) } }
            )) {
                Text("我的").tag(MergeChoice?.some(.mine))
                Text("服务器").tag(MergeChoice?.some(.theirs))
                Text("两者（我的在前）").tag(MergeChoice?.some(.both))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    editor.choice(for: conflict.id) == nil ? Color.orange.opacity(0.6) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    private func sidePanel(_ title: String, lines: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ScrollView(.vertical) {
                Text(lines.isEmpty ? "（删除）" : lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 96)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
