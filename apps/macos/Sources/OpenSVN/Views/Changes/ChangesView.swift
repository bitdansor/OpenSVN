import SwiftUI
import OpenSVNCore

struct ChangesView: View {
    @Bindable var session: RepositorySession
    @Binding var tab: RepositoryTab

    var body: some View {
        VStack(spacing: 0) {
            if session.status != nil, !session.conflictedEntries.isEmpty {
                ConflictGuideBanner(session: session)
            }
            if session.status == nil {
                ProgressView("正在读取工作副本…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.status?.isEmpty == true {
                ContentUnavailableView {
                    Label("工作副本干净", systemImage: "checkmark.seal")
                } description: {
                    Text("没有本地修改。")
                } actions: {
                    Button("更新") { Task { await session.requestUpdate() } }
                }
            } else if filteredEntries.isEmpty {
                // Distinct from "clean": the working copy has changes, the
                // filter is hiding them. Saying "干净" here would be a lie.
                ContentUnavailableView {
                    Label("没有匹配的文件", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("「\(session.filterText)」没有匹配任何变更。")
                } actions: {
                    Button("清除过滤") { session.filterText = "" }
                }
            } else {
                list
            }
            Divider()
            actionBar
        }
        .sheet(item: $session.mergeEditor) { editor in
            MergeEditorView(session: session, editor: editor)
        }
        .sheet(item: $session.lockEditor) { _ in
            LockSheet(session: session)
        }
    }

    private var list: some View {
        List(selection: $session.selectedPaths) {
            ForEach(orderedCategories, id: \.self) { category in
                let entries = grouped[category] ?? []
                if !entries.isEmpty {
                    Section {
                        ForEach(entries) { entry in
                            row(entry)
                                .tag(entry.id)
                                .contextMenu { contextMenu(for: entry) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: category.systemImage)
                                .foregroundStyle(category.color)
                            Text("\(category.title) · \(entries.count)")
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        // System search field rather than a hand-rolled one: it brings ⌘F, the
        // clear button, and the platform's own Escape handling with it.
        .searchable(
            text: $session.filterText,
            placement: .toolbar,
            prompt: "过滤文件（空格分隔多个关键词）"
        )
    }

    private func row(_ entry: StatusEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.category.systemImage)
                .foregroundStyle(entry.category.color)
                .frame(width: 16)

            Text(session.relativePath(entry.path))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            if let changelist = entry.changelist {
                StatusBadge(text: changelist, color: .blue)
            }
            if entry.hasConflicts {
                ConflictBadges(flags: entry.conflicts)
            }
            // The inline button is the discoverable path. The context menu keeps
            // the same action for consistency, but a capability that only exists
            // in a right-click menu is a capability most users never learn.
            if entry.hasConflicts, entry.conflicts.contains(.text) {
                Button {
                    session.beginMerge(entry)
                } label: {
                    Label("三方合并", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("并排比较我的改动、基线和服务器改动，逐块决定保留哪一边")
            }
            // The badge tells the two situations apart: an orange lock is ours
            // (releasable), a red one belongs to someone else (only a steal
            // clears it). Collapsing them into "locked" invites a failed commit
            // with no explanation.
            if let lock = session.lock(for: entry) {
                Label(lock.owner ?? "已锁定", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(session.isOwnLock(entry) ? .orange : .red)
                    .help(lockHelp(lock, own: session.isOwnLock(entry)))
            }
            if entry.isWorkingCopyLocked {
                StatusBadge(text: "需清理", color: .orange)
            }
            if entry.properties == .modified {
                StatusBadge(text: "属性", color: .purple)
            }
            Text(entry.item.rawValue)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task {
                await session.loadDiff(for: entry)
                tab = .diff
            }
        }
        .help(entry.path)
    }

    @ViewBuilder
    private func contextMenu(for entry: StatusEntry) -> some View {
        Button("查看差异") {
            Task {
                await session.loadDiff(for: entry)
                tab = .diff
            }
        }
        if entry.item == .unversioned {
            Button("添加到版本控制") {
                Task { await session.add([entry.id]) }
            }
            Button("忽略此文件") {
                Task { await session.ignore([entry.id]) }
            }
            if !extensionOf(entry).isEmpty {
                Button("忽略所有 .\(extensionOf(entry)) 文件") {
                    Task { await session.ignoreExtension(of: entry) }
                }
            }
            Divider()
        }
        Button("属性…") {
            session.openProperties(for: entry)
        }
        if entry.hasConflicts {
            Menu("解决冲突") {
                if entry.conflicts.contains(.text) {
                    Button {
                        session.beginMerge(entry)
                    } label: {
                        Label("三方合并…", systemImage: "arrow.triangle.branch")
                    }
                    .help("并排比较我的改动、基线和服务器改动，逐块选择")
                    Divider()
                }
                ForEach(ResolveStrategy.allCases, id: \.self) { strategy in
                    Button {
                        session.resolve(entry, strategy: strategy)
                    } label: {
                        Label(strategy.title, systemImage: strategy.menuSymbol)
                    }
                    .help(strategy.consequence)
                }
            }
        }
        lockMenu(for: [entry])
        Divider()
        Button("还原本地修改…", role: .destructive) {
            session.requestRevert([entry.id])
        }
        Button("删除…", role: .destructive) {
            session.requestDelete([entry.id])
        }
    }

    /// Lock actions for one or more entries.
    ///
    /// Only versioned paths can be locked, and the offered action depends on who
    /// holds the lock: taking again what we already hold can only fail.
    @ViewBuilder
    private func lockMenu(for entries: [StatusEntry]) -> some View {
        let lockable = entries.filter { $0.item != .unversioned && $0.item != .ignored }
        if !lockable.isEmpty {
            Divider()
            let path = lockable.map(\.id)
            if lockable.contains(where: { session.isOwnLock($0) }) {
                Button("解除锁定…") { session.requestUnlock(path) }
            }
            if lockable.contains(where: { session.lock(for: $0) == nil }) {
                Button("锁定…") { session.openLockEditor(for: path) }
            }
            if lockable.contains(where: { session.lock(for: $0) != nil && !session.isOwnLock($0) }) {
                Button("强制抢占锁定…") { session.openLockEditor(for: path) }
            }
        }
    }

    private func lockHelp(_ lock: RepositoryLock, own: Bool) -> String {
        var lines: [String] = []
        lines.append(own ? "本工作副本持有该锁" : "锁由 \(lock.owner ?? "他人") 持有")
        if let comment = lock.comment, !comment.isEmpty {
            lines.append("说明：\(comment)")
        }
        if let created = lock.createdAt {
            lines.append("锁定于 \(created.formatted(date: .abbreviated, time: .shortened))")
        }
        if !own {
            lines.append("解除需要强制，且会让对方无法提交。")
        }
        return lines.joined(separator: "\n")
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await session.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }

            Divider().frame(height: 16)

            Button {
                tab = .commit
            } label: {
                Label("去提交", systemImage: "arrow.up.doc")
            }
            .disabled(session.changedEntries.isEmpty)

            Spacer()

            Text(selectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                Button("添加到版本控制") { Task { await session.add(unversionedSelection) } }
                    .disabled(unversionedSelection.isEmpty)
                Button("忽略所选文件") { Task { await session.ignore(unversionedSelection) } }
                    .disabled(unversionedSelection.isEmpty)
                    .help("把所选文件加入各自目录的 svn:ignore")
                Button("属性…") {
                    guard let entry = selectedEntries.first, selectedEntries.count == 1 else { return }
                    session.openProperties(for: entry)
                }
                .disabled(selectedEntries.count != 1)
                lockMenu(for: selectedEntries)
                Button(session.isLockLoading ? "正在查询锁定…" : "刷新锁定状态") {
                    Task { await session.refreshLocks() }
                }
                .disabled(session.isLockLoading)
                .help("向服务器查询这些文件上的锁（包括他人持有的）")
                Button("还原…") { session.requestRevert(Array(session.selectedPaths)) }
                    .disabled(session.selectedPaths.isEmpty)
                Button("删除…") { session.requestDelete(Array(session.selectedPaths)) }
                    .disabled(session.selectedPaths.isEmpty)
                Divider()
                Button("查看差异") {
                    guard let entry = selectedEntries.first else { return }
                    Task {
                        await session.loadDiff(for: entry)
                        tab = .diff
                    }
                }
                .disabled(selectedEntries.isEmpty)

                Divider()

                Menu("解决全部冲突（\(session.conflictedEntries.count)）") {
                    ForEach(ResolveStrategy.allCases, id: \.self) { strategy in
                        Button {
                            session.resolveAllConflicts(strategy: strategy)
                        } label: {
                            Label(strategy.title, systemImage: strategy.menuSymbol)
                        }
                        .help(strategy.consequence)
                    }
                }
                .disabled(session.conflictedEntries.isEmpty)
            } label: {
                Label("操作", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var selectionSummary: String {
        var parts: [String] = []
        if !session.filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("显示 \(filteredEntries.count) / \(session.status?.entries.count ?? 0) 项")
        }
        if session.selectedPaths.isEmpty {
            parts.append("未选择")
        } else {
            parts.append("已选择 \(session.selectedPaths.count) 项")
        }
        return parts.joined(separator: " · ")
    }

    private var grouped: [StatusCategory: [StatusEntry]] {
        Dictionary(grouping: filteredEntries, by: \.category)
    }

    /// The entries the filter lets through.
    ///
    /// Every whitespace-separated term has to match somewhere in the relative
    /// path, which makes "src retry" mean "inside src, named retry" instead of
    /// "anything called src or retry". Matching the whole path rather than the
    /// file name is what makes directory filtering work without a second field.
    private var filteredEntries: [StatusEntry] {
        let raw = session.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = session.status?.entries ?? []
        guard !raw.isEmpty else { return all }
        let terms = raw.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        return all.filter { entry in
            let haystack = session.relativePath(entry.path).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private var orderedCategories: [StatusCategory] {
        StatusCategory.allCases
            .filter { !(grouped[$0] ?? []).isEmpty }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var selectedEntries: [StatusEntry] {
        (session.status?.entries ?? []).filter { session.selectedPaths.contains($0.id) }
    }

    private var unversionedSelection: [String] {
        selectedEntries.filter { $0.item == .unversioned }.map(\.id)
    }

    private func extensionOf(_ entry: StatusEntry) -> String {
        URL(fileURLWithPath: entry.path).pathExtension
    }
}
