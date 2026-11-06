import SwiftUI
import OpenSVNCore

/// The branch-merge sheet.
///
/// `svn merge` writes into the working copy and can leave conflicts behind, so
/// this sheet exists to be read *before* pressing the button. It shows the same
/// `OperationPreview` the service builds (a pure computation — no subprocess), so
/// what the sheet promises and what the service would report are one code path.
///
/// The revision field is a free-text range rather than a stepper because merge
/// ranges are entered far more often than they are nudged, and svn's own syntax
/// (`12:34`, reversed for a revert) is the shortest way to say it.
struct MergeSheet: View {
    @Bindable var session: RepositorySession
    @Environment(\.dismiss) private var dismiss

    private enum Style: String, CaseIterable, Identifiable {
        case automatic
        case twoURL

        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return "跟踪合并（一次来源）"
            case .twoURL: return "比较两个 URL"
            }
        }
    }

    private enum RevisionChoice: String, CaseIterable, Identifiable {
        case all
        case range
        case changes

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部未合并的修订"
            case .range: return "指定范围"
            case .changes: return "挑拣单个修订"
            }
        }
    }

    @State private var style: Style = .automatic
    @State private var sourceURL = ""
    @State private var rightURL = ""
    @State private var revisionChoice: RevisionChoice = .all
    @State private var rangeText = ""
    @State private var changesText = ""
    @State private var recordOnly = false
    @State private var ignoreAncestry = false
    @State private var accept: SVNAccept = .postpone
    @State private var isRunning = false
    @State private var eligible: [Int64]?
    @State private var isCheckingEligible = false
    @State private var parseNote: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                styleSection
                sourceSection
                revisionSection
                optionsSection
            }
            .formStyle(.grouped)
            Divider()
            previewSection
            Divider()
            footer
        }
        .frame(width: 640, height: 620)
        .onAppear(perform: suggestSource)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("合并到「\(session.displayName)」")
                    .font(.headline)
                Text("合并只改工作副本：结果还需要一次提交才会进入仓库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Form

    private var styleSection: some View {
        Section {
            Picker("方式", selection: $style) {
                ForEach(Style.allCases) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("合并方式")
        } footer: {
            Text(style == .automatic
                 ? "svn merge SOURCE：由 svn:mergeinfo 决定哪些修订还没合并过。合并一个分支回主干、把主干的修复合到分支，都用这一种。"
                 : "svn merge SOURCE1 SOURCE2：把两个 URL 之间的差异应用过来，不依赖 svn:mergeinfo。")
                .font(.caption2)
        }
    }

    private var sourceSection: some View {
        Section("来源") {
            LabeledContent("来源 URL") {
                TextField("https://…/branches/feature", text: $sourceURL)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            if style == .twoURL {
                LabeledContent("对比 URL") {
                    TextField("https://…/tags/v2", text: $rightURL)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }
        }
    }

    private var revisionSection: some View {
        Section("修订") {
            if style == .automatic {
                Picker("范围", selection: $revisionChoice) {
                    ForEach(RevisionChoice.allCases) { candidate in
                        Text(candidate.title).tag(candidate)
                    }
                }

                switch revisionChoice {
                case .all:
                    EmptyView()
                case .range:
                    LabeledContent("起始:结束") {
                        TextField("12:34", text: $rangeText)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    Text("结束小于起始就是反向合并——这是撤销某段已提交改动的正规做法。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .changes:
                    LabeledContent("修订号") {
                        TextField("12,14,20", text: $changesText)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    Text("逗号分隔的单个修订号，相当于对每个修订各做一次 -c。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await checkEligible() }
                    } label: {
                        if isCheckingEligible {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("查询未合并的修订", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(isCheckingEligible || trimmedSource.isEmpty)
                    .help("svn mergeinfo --show-revs eligible：只读，不碰工作副本")

                    if let eligible {
                        Text(eligible.isEmpty
                             ? "没有待合并的修订"
                             : "待合并 r\(revisionList(eligible))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
            } else {
                Text("两 URL 比较不分修订范围：差异就是两个 URL 的当前内容之间的差异。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var optionsSection: some View {
        Section("选项") {
            Toggle("只记录合并（--record-only）", isOn: $recordOnly)
                .help("只把修订记进 svn:mergeinfo，不改动任何文件：用于「这段修改我已经手工搬过去了」")
            Toggle("忽略祖先关系（--ignore-ancestry）", isOn: $ignoreAncestry)
                .help("不检查两个 URL 是否有复制历史。两 URL 比较常用；跟踪合并会因此失去一部分保护")

            Picker("冲突处理", selection: $accept) {
                Text("留给我处理（postpone）").tag(SVNAccept.postpone)
                Text("保留我的整份文件（mine-full）").tag(SVNAccept.mineFull)
                Text("采用来源的整份文件（theirs-full）").tag(SVNAccept.theirsFull)
                Text("冲突处保留我的（mine-conflict）").tag(SVNAccept.mineConflict)
                Text("冲突处采用来源的（theirs-conflict）").tag(SVNAccept.theirsConflict)
            }
            if accept.isOverwriting {
                Text("“整份文件”类策略会覆盖本地或来源的完整内容，且没有撤销：冲突被替换掉之后，原本的三份副本只能从备份里找回。")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if let parseNote {
                Text(parseNote)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: riskIcon)
                    .foregroundStyle(riskColor)
                Text(preview?.summary ?? "填写来源后这里会显示这次合并做什么")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer()
            }
            if let detail = preview?.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if isRunning { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isRunning)
            Button(isRunning ? "合并中…" : "合并") {
                Task { await runMerge() }
            }
            .buttonStyle(.borderedProminent)
            .tint(accept.isOverwriting ? .red : nil)
            .keyboardShortcut(.defaultAction)
            .disabled(isRunning || request == nil)
        }
        .padding(14)
    }

    // MARK: - Derived values

    private var trimmedSource: String {
        sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Built on every redraw, so the preview always describes what the button
    /// would actually run. `nil` means "not runnable yet".
    private var request: MergeRequest? {
        let target = session.path
        switch style {
        case .automatic:
            guard !trimmedSource.isEmpty else { return nil }
            var revisions: MergeRevisions?
            switch revisionChoice {
            case .all:
                revisions = nil
            case .range:
                guard let parsed = parseRange(rangeText) else { return nil }
                revisions = parsed
            case .changes:
                guard let parsed = parseChanges(changesText) else { return nil }
                revisions = parsed
            }
            return MergeRequest(
                style: .automatic(sourceURL: trimmedSource, revisions: revisions),
                target: target,
                recordOnly: recordOnly,
                accept: accept,
                ignoreAncestry: ignoreAncestry
            )
        case .twoURL:
            let right = rightURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSource.isEmpty, !right.isEmpty else { return nil }
            return MergeRequest(
                style: .twoURL(leftURL: trimmedSource, rightURL: right),
                target: target,
                recordOnly: recordOnly,
                accept: accept,
                ignoreAncestry: ignoreAncestry
            )
        }
    }

    private var preview: OperationPreview? {
        request.map { session.previewMerge($0) }
    }

    private var riskIcon: String {
        switch preview?.risk {
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.triangle"
        default: return "info.circle"
        }
    }

    private var riskColor: Color {
        switch preview?.risk {
        case .high: return .red
        case .medium: return .orange
        default: return .secondary
        }
    }

    // MARK: - Actions

    private func suggestSource() {
        // The two layouts that account for almost every merge are trunk ← branches
        // and branches ← trunk. Guessing between them from this working copy's own
        // URL saves the one piece of typing that a merge always needs; anything
        // else just echoes the current URL, which the user can edit.
        guard trimmedSource.isEmpty, var own = session.info?.url else { return }
        if own.hasSuffix("/") { own.removeLast() }
        if let branches = own.range(of: "/branches/") {
            sourceURL = String(own[own.startIndex..<branches.lowerBound]) + "/trunk"
        } else if own.hasSuffix("/trunk") {
            sourceURL = String(own.dropLast("/trunk".count)) + "/branches"
        } else {
            sourceURL = own
        }
    }

    private func checkEligible() async {
        isCheckingEligible = true
        defer { isCheckingEligible = false }
        eligible = await session.eligibleRevisions(from: trimmedSource)
    }

    private func runMerge() async {
        guard let request else { return }
        do {
            try request.validate()
        } catch let error as SVNError {
            parseNote = error.message
            return
        } catch {
            parseNote = error.localizedDescription
            return
        }
        parseNote = nil
        isRunning = true
        defer { isRunning = false }
        // Clear any older report first, so "a report exists" afterwards means
        // *this* merge produced one.
        session.branchReport = nil
        await session.merge(request)
        // Close on success only: a failure is already an alert, and keeping this
        // sheet open preserves what the user typed while they read it.
        if session.branchReport != nil { dismiss() }
    }

    // MARK: - Parsing

    /// `12:34`, `12-34`, `12..34`. Anything else is refused rather than guessed:
    /// a silently mis-parsed range would merge the wrong revisions.
    private func parseRange(_ text: String) -> MergeRevisions? {
        let cleaned = text.replacingOccurrences(of: "..", with: ":")
        let parts = cleaned.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 2,
              let from = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
              let to = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return .range(from: from, to: to)
    }

    private func parseChanges(_ text: String) -> MergeRevisions? {
        let numbers = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { Int64($0) }
        let rawCount = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
        guard !numbers.isEmpty, numbers.count == rawCount else { return nil }
        return .changes(numbers)
    }

    private func revisionList(_ revisions: [Int64]) -> String {
        let shown = revisions.prefix(8).map { String($0) }.joined(separator: ",")
        return revisions.count > 8 ? shown + "…" : shown
    }
}
