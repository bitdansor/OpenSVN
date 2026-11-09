import AppKit
import SwiftUI
import OpenSVNCore

struct ChangesView: View {
    @Bindable var session: RepositorySession
    @Binding var tab: RepositoryTab
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            if session.status != nil, !session.conflictedEntries.isEmpty {
                ConflictGuideBanner(session: session)
            }
            // The status area claims the leftover height explicitly. Neither
            // `ContentUnavailableView` nor `ProgressView` grows on its own, so a
            // VStack that merely hugs its children leaves the action bar
            // hovering in the middle of the window with dead space below it.
            statusArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            actionBar
        }
        // Finder drops land on this page: the modifier resolves the file URLs
        // and routes them through `session.confirmImport`, so nothing is written
        // until the existing confirmation dialog is accepted.
        .modifier(WorkcopyDropImport(session: session))
        .sheet(item: $session.mergeEditor) { editor in
            MergeEditorView(session: session, editor: editor)
        }
        .sheet(item: $session.lockEditor) { _ in
            LockSheet(session: session)
        }
        .sheet(isPresented: Binding(
            get: { quickLookURL != nil },
            set: { if !$0 { quickLookURL = nil } }
        )) {
            if let quickLookURL {
                QuickLookSheet(url: quickLookURL)
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if session.status == nil {
            ProgressView(L.t("正在读取工作副本…"))
        } else if session.status?.isEmpty == true {
            ContentUnavailableView {
                Label(L.t("工作副本干净"), systemImage: "checkmark.seal")
            } description: {
                Text(L.t("没有本地修改。"))
            } actions: {
                Button(L.t("更新")) { Task { await session.requestUpdate() } }
            }
        } else if filteredEntries.isEmpty {
            // Distinct from "clean": the working copy has changes, the
            // filter is hiding them. Saying "干净" here would be a lie.
            ContentUnavailableView {
                Label(L.t("没有匹配的文件"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(L.f("「%@」没有匹配任何变更。", String(describing: session.filterText)))
            } actions: {
                Button(L.t("清除过滤")) { session.filterText = "" }
            }
        } else {
            list
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
                                .modifier(ChangesRowDragSource(url: session.entryURL(entry)))
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
            prompt: L.t("过滤文件（空格分隔多个关键词）")
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

            if entry.isInsideExternal(externalRoots) {
                // svn lists these next to the parent's own changes but refuses to
                // commit them; without a badge the row looks like any other edit.
                StatusBadge(text: L.t("外部"), color: .blue)
                    .help(L.t("该路径位于 svn:externals 挂载的工作副本内，要提交得去那个工作副本"))
            }
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
                    Label(L.t("三方合并"), systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L.t("并排比较我的改动、基线和服务器改动，逐块决定保留哪一边"))
            }
            // The badge tells the two situations apart: an orange lock is ours
            // (releasable), a red one belongs to someone else (only a steal
            // clears it). Collapsing them into "locked" invites a failed commit
            // with no explanation.
            if let lock = session.lock(for: entry) {
                Label(lock.owner ?? L.t("已锁定"), systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(session.isOwnLock(entry) ? .orange : .red)
                    .help(lockHelp(lock, own: session.isOwnLock(entry)))
            }
            if entry.isWorkingCopyLocked {
                StatusBadge(text: L.t("需清理"), color: .orange)
            }
            if entry.properties == .modified {
                StatusBadge(text: L.t("属性"), color: .purple)
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
        Button(L.t("查看差异")) {
            Task {
                await session.loadDiff(for: entry)
                tab = .diff
            }
        }
        if entry.item == .unversioned {
            Button(L.t("添加到版本控制")) {
                Task { await session.add([entry.id]) }
            }
            Button(L.t("忽略此文件")) {
                Task { await session.ignore([entry.id]) }
            }
            if !extensionOf(entry).isEmpty {
                Button(L.f("忽略所有 .%@ 文件", String(describing: extensionOf(entry)))) {
                    Task { await session.ignoreExtension(of: entry) }
                }
            }
            Divider()
        }
        if entry.item != .unversioned, entry.item != .ignored {
            Button(L.t("查看此文件的历史")) {
                Task {
                    await session.showHistory(for: entry)
                    tab = .history
                }
            }
            Button(L.t("注解（谁写的）…")) {
                session.openBlame(for: entry)
            }
            Divider()
        }
        Button(L.t("属性…")) {
            session.openProperties(for: entry)
        }
        if entry.hasConflicts {
            Menu(L.t("解决冲突")) {
                if entry.conflicts.contains(.text) {
                    Button {
                        session.beginMerge(entry)
                    } label: {
                        Label(L.t("三方合并…"), systemImage: "arrow.triangle.branch")
                    }
                    .help(L.t("并排比较我的改动、基线和服务器改动，逐块选择"))
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
        Button(L.t("还原本地修改…"), role: .destructive) {
            session.requestRevert([entry.id])
        }
        Button(L.t("删除…"), role: .destructive) {
            session.requestDelete([entry.id])
        }
        Divider()
        ChangesRowQuickActions(url: session.entryURL(entry)) { url in
            quickLookURL = url
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
                Button(L.t("解除锁定…")) { session.requestUnlock(path) }
            }
            if lockable.contains(where: { session.lock(for: $0) == nil }) {
                Button(L.t("锁定…")) { session.openLockEditor(for: path) }
            }
            if lockable.contains(where: { session.lock(for: $0) != nil && !session.isOwnLock($0) }) {
                Button(L.t("强制抢占锁定…")) { session.openLockEditor(for: path) }
            }
        }
    }

    private func lockHelp(_ lock: RepositoryLock, own: Bool) -> String {
        var lines: [String] = []
        lines.append(own ? L.t("本工作副本持有该锁") : L.f("锁由 %@ 持有", String(describing: lock.owner ?? L.t("他人"))))
        if let comment = lock.comment, !comment.isEmpty {
            lines.append(L.f("说明：%@", String(describing: comment)))
        }
        if let created = lock.createdAt {
            lines.append(L.f("锁定于 %@", RelativeTime.absolute(created)))
        }
        if !own {
            lines.append(L.t("解除需要强制，且会让对方无法提交。"))
        }
        return lines.joined(separator: "\n")
    }

    private var actionBar: some View {
        // No refresh button here: the toolbar already owns "re-read the working
        // copy", with the same icon and the same ⌘R. Two of them on one screen
        // reads as two different checks, and this bar is for acting on files.
        HStack(spacing: 10) {
            changelistMenu

            Divider().frame(height: 16)

            Button {
                tab = .commit
            } label: {
                Label(L.t("去提交"), systemImage: "arrow.up.doc")
            }
            .disabled(session.changedEntries.isEmpty)

            Spacer()

            Text(selectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                Button(L.t("添加到版本控制")) { Task { await session.add(unversionedSelection) } }
                    .disabled(unversionedSelection.isEmpty)
                Button(L.t("忽略所选文件")) { Task { await session.ignore(unversionedSelection) } }
                    .disabled(unversionedSelection.isEmpty)
                    .help(L.t("把所选文件加入各自目录的 svn:ignore"))
                Button(L.t("属性…")) {
                    guard let entry = selectedEntries.first, selectedEntries.count == 1 else { return }
                    session.openProperties(for: entry)
                }
                .disabled(selectedEntries.count != 1)
                lockMenu(for: selectedEntries)
                Button(session.isLockLoading ? L.t("正在查询锁定…") : L.t("刷新锁定状态")) {
                    Task { await session.refreshLocks() }
                }
                .disabled(session.isLockLoading)
                .help(L.t("向服务器查询这些文件上的锁（包括他人持有的）"))
                Button(L.t("还原…")) { session.requestRevert(Array(session.selectedPaths)) }
                    .disabled(session.selectedPaths.isEmpty)
                Button(L.t("删除…")) { session.requestDelete(Array(session.selectedPaths)) }
                    .disabled(session.selectedPaths.isEmpty)
                Divider()
                Button(L.t("查看差异")) {
                    guard let entry = selectedEntries.first else { return }
                    Task {
                        await session.loadDiff(for: entry)
                        tab = .diff
                    }
                }
                .disabled(selectedEntries.isEmpty)

                Divider()

                Menu(L.f("解决全部冲突（%@）", String(describing: session.conflictedEntries.count))) {
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
                Label(L.t("操作"), systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Changelists: a local label and a view filter, never a server concept.
    private var changelistMenu: some View {
        Menu {
            Button(L.t("显示全部")) { session.changelistFilter = nil }
            if !session.changelists.isEmpty {
                Divider()
                ForEach(session.changelists, id: \.self) { name in
                    Button {
                        session.changelistFilter = name
                    } label: {
                        if session.changelistFilter == name {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }

            Divider()

            Menu(L.t("将所选加入")) {
                ForEach(session.changelists, id: \.self) { name in
                    Button(name) {
                        Task { await session.assignChangelist(name, to: selectedEntries.map(\.id)) }
                    }
                }
                if !session.changelists.isEmpty { Divider() }
                Button(L.t("新建变更集…")) { promptForChangelistName() }
            }
            .disabled(selectedEntries.isEmpty)

            Button(L.t("移出变更集")) {
                Task { await session.assignChangelist(nil, to: selectedEntries.map(\.id)) }
            }
            .disabled(!selectedEntries.contains { $0.changelist != nil })
        } label: {
            Label(
                session.changelistFilter ?? L.t("变更集"),
                systemImage: "tray.full"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L.t("变更集只存在于本地，用来把改动分组；提交时按勾选，不按变更集"))
    }

    /// A name prompt has to be a text field, and `NSAlert` is the shortest path
    /// to one that also blocks until answered.
    private func promptForChangelistName() {
        let alert = NSAlert()
        alert.messageText = L.t("新建变更集")
        alert.informativeText = L.t("变更集是本地标签，不会提交到服务器。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L.t("例如 ui-review")
        alert.accessoryView = field
        alert.addButton(withTitle: L.t("创建"))
        alert.addButton(withTitle: L.t("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let paths = selectedEntries.map(\.id)
        Task { await session.assignChangelist(name, to: paths) }
    }

    private var selectionSummary: String {
        var parts: [String] = []
        if !session.filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(L.f("显示 %@ / %@ 项", String(describing: filteredEntries.count), String(describing: session.status?.entries.count ?? 0)))
        }
        if session.selectedPaths.isEmpty {
            parts.append(L.t("未选择"))
        } else {
            parts.append(L.n("已选择 %d 项", session.selectedPaths.count))
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
        var entries = session.status?.entries ?? []
        if let list = session.changelistFilter {
            entries = entries.filter { $0.changelist == list }
        }
        let raw = session.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return entries }
        let terms = raw.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        return entries.filter { entry in
            let haystack = session.relativePath(entry.path).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private var externalRoots: [String] {
        session.status?.externalRoots ?? []
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
