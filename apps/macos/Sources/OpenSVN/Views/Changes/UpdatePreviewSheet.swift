import SwiftUI
import OpenSVNCore

/// The "what am I about to pull in?" sheet.
///
/// `svn update` has no dry run, so this is the closest thing to one: the list
/// comes from `status --show-updates`, and the revision it names is the one the
/// update would land on. The sheet exists to be read and cancelled — not to
/// confirm a decision that was already made — which is why 取消 is the default
/// and the destructive-looking warning is about *risks*, not about updating.
struct UpdatePreviewSheet: View {
    @Bindable var session: RepositorySession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 24))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("更新「\(session.displayName)」")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var subtitle: String {
        guard let preview = session.updatePreview?.preview else {
            return session.updatePreview?.isLoading == true ? "正在向服务器查询…" : "尚未取得服务器状态"
        }
        let local = preview.workingCopyRevision.map { "r\($0)" } ?? "未知修订"
        guard let server = preview.serverRevision else {
            return "本地 \(local)"
        }
        return "本地 \(local) → 服务器 r\(server)"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let state = session.updatePreview, state.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在读取服务器上的变更…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("这一步只读取，不会改动工作副本。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure = session.updatePreview?.failure {
            failureView(failure)
        } else if let preview = session.updatePreview?.preview {
            if preview.isEmpty {
                emptyView(preview)
            } else {
                changeList(preview)
            }
        } else {
            Color.clear
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("无法读取服务器状态")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("重试") {
                Task { await session.loadUpdatePreview() }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyView(_ preview: RemotePreview) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text("已是最新")
                .font(.headline)
            if let server = preview.serverRevision {
                Text("服务器上没有任何比本地更新的内容（服务器 r\(server)）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("服务器上没有任何比本地更新的内容。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("仍然更新会重新应用目录属性，通常没有必要。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func changeList(_ preview: RemotePreview) -> some View {
        VStack(spacing: 0) {
            summaryBar(preview)
            if let rootChange = preview.rootPropertyChange {
                rootPropertyRow(rootChange)
            }
            if preview.hasConflictsWithLocal {
                conflictBanner(preview)
            }
            List {
                ForEach(RemoteSection.allCases, id: \.self) { section in
                    let entries = preview.changes.filter { section.matches($0) }
                    if !entries.isEmpty {
                        Section {
                            ForEach(entries) { change in
                                row(change)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: section.systemImage)
                                    .foregroundStyle(section.color)
                                Text("\(section.title) · \(entries.count)")
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func summaryBar(_ preview: RemotePreview) -> some View {
        HStack(spacing: 12) {
            countChip("新增", preview.addedCount, .green)
            countChip("修改", preview.modifiedCount, .orange)
            countChip("删除", preview.deletedCount, .red)
            Spacer()
            Text("本地 \(session.updatePreview?.localChangeCount ?? 0) 个未提交修改")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func countChip(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(count == 0 ? .tertiary : .secondary)
        }
    }

    private func rootPropertyRow(_ change: RemoteChange) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .foregroundStyle(.purple)
            Text("工作副本根目录的属性也有变更")
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.purple.opacity(0.08))
    }

    private func conflictBanner(_ preview: RemotePreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(preview.conflictRisks.count) 个文件本地也改过，更新时可能冲突")
                    .font(.callout.weight(.medium))
            }
            Text("两边改的是同一处时，svn 会把冲突标记写进文件，并留下冲突副本。更新不会丢失本地内容，但你需要解决冲突后才能提交。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
    }

    private func row(_ change: RemoteChange) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: change))
                .foregroundStyle(color(for: change))
                .frame(width: 16)
            Text(session.relativePath(change.path))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if change.conflictsWithLocal {
                Label("可能冲突", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("本地对该路径有未提交的修改，更新时可能产生冲突")
            }
            Text(localDescription(for: change))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .help(change.path)
    }

    private func symbol(for change: RemoteChange) -> String {
        if change.isPropertyOnly { return "tag" }
        switch change.item {
        case .added: return "plus.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        default: return "circle"
        }
    }

    private func color(for change: RemoteChange) -> Color {
        if change.isPropertyOnly { return .purple }
        switch change.item {
        case .added: return .green
        case .deleted: return .red
        case .modified: return .orange
        default: return .secondary
        }
    }

    private func localDescription(for change: RemoteChange) -> String {
        switch change.localItem {
        case .modified: return "本地已修改"
        case .added: return "本地已新增"
        case .deleted: return "本地已删除"
        case .missing: return "本地缺失"
        case .conflicted: return "本地有冲突"
        case .unversioned: return "本地未纳入版本控制"
        default: return ""
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if session.updatePreview?.failure != nil {
                Text("预检失败时仍然可以直接更新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { session.dismissUpdatePreview() }
                    .keyboardShortcut(.cancelAction)
                Button("仍然更新") {
                    Task { await session.confirmUpdate() }
                }
            } else {
                Text("更新只读取服务器并合并到本地；未提交的修改会保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { session.dismissUpdatePreview() }
                    .keyboardShortcut(.cancelAction)
                Button(updateButtonTitle) {
                    Task { await session.confirmUpdate() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(session.updatePreview?.isLoading ?? true)
            }
        }
        .padding(14)
    }

    private var updateButtonTitle: String {
        guard let preview = session.updatePreview?.preview, let server = preview.serverRevision else {
            return "更新"
        }
        return preview.isEmpty ? "仍然更新到 r\(server)" : "更新到 r\(server)"
    }
}

/// The three buckets the sheet lists, in the order they matter to a reader.
private enum RemoteSection: CaseIterable {
    case added
    case modified
    case deleted

    var title: String {
        switch self {
        case .added: return "将新增"
        case .modified: return "将修改"
        case .deleted: return "将删除"
        }
    }

    var systemImage: String {
        switch self {
        case .added: return "plus.circle"
        case .modified: return "pencil.circle"
        case .deleted: return "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        }
    }

    func matches(_ change: RemoteChange) -> Bool {
        if self == .modified { return change.item == .modified || change.isPropertyOnly }
        if self == .added { return change.item == .added }
        return change.item == .deleted
    }
}
