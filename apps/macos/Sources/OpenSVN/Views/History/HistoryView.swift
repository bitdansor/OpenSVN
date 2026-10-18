import SwiftUI
import OpenSVNCore

struct HistoryView: View {
    @Bindable var session: RepositorySession
    @Binding var tab: RepositoryTab
    @State private var selectedRevision: Int64?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
            detail
                .frame(minWidth: 340)
        }
        .task {
            if session.log.isEmpty {
                await session.loadLog(reset: true)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史")
                    .font(.headline)
                Spacer()
                if session.isLogLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await session.loadLog(reset: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(session.isLogLoading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if session.log.isEmpty {
                ContentUnavailableView("尚无历史", systemImage: "clock")
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedRevision) {
                    ForEach(session.log) { entry in
                        row(entry)
                            .tag(entry.revision)
                    }
                    if session.logHasMore {
                        Button {
                            Task { await session.loadLog(reset: false) }
                        } label: {
                            HStack {
                                Spacer()
                                if session.isLogLoading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("加载更早的提交")
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("r\(entry.revision)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.14)))
                Text(entry.author ?? "unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(RelativeTime.string(entry.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(firstLine(of: entry.message))
                .font(.callout)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { selectedRevision = entry.revision }
    }

    @ViewBuilder
    private var detail: some View {
        if let revision = selectedRevision,
           let entry = session.log.first(where: { $0.revision == revision }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("r\(entry.revision)")
                            .font(.title2.monospacedDigit().weight(.semibold))
                        Spacer()
                        Button {
                            Task {
                                await session.loadDiffForRevision(entry.revision, entry: entry)
                                tab = .diff
                            }
                        } label: {
                            Label("查看此版本差异", systemImage: "plus.forwardslash.minus")
                        }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("作者").foregroundStyle(.secondary)
                            Text(entry.author ?? "—")
                        }
                        GridRow {
                            Text("时间").foregroundStyle(.secondary)
                            Text(RelativeTime.absolute(entry.date))
                        }
                    }
                    .font(.callout)

                    Divider()

                    Text(entry.message.isEmpty ? "（无提交说明）" : entry.message)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !entry.changedPaths.isEmpty {
                        Divider()
                        Text("变更路径（\(entry.changedPaths.count)）")
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(entry.changedPaths, id: \.self) { path in
                                HStack(spacing: 6) {
                                    Text(path.action.rawValue)
                                        .font(.caption2.monospaced().weight(.bold))
                                        .foregroundStyle(color(for: path.action))
                                        .frame(width: 14)
                                    Text(path.path)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                    if let copyFrom = path.copyFromPath {
                                        Text("← \(copyFrom)@\(path.copyFromRevision.map(String.init) ?? "?")")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("选择一个修订版本", systemImage: "clock.arrow.circlepath")
                .frame(maxHeight: .infinity)
        }
    }

    private func firstLine(of message: String) -> String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "（无提交说明）"
    }

    private func color(for action: ChangedPath.Action) -> Color {
        switch action {
        case .added: return .green
        case .deleted: return .red
        case .modified: return .orange
        case .replaced: return .purple
        case .unknown: return .secondary
        }
    }
}
