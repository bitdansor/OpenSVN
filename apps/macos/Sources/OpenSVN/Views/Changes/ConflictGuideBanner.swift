import SwiftUI
import OpenSVNCore

/// Explains what a conflict is — and offers the one action worth taking — at the
/// place the user is already looking.
///
/// The menu item alone was not enough. `解决冲突 → 三方合并…` sits two levels deep
/// and says nothing about *why* a merge helps, so a user who has never seen a
/// three-way merge has no reason to go looking for it. This banner exists to make
/// the capability discoverable and to explain its grammar in one sentence:
/// **only the region both sides changed needs a decision.**
///
/// It is not a modal. A conflict does not block reading, diffing, or switching
/// files, so interrupting with an alert would be a lie about urgency.
struct ConflictGuideBanner: View {
    @Bindable var session: RepositorySession
    @State private var isExpanded = true

    private var mergeableEntries: [StatusEntry] {
        session.conflictedEntries.filter { $0.conflicts.contains(.text) }
    }

    private var otherCount: Int {
        session.conflictedEntries.count - mergeableEntries.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.medium)

                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let first = mergeableEntries.first {
                    Button {
                        session.beginMerge(first)
                    } label: {
                        Label(mergeableEntries.count == 1 ? "开始三方合并" : "先合并「\(shortName(first))」", systemImage: "arrow.triangle.branch")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .help("并排比较我的改动、共同基线和服务器改动，逐块决定保留哪一边")
                }

                Menu {
                    Button("全部用我的") { session.resolveAllConflicts(strategy: .mineFull) }
                    Button("全部用服务器") { session.resolveAllConflicts(strategy: .theirsFull) }
                } label: {
                    Label("其他方式", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("放弃逐块比较，整个文件采用某一边")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起说明" : "展开说明")
            }

            if isExpanded {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var title: String {
        let total = session.conflictedEntries.count
        if mergeableEntries.isEmpty {
            return "\(total) 个文件有冲突（都不能三方合并）"
        }
        if otherCount == 0 {
            return "\(total) 个文件有文本冲突，可以逐块合并"
        }
        return "\(total) 个文件有冲突，其中 \(mergeableEntries.count) 个可以三方合并"
    }

    private var explanation: String {
        if mergeableEntries.isEmpty {
            return "属性冲突和树冲突没有三份可比较的文本，需要整体选一边。用右键菜单「解决冲突」里的策略，或右上角「其他方式」。"
        }
        var text = "三方合并并排显示三份内容：左边是我的改动，中间是双方共同的基线，右边是服务器上的改动。"
            + "只有两边都改了同一处才需要你决定，其余部分会自动合并。写入前会把当前冲突文件备份到应用支持目录。"
        if otherCount > 0 {
            text += " 另有 \(otherCount) 个属性或树冲突不能三方合并，需要整体选一边。"
        }
        return text
    }

    private func shortName(_ entry: StatusEntry) -> String {
        let name = session.relativePath(entry.path)
        return name.split(separator: "/").last.map(String.init) ?? name
    }
}
