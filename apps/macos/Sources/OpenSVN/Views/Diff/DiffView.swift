import AppKit
import SwiftUI
import OpenSVNCore

struct DiffView: View {
    @Bindable var session: RepositorySession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let diff = session.diff, !diff.isEmpty {
                DiffTextView(text: diff.text)
            } else if session.isLoading {
                ProgressView("正在生成差异…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("没有差异", systemImage: "plus.forwardslash.minus")
                } description: {
                    Text("在「变更」页双击文件，或在「历史」页选择修订版本后查看差异。")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text(session.diffTitle.isEmpty ? "差异" : session.diffTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let diff = session.diff {
                if diff.isTruncated {
                    StatusBadge(text: "已截断", color: .orange)
                }
                Text("\(diff.byteCount) 字节")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    copyToPasteboard(diff.text)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Renders a unified diff with per-line colouring.
///
/// Deliberately line-based instead of constructing one huge `Text`: large
/// diffs stay scrollable, and the line cap keeps SwiftUI's layout cost bounded.
struct DiffTextView: View {
    let text: String
    private let lineLimit = 6_000

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(lineLimit).enumerated()), id: \.offset) { _, line in
                    Text(String(line).isEmpty ? " " : String(line))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(color(for: String(line)))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: String(line)))
                }
                if lines.count > lineLimit {
                    Text("… 其余 \(lines.count - lineLimit) 行未显示")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .purple }
        if line.hasPrefix("Index:") || line.hasPrefix("====") { return .secondary }
        if line.hasPrefix("Property changes on:") { return .orange }
        return .primary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Color.green.opacity(0.10) }
        if line.hasPrefix("-") { return Color.red.opacity(0.10) }
        if line.hasPrefix("@@") { return Color.purple.opacity(0.08) }
        return .clear
    }
}
