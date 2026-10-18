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
            guide
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

    /// The three-step strip is the whole mental model of a three-way merge. It is
    /// always visible rather than a first-run tooltip: the question "which side am
    /// I looking at?" recurs on every card, not just the first one.
    private var guide: some View {
        HStack(alignment: .top, spacing: 16) {
            step(1, "看三栏", "左边是我的文件，中间是双方共同的基线，右边是服务器上的版本。")
            step(2, "每处选一边", "只有两边都改了同一处才需要决定；单边改动已经自动采用。")
            step(3, "写回文件", "点「写入并标记已解决」，文件内容就是你的决定，冲突随之解除。")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.06))
    }

    private func step(_ index: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("\(index)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
            VStack(alignment: .leading, spacing: 2) {
                Text("写入前会把当前的冲突文件备份到应用支持目录，写错了可以找回。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !editor.unresolved.isEmpty {
                    Text("还有 \(editor.unresolved.count) 处没有决定 —— 每一处都必须选一边，合并结果才不会丢内容。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
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

            // Naming *why* this region needs a decision is what turns three
            // panels of text into a question the user can answer.
            Text(reason(for: conflict))
                .font(.caption)
                .foregroundStyle(editor.choice(for: conflict.id) == nil ? .orange : .secondary)

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

    /// The engine only asks when both sides changed the same region differently,
    /// but the *shape* of the disagreement differs and the label should say which
    /// one it is. The empty-side branches are defensive: `ThreeWayMerge` resolves
    /// one-sided changes by itself, so reaching them would mean the engine changed
    /// and this text would be the first visible symptom.
    private func reason(for conflict: MergeConflict) -> String {
        if conflict.baseLines.isEmpty {
            return "这里原本没有内容，两边各自新增了不同的内容。"
        }
        if conflict.mineLines.isEmpty {
            return "我删掉了这段，服务器改动了它。"
        }
        if conflict.theirsLines.isEmpty {
            return "服务器删掉了这段，我改动了它。"
        }
        return "两边改了同一处，而且内容不同 —— 这是唯一需要你决定的情况。"
    }
}
