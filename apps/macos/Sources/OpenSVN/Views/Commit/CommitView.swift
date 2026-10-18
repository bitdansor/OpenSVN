import SwiftUI
import OpenSVNCore

struct CommitView: View {
    @Bindable var session: RepositorySession

    var body: some View {
        VStack(spacing: 0) {
            if session.conflictedEntries.isEmpty == false {
                conflictBanner
            }

            HStack(alignment: .top, spacing: 0) {
                fileList
                    .frame(minWidth: 320, idealWidth: 420)

                Divider()

                editor
                    .frame(minWidth: 320)
            }
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("有 \(session.conflictedEntries.count) 个未解决的冲突")
                    .font(.callout.weight(.medium))
                Text("解决冲突并标记 resolve 后才能提交。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("待提交文件")
                    .font(.headline)
                Spacer()
                Button("全选") {
                    session.commitSelection = Set(session.changedEntries.filter { !$0.hasConflicts }.map(\.id))
                }
                .buttonStyle(.link)
                Button("全不选") { session.commitSelection.removeAll() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if session.changedEntries.isEmpty {
                ContentUnavailableView("没有可提交的修改", systemImage: "tray")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(session.changedEntries) { entry in
                        Toggle(isOn: binding(for: entry)) {
                            HStack(spacing: 8) {
                                Image(systemName: entry.category.systemImage)
                                    .foregroundStyle(entry.category.color)
                                Text(session.relativePath(entry.path))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if entry.hasConflicts {
                                    ConflictBadges(flags: entry.conflicts)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(entry.hasConflicts)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("提交说明")
                    .font(.headline)
                Spacer()
                Text("\(session.commitMessage.count) 字符")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)

            TextEditor(text: $session.commitMessage)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
                .padding(.horizontal, 14)
                .frame(minHeight: 160, maxHeight: .infinity)

            Text("提交前会再次读取工作副本状态；发现冲突将中止提交。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)

            HStack {
                Text(commitSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await session.commit() }
                } label: {
                    Label("提交 \(session.commitSelection.count) 项", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.commitSelection.isEmpty
                          || session.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(14)
        }
    }

    private func binding(for entry: StatusEntry) -> Binding<Bool> {
        Binding(
            get: { session.commitSelection.contains(entry.id) },
            set: { isOn in
                if isOn {
                    session.commitSelection.insert(entry.id)
                } else {
                    session.commitSelection.remove(entry.id)
                }
            }
        )
    }

    private var commitSummary: String {
        let selection = session.commitSelection
        let entries = session.changedEntries.filter { selection.contains($0.id) }
        let hasSkippedConflicts = session.changedEntries.contains { $0.hasConflicts && !selection.contains($0.id) }
        if hasSkippedConflicts {
            return "\(entries.count) 项待提交 · 冲突项已排除"
        }
        return "\(entries.count) 项待提交"
    }
}
