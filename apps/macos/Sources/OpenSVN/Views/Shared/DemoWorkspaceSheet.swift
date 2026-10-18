import SwiftUI
import OpenSVNCore

/// The entry point for "show me what a three-way merge does".
///
/// It exists because the feature is expensive to try and cheap to demo: a real
/// evaluation needs two working copies, an edit that reached the repository, a
/// conflicting local edit, and a working `svnadmin`. This sheet builds all of
/// that locally, then opens the result, so the first merge the user sees is one
/// they did not have to construct.
struct DemoWorkspaceSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560)
        .task { appState.refreshDemoAvailability() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("亲手试一次三方合并")
                    .font(.title3.weight(.semibold))
                Text("在本机生成一个带冲突的小仓库，不需要联网，也不会动你的其他文件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("三方合并要准备两份工作副本和一次真实冲突 —— 为了试一个功能做这些不值得。点下面的按钮，这些都由 OpenSVN 代劳。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 9) {
                Text("生成后你会看到")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                item("src/calculator.swift", "3 处自动合并，1 处需要你决定", tint: .blue)
                item("docs/config.md", "2 处自动合并，1 处需要你决定", tint: .blue)
                item("docs/发布说明.md", "中文文件名，同样可以合并", tint: .blue)
                item("docs/属性冲突.txt", "属性冲突 —— 三方合并处理不了，需要整体选一边", tint: .purple)
                item("src/util.swift", "只有服务器改过，更新时已经自动合并", tint: .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(displayPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            if case .failed(let message) = appState.demoPhase {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("取消") { dismiss() }
            Spacer()

            if appState.demoPhase == .building {
                ProgressView().controlSize(.small)
                Text("正在生成…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.demoWorkingCopy != nil {
                Button("重新生成") {
                    Task { await appState.createDemoWorkspace() }
                }
                .disabled(appState.demoPhase == .building)
                Button("打开演示") { appState.openExistingDemo() }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.demoPhase == .building)
            } else {
                Button("生成并打开") {
                    Task { await appState.createDemoWorkspace() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.demoPhase == .building)
            }
        }
        .padding(16)
    }

    // MARK: - Pieces

    private func item(_ path: String, _ detail: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 190, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayPath: String {
        (DemoWorkspace.defaultRoot.path as NSString).abbreviatingWithTildeInPath
    }
}
