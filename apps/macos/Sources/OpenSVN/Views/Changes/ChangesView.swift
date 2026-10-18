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
            } else if let snapshot = session.status, snapshot.entries.isEmpty {
                ContentUnavailableView {
                    Label("工作副本干净", systemImage: "checkmark.seal")
                } description: {
                    Text("没有本地修改。")
                } actions: {
                    Button("更新") { Task { await session.update() } }
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
            if let lock = entry.repositoryLock {
                Label(lock.owner ?? "已锁定", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
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
        Divider()
        Button("还原本地修改…", role: .destructive) {
            session.requestRevert([entry.id])
        }
        Button("删除…", role: .destructive) {
            session.requestDelete([entry.id])
        }
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
        if session.selectedPaths.isEmpty {
            return "未选择"
        }
        return "已选择 \(session.selectedPaths.count) 项"
    }

    private var grouped: [StatusCategory: [StatusEntry]] {
        Dictionary(grouping: session.status?.entries ?? [], by: \.category)
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
}
