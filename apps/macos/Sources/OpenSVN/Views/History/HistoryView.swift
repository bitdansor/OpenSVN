import AppKit
import SwiftUI
import OpenSVNCore

struct HistoryView: View {
    @Bindable var session: RepositorySession
    @Binding var tab: RepositoryTab
    @State private var selectedRevision: Int64?

    var body: some View {
        VStack(spacing: 0) {
            if session.logTarget != nil {
                pathScopeBanner
            }
            if session.logIsServerSearch {
                serverSearchBanner
            }
            HSplitView {
                list
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
                detail
                    .frame(minWidth: 340)
            }
        }
        // Local by default: it is instant, and it is what people mean by
        // "search" when the answer is already on screen.
        .searchable(
            text: $session.logFilter.text,
            placement: .toolbar,
            prompt: "筛选已加载的历史（⌘F）"
        )
        .task {
            if session.log.isEmpty {
                await session.loadLog(reset: true)
            }
        }
        // Selecting the newest revision on arrival is not decoration: an empty
        // right-hand pane reads as "this page is broken", and the newest commit
        // is what someone opening history almost always wants to see.
        .onChange(of: session.log.first?.revision) { _, revision in
            if selectedRevision == nil, let revision {
                selectedRevision = revision
            }
        }
    }

    // MARK: - Banners

    private var pathScopeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)
            Text("仅显示「\(session.logTarget ?? "")」的历史")
                .font(.callout)
            if session.logHasMore || session.isLogLoading {
                Text("（沿改名/复制向上追溯）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("显示全部") {
                Task { await session.clearLogTarget() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.08))
    }

    private var serverSearchBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass.circle.fill")
                .foregroundStyle(.orange)
            Text("服务器搜索结果：\(session.log.count) 条匹配「\(session.logServerSearchText)」")
                .font(.callout)
            Text("匹配提交说明、作者、日期与路径")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("返回完整历史") {
                Task { await session.clearServerSearch() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if session.log.isEmpty {
                ContentUnavailableView("尚无历史", systemImage: "clock")
                    .frame(maxHeight: .infinity)
            } else if session.filteredLog.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的修订", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("已加载 \(session.log.count) 条历史，没有一条符合当前筛选。")
                } actions: {
                    Button("清除筛选") { session.logFilter = LogFilter() }
                    if let pattern = session.logFilter.serverSearchPattern {
                        Button("在服务器上搜索「\(pattern)」") {
                            Task { await session.searchLog(pattern) }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedRevision) {
                    ForEach(session.filteredLog) { entry in
                        row(entry)
                            .tag(entry.revision)
                            .contextMenu { contextMenu(for: entry) }
                    }
                    if session.logHasMore && session.logFilter.isEmpty {
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

    private var header: some View {
        HStack(spacing: 8) {
            Text("历史")
                .font(.headline)
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            if session.isLogLoading || session.isLogSearching {
                ProgressView().controlSize(.small)
            }

            Spacer()

            filterMenu

            if session.logFilter.serverSearchPattern != nil {
                Button {
                    Task { await session.searchLog(session.logFilter.text) }
                } label: {
                    Image(systemName: "globe")
                }
                .buttonStyle(.borderless)
                .disabled(session.isLogSearching)
                .help("在服务器上搜索全部历史（不只已加载的部分）")
            }

            Button {
                Task { await session.loadLog(reset: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(session.isLogLoading)
            .help("重新读取最新历史")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var countLabel: String {
        if session.logFilter.isEmpty {
            return "\(session.log.count) 条"
        }
        return "\(session.filteredLog.count) / \(session.log.count)"
    }

    /// Filtering that is worth a menu rather than a text field.
    ///
    /// Authors and date windows are choices, not typing: picking "alice" from a
    /// list of the authors actually present cannot produce zero results by typo,
    /// which a free-text author field can.
    private var filterMenu: some View {
        Menu {
            Section("作者") {
                Button("全部作者") { session.logFilter.author = nil }
                ForEach(authors, id: \.self) { author in
                    Button {
                        session.logFilter.author = author
                    } label: {
                        if session.logFilter.author == author {
                            Label(author, systemImage: "checkmark")
                        } else {
                            Text(author)
                        }
                    }
                }
            }

            Section("提交日期") {
                Button("不限") {
                    session.logFilter.from = nil
                    session.logFilter.to = nil
                }
                ForEach(DateWindow.allCases, id: \.self) { window in
                    Button(window.title) {
                        session.logFilter.from = window.start()
                        session.logFilter.to = nil
                    }
                }
            }

            if let path = session.logFilter.path {
                Section {
                    Button("清除路径筛选") { session.logFilter.path = nil }
                    Text("当前：\(path)")
                }
            }

            if !session.logFilter.isEmpty {
                Divider()
                Button("清除全部筛选") { session.logFilter = LogFilter() }
            }
        } label: {
            Label(
                session.logFilter.isEmpty ? "筛选" : "筛选 · \(session.logFilter.conditionCount)",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按作者、日期或路径筛选已加载的历史")
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
        .help(entry.message)
    }

    @ViewBuilder
    private func contextMenu(for entry: LogEntry) -> some View {
        Button("查看此版本差异") {
            Task {
                await session.loadDiffForRevision(entry.revision, entry: entry)
                tab = .diff
            }
        }
        Button("复制摘要") { copy(entry) }
        Divider()
        if let author = entry.author, !author.isEmpty {
            Button("只看 \(author) 的提交") { session.logFilter.author = author }
        }
        if let path = entry.changedPaths.first?.path {
            Button("只看包含「\(shortName(path))」的提交") {
                session.logFilter.path = path
            }
        }
    }

    // MARK: - Detail

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
                            copy(entry)
                        } label: {
                            Label("复制摘要", systemImage: "doc.on.doc")
                        }
                        .help("复制为 Markdown，可直接贴进工单或聊天")
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
                            Button(entry.author ?? "—") {
                                if let author = entry.author {
                                    session.logFilter.author = author
                                }
                            }
                            .buttonStyle(.link)
                            .disabled(entry.author == nil)
                            .help("只看该作者的提交")
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
                        HStack {
                            Text("变更路径（\(entry.changedPaths.count)）")
                                .font(.headline)
                            Spacer()
                            Text("点击路径可只显示它的历史")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(entry.changedPaths, id: \.self) { path in
                                changedPathRow(path)
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

    private func changedPathRow(_ path: ChangedPath) -> some View {
        HStack(spacing: 6) {
            Text(path.action.rawValue)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(color(for: path.action))
                .frame(width: 14)
            Button {
                session.logFilter.path = path.path
            } label: {
                Text(path.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("只显示包含该路径的提交")
            if let copyFrom = path.copyFromPath {
                Text("← \(copyFrom)@\(path.copyFromRevision.map(String.init) ?? "?")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    // MARK: - Helpers

    /// Authors present in the loaded history, most commits first.
    private var authors: [String] {
        var counts: [String: Int] = [:]
        for entry in session.log {
            guard let author = entry.author, !author.isEmpty else { continue }
            counts[author, default: 0] += 1
        }
        return counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map(\.key)
    }

    private func copy(_ entry: LogEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.summary(for: entry), forType: .string)
    }

    private func firstLine(of message: String) -> String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "（无提交说明）"
    }

    private func shortName(_ path: String) -> String {
        (path as NSString).lastPathComponent
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

/// Date presets rather than two date pickers.
///
/// "When was this changed" is almost always asked as a rough window, and a pair
/// of pickers asks the user to translate that into two exact instants.
private enum DateWindow: CaseIterable {
    case week
    case month
    case quarter
    case year

    var title: String {
        switch self {
        case .week: return "最近 7 天"
        case .month: return "最近 30 天"
        case .quarter: return "最近 90 天"
        case .year: return "最近一年"
        }
    }

    var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        }
    }

    func start(from now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
    }
}
