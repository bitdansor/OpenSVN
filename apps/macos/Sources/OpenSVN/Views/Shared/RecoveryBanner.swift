import AppKit
import OpenSVNCore
import SwiftUI

/// Top-of-window notice about a write that a previous launch never finished.
///
/// It sits above the split view instead of being an alert: the app is usable
/// while it is shown, and dismissing it is an explicit act. An alert would train
/// people to click it away without reading, which is the opposite of what a
/// half-finished `svn commit` needs.
struct RecoveryBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let quarantine = appState.journalQuarantineURL {
                corruptionRow(quarantine)
            }
            if !appState.recoveryItems.isEmpty {
                interruptedRows
            }
            if let error = appState.recoveryError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The tint alone is translucent: over a `NavigationSplitView` it let the
        // selected sidebar row show through the advice text. An explicit base
        // colour keeps the copy readable in both appearances.
        .background {
            Color(nsColor: .windowBackgroundColor)
            Color.orange.opacity(0.12)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Corrupt journal

    private func corruptionRow(_ url: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "doc.questionmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("操作记录文件无法读取")
                    .font(.subheadline.weight(.semibold))
                Text("已保留为 \(url.lastPathComponent)，无法判断上次是否有操作被中断。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .controlSize(.small)
            Button("知道了") { appState.acknowledgeJournalCorruption() }
                .controlSize(.small)
        }
    }

    // MARK: - Interrupted operations

    private var interruptedRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("上次有 \(appState.recoveryItems.count) 项操作没有正常结束")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("全部忽略") {
                    Task { await appState.dismissAllRecovery() }
                }
                .controlSize(.small)
            }

            ForEach(appState.recoveryItems.prefix(3)) { entry in
                entryRow(entry)
            }

            if appState.recoveryItems.count > 3 {
                Text("还有 \(appState.recoveryItems.count - 3) 项未显示")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func entryRow(_ entry: OperationJournal.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: entry.kind))
                .frame(width: 16)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.kind.title) · \(workingCopyName(entry))")
                    .font(.callout.weight(.medium))
                Text(entry.recoveryAdvice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if canClean(entry) {
                Button("清理") {
                    Task { await appState.recover(entry) }
                }
                .controlSize(.small)
                .help("运行 svn cleanup，把工作副本从中间状态恢复")
            }
            Button("显示") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: entry.workingCopy)
                ])
            }
            .controlSize(.small)
            Button("忽略") {
                Task { await appState.dismissRecovery(entry) }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func workingCopyName(_ entry: OperationJournal.Entry) -> String {
        let url = URL(fileURLWithPath: entry.workingCopy)
        return url.lastPathComponent.isEmpty ? entry.workingCopy : url.lastPathComponent
    }

    private func canClean(_ entry: OperationJournal.Entry) -> Bool {
        // A checkout destination may not exist yet, and `svn cleanup` cannot help
        // a directory that was never created.
        entry.kind != .checkout && FileManager.default.fileExists(atPath: entry.workingCopy)
    }

    private func icon(for kind: OperationJournal.Entry.Kind) -> String {
        switch kind {
        case .checkout: return "arrow.down.circle"
        case .update: return "arrow.triangle.2.circlepath"
        case .commit: return "arrow.up.circle"
        case .add: return "plus.circle"
        case .delete: return "trash"
        case .revert: return "arrow.uturn.backward.circle"
        case .resolve: return "checkmark.circle"
        case .cleanup: return "wand.and.stars"
        case .property: return "tag.circle"
        }
    }
}
