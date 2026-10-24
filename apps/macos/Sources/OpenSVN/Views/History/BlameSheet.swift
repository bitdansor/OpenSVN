import SwiftUI
import OpenSVNCore

/// `svn blame` for one file, as a sheet.
///
/// A sheet rather than a tab because annotation is a question about one file,
/// asked while looking at that file — it does not belong in the same rotation as
/// Changes/History/Commit.
struct BlameSheet: View {
    @Bindable var session: RepositorySession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 900, height: 620)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 22))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.blameState?.displayPath ?? "注解")
                    .font(.headline)
                if let result = session.blameState?.result {
                    Text(summaryLine(result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if session.blameState?.isLoading == true {
                    Text("正在逐行归属…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("关闭") { session.dismissBlame() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func summaryLine(_ result: BlameResult) -> String {
        let people = result.authorship
        let parts = people
            .prefix(3)
            .map { "\($0.author) \($0.lines) 行" }
            .joined(separator: " · ")
        let more = people.count > 3 ? " 等 \(people.count) 人" : ""
        let uncommitted = result.uncommittedLineCount
        let tail = uncommitted > 0 ? " · 其中 \(uncommitted) 行未提交" : ""
        return "\(result.lines.count) 行 · \(parts)\(more)\(tail)"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = session.blameState?.error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text("无法注解此文件")
                    .font(.headline)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("重试") { Task { await session.loadBlame() } }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.blameState?.isLoading == true {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = session.blameState?.result {
            if result.isEmpty {
                ContentUnavailableView("没有可注解的行", systemImage: "text.alignleft")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    columnHeader
                    Divider()
                    if result.uncommittedLineCount > 0 {
                        localEditNotice(result)
                    }
                    lineList(result)
                }
            }
        } else {
            Color.clear
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("行").frame(width: 44, alignment: .trailing)
            Text("修订").frame(width: 56, alignment: .leading)
            Text("作者").frame(width: 120, alignment: .leading)
            Text("内容")
            Spacer(minLength: 0)
        }
        .font(.system(.caption2, design: .monospaced).weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func localEditNotice(_ result: BlameResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil.circle")
                .foregroundStyle(.orange)
            Text("其中 \(result.uncommittedLineCount) 行是本地未提交的修改，没有作者归属。")
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
    }

    private func lineList(_ result: BlameResult) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(result.lines) { line in
                    HStack(spacing: 8) {
                        Text("\(line.lineNumber)")
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(.tertiary)
                        Text(line.revision.map { "r\($0)" } ?? "未提交")
                            .frame(width: 56, alignment: .leading)
                            .foregroundStyle(line.revision == nil ? .orange : .primary)
                            .lineLimit(1)
                        Text(line.author ?? "—")
                            .frame(width: 120, alignment: .leading)
                            .foregroundStyle(color(for: line.author, in: result))
                            .lineLimit(1)
                        Text(line.content.isEmpty ? " " : line.content)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 1)
                    .background(rowBackground(for: line, in: result))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func rowBackground(for line: BlameLine, in result: BlameResult) -> Color {
        guard let index = colorIndex(for: line.author, in: result) else {
            return line.revision == nil ? Color.orange.opacity(0.10) : Color.clear
        }
        return palette[index % palette.count].opacity(0.06)
    }

    // MARK: - Author colours

    private let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .brown, .mint]

    /// Index of an author in the "most lines first" order, so the busiest author
    /// is always the same colour across files.
    private func colorIndex(for author: String?, in result: BlameResult) -> Int? {
        let name = author ?? "—"
        return result.authorship.firstIndex { $0.author == name }
    }

    private func color(for author: String?, in result: BlameResult) -> Color {
        guard let index = colorIndex(for: author, in: result) else { return .secondary }
        return palette[index % palette.count]
    }
}
