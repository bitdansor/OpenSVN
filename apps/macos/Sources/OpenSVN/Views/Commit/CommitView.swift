import SwiftUI
import OpenSVNCore

/// The commit page: pick files on the left, write the message above a preview of
/// the selected file's diff.
///
/// The preview lives here rather than sending people back to the Changes page for
/// one last look. Committing is the moment where "did I mean to include this?"
/// gets answered, and answering it should not cost a tab switch plus a
/// re-selection.
struct CommitView: View {
    @Bindable var session: RepositorySession
    /// The commit panel's own history sheet: scoping `session.log` to one file
    /// lets the user answer "who touched this?" without leaving the page.
    @State private var showingHistorySheet = false

    var body: some View {
        VStack(spacing: 0) {
            if session.conflictedEntries.isEmpty == false {
                conflictBanner
            }
            if let summary = session.lastCommit {
                successBanner(summary)
            }

            HSplitView {
                fileList
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)

                editor
                    .frame(minWidth: 380)
            }
        }
        // Showing something instead of an empty placeholder: the first changed
        // file is the one the user most likely wants to look at, and an empty
        // preview pane on arrival reads as "this feature does not work".
        .task {
            guard session.commitPreviewPath == nil,
                  let first = session.changedEntries.first else { return }
            await session.previewDiff(for: first)
        }
        .sheet(isPresented: $showingHistorySheet, onDismiss: {
            Task { await session.clearLogTarget() }
        }) {
            CommitFileHistorySheet(session: session)
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.n("有 %d 个未解决的冲突", session.conflictedEntries.count))
                    .font(.callout.weight(.medium))
                Text(L.t("解决冲突并标记 resolve 后才能提交。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let first = session.conflictedEntries.first {
                Button(L.t("用外部工具解决")) {
                    session.resolveWithExternalTool(first)
                }
                .controlSize(.small)
                .help(L.f("用「扩展设置」里配置的三方合并工具处理「%@」", String(describing: session.relativePath(first.path))))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private func successBanner(_ summary: CommitSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.revision.map { L.f("已提交为 r%@", String(describing: $0)) } ?? L.t("已提交"))
                    .font(.callout.weight(.medium))
                if !summary.committedPaths.isEmpty {
                    Text(L.n("包含 %d 个路径", summary.committedPaths.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }

    // MARK: - File list

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L.t("待提交文件"))
                    .font(.headline)
                Spacer()
                Button(L.t("全选")) {
                    session.commitSelection = Set(session.changedEntries.filter { !$0.hasConflicts }.map(\.id))
                }
                .buttonStyle(.link)
                Button(L.t("全不选")) { session.commitSelection.removeAll() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if session.changedEntries.isEmpty {
                ContentUnavailableView(L.t("没有可提交的修改"), systemImage: "tray")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(session.changedEntries) { entry in
                        row(entry)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ entry: StatusEntry) -> some View {
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
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // Clicking the name previews; the checkbox stays the only thing that
            // changes what will be committed.
            .onTapGesture {
                Task { await session.previewDiff(for: entry) }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(entry.hasConflicts)
        .contextMenu {
            Button(L.t("查看此文件历史…")) {
                showingHistorySheet = true
                Task { await session.showHistory(for: entry) }
            }
            Button(L.t("注解 / 作者…")) {
                session.openBlame(for: entry)
            }
            .disabled(entry.item == .unversioned)
        }
    }

    // MARK: - Message + preview

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            messageHeader
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
                .frame(minHeight: 120, idealHeight: 160, maxHeight: 240)

            Text(L.t("提交前会再次读取工作副本状态；发现冲突将中止提交，说明与勾选会保留。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)

            TicketLinksBar(text: session.commitMessage)
                .padding(.horizontal, 14)
                .padding(.top, 6)

            Divider()
                .padding(.top, 8)

            preview
                .frame(maxHeight: .infinity)

            footer
        }
    }

    private var messageHeader: some View {
        HStack {
            Text(L.t("提交说明"))
                .font(.headline)
            if !session.recentCommitMessages.isEmpty {
                Menu {
                    ForEach(session.recentCommitMessages, id: \.self) { message in
                        Button(firstLine(of: message)) {
                            session.commitMessage = message
                        }
                    }
                } label: {
                    Label(L.t("最近说明"), systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L.t("复用之前的提交说明"))
            }
            Spacer()
            Text(L.f("%@ 字符", String(describing: session.commitMessage.count)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                if let path = session.commitPreviewPath {
                    Text(session.relativePath(path))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(L.t("差异预览"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let diff = session.commitPreviewDiff {
                    if diff.isTruncated {
                        StatusBadge(text: L.t("已截断"), color: .orange)
                    }
                    Text(L.f("%@ 字节", String(describing: diff.byteCount)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            if let diff = session.commitPreviewDiff, !diff.isEmpty {
                DiffTextView(text: diff.text)
            } else if session.commitPreviewPath != nil {
                ContentUnavailableView {
                    Label(L.t("没有文本差异"), systemImage: "equal.circle")
                } description: {
                    Text(L.t("可能是二进制文件、新目录，或只有属性变化。"))
                        .font(.caption)
                }
                .frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(L.t("选择文件查看差异"), systemImage: "cursorarrow.click")
                } description: {
                    Text(L.t("点击左侧文件名，提交前再确认一次改了什么。"))
                        .font(.caption)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(commitSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await session.commit() }
            } label: {
                Label(L.n("提交 %d 项", session.commitSelection.count), systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.commitSelection.isEmpty
                      || session.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(14)
    }

    // MARK: - Helpers

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

    private func firstLine(of message: String) -> String {
        let line = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? message
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    private var commitSummary: String {
        let selection = session.commitSelection
        let entries = session.changedEntries.filter { selection.contains($0.id) }
        let hasSkippedConflicts = session.changedEntries.contains { $0.hasConflicts && !selection.contains($0.id) }
        if hasSkippedConflicts {
            return L.n("%d 项待提交 · 冲突项已排除", entries.count)
        }
        return L.n("%d 项待提交", entries.count)
    }
}
