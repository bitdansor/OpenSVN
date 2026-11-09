import OpenSVNCore
import SwiftUI

/// History for one file, opened from the commit panel.
///
/// It reads the same `session.log` the History page uses (already scoped by
/// `showHistory(for:)`), so switching pages is not required just to answer
/// "who touched this file and why". Message bodies render ticket links.
struct CommitFileHistorySheet: View {
    @Bindable var session: RepositorySession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRevision: Int64?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 280, idealWidth: 340)
                detail
                    .frame(minWidth: 340)
            }
        }
        .frame(width: 860, height: 520)
        .onAppear {
            if selectedRevision == nil {
                selectedRevision = session.filteredLog.first?.revision
            }
        }
        .onChange(of: session.filteredLog.first?.revision) { _, revision in
            if selectedRevision == nil, let revision {
                selectedRevision = revision
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.t("文件历史"))
                    .font(.headline)
                Text(session.logTarget ?? session.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if session.isLogLoading {
                ProgressView().controlSize(.small)
            }
            Button(L.t("关闭")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var list: some View {
        if session.filteredLog.isEmpty && session.isLogLoading {
            ProgressView(L.t("正在读取历史…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedRevision) {
                ForEach(session.filteredLog) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("r\(entry.revision)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                            Text(entry.author ?? "unknown")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(RelativeTime.string(entry.date))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(firstLine(of: entry.message))
                            .font(.callout)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 3)
                    .tag(entry.revision)
                }
                if session.logHasMore {
                    Button {
                        Task { await session.loadLog(reset: false) }
                    } label: {
                        HStack { Spacer(); Text(L.t("加载更早的提交")); Spacer() }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let revision = selectedRevision,
           let entry = session.log.first(where: { $0.revision == revision }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("r\(entry.revision)")
                            .font(.title2.monospacedDigit().weight(.semibold))
                        Spacer()
                        if let author = entry.author {
                            Text(author)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(RelativeTime.absolute(entry.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    TicketLinkedText(text: entry.message.isEmpty ? L.t("（无提交说明）") : entry.message)
                        .font(.body)
                    if !entry.changedPaths.isEmpty {
                        Divider()
                        Text(L.f("变更路径（%@）", String(describing: entry.changedPaths.count)))
                            .font(.headline)
                        ForEach(entry.changedPaths, id: \.self) { path in
                            HStack(spacing: 6) {
                                Text(path.action.rawValue)
                                    .font(.caption2.monospaced().weight(.bold))
                                    .frame(width: 14)
                                Text(path.path)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(L.t("选择一个修订版本"), systemImage: "clock.arrow.circlepath")
                .frame(maxHeight: .infinity)
        }
    }

    private func firstLine(of message: String) -> String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? L.t("（无提交说明）")
    }
}
