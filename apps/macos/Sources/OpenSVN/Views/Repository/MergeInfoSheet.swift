import SwiftUI
import OpenSVNCore

/// Read-only view of merge tracking for this working copy.
///
/// Two different facts live here and they are easy to confuse:
/// - the stored `svn:mergeinfo` property, which is what svn *recorded*;
/// - `svn mergeinfo --show-revs`, which is what svn would *do* next for a given
///   source.
/// The first is local and always available; the second needs a source URL and a
/// round trip, so it is asked for explicitly instead of on open.
struct MergeInfoSheet: View {
    @Bindable var session: RepositorySession
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
    }

    private var state: RepositorySession.MergeInfoSnapshot? {
        session.mergeInfoSnapshot
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(L.t("合并记录"))
                    .font(.headline)
                Text(state?.target ?? session.path.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                Task { await session.loadMergeInfo(source: source) }
            } label: {
                Label(L.t("重新读取"), systemImage: "arrow.clockwise")
            }
            .disabled(state?.isLoading ?? true)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = state?.failure {
            ContentUnavailableView {
                Label(L.t("读不到合并记录"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            }
        } else if state?.isLoading == true, state?.lines.isEmpty ?? true {
            VStack(spacing: 10) {
                ProgressView()
                Text(L.t("正在读取 svn:mergeinfo…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    recordedSection
                    querySection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var recordedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("已记录的合并（svn:mergeinfo）"))
                .font(.headline)
            if let lines = state?.lines, !lines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.sourcePath)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(rangeSummary(line.ranges))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            } else {
                Text(L.t("这个路径上没有任何合并记录。首次成功合并之后 svn 才会写入 svn:mergeinfo。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var querySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("某个来源还有哪些没收"))
                .font(.headline)
            HStack(spacing: 8) {
                TextField(L.t("来源 URL，例如 https://…/trunk"), text: $source)
                    .textFieldStyle(.roundedBorder)
                Button(L.t("查询")) {
                    Task { await session.loadMergeInfo(source: source) }
                }
                .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || state?.isLoading == true)
            }
            Text(L.t("svn mergeinfo --show-revs eligible：只读，不碰工作副本，但要访问服务器。"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !(state?.source.isEmpty ?? true) {
                revisionRow(L.t("待合并"), revisions: state?.eligible ?? [], tint: .blue)
                revisionRow(L.t("已合并"), revisions: state?.merged ?? [], tint: .secondary)
            }
        }
    }

    private func revisionRow(_ title: String, revisions: [Int64], tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(revisions.isEmpty ? L.t("无") : revisions.map { "r\($0)" }.joined(separator: " "))
                .font(.caption.monospaced())
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L.t("关闭")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    /// Ranges stay ranges on screen too: `1-100000` printed as a list would be
    /// unreadable and would lie about what is stored.
    private func rangeSummary(_ ranges: [MergeInfoRange]) -> String {
        guard !ranges.isEmpty else { return "" }
        return ranges.map { range in
            let body = range.lower == range.upper ? "\(range.lower)" : "\(range.lower)-\(range.upper)"
            return range.nonInheritable ? body + "*" : body
        }.joined(separator: ",")
    }
}
