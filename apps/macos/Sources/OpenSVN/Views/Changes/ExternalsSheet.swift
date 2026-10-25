import SwiftUI
import OpenSVNCore

/// `svn:externals` of one working copy, read-only.
///
/// Read-only is not a shortcut here. svn 1.14 answers `svn propset` against a URL
/// with `E200009: Targets must be working copy paths` — there is no remote
/// property editing at all. Editing the mount list therefore needs a checkout,
/// and a sheet that pretended otherwise would fail on the one action it offered.
struct ExternalsSheet: View {
    @Bindable var session: RepositorySession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 440)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("svn:externals")
                    .font(.headline)
                Text("挂载在本工作副本内的其它工作副本。它们的改动在「变更」页会标为「外部」，不能从这里提交。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if let error = session.externalsState?.error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("重试") { Task { await session.loadExternals() } }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.externalsState?.isLoading == true {
            ProgressView("正在读取仓库属性…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let targets = session.externalsState?.targets, !targets.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(targets) { target in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(shorten(target.path))
                                .font(.callout.weight(.medium))
                                .textSelection(.enabled)
                            Text(target.value(of: "svn:externals") ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary.opacity(0.10))
                                )
                        }
                    }
                }
                .padding(18)
            }
        } else {
            ContentUnavailableView {
                Label("没有 svn:externals", systemImage: "link.badge.plus")
            } description: {
                Text("这个工作副本没有挂载外部工作副本。")
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("属性只读：svn 不支持直接修改仓库路径的属性，改完需要在工作副本里提交。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("刷新") { Task { await session.loadExternals() } }
                .disabled(session.externalsState?.isLoading == true)
            Button("关闭") { session.dismissExternals() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    private func shorten(_ path: String) -> String {
        guard let root = session.info?.url, path.hasPrefix(root) else { return path }
        let relative = String(path.dropFirst(root.count))
        return relative.isEmpty ? "（工作副本根）" : relative
    }
}
