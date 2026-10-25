import SwiftUI
import OpenSVNCore

extension StatusCategory {
    var title: String {
        switch self {
        case .conflicted: return "冲突"
        case .modified: return "已修改"
        case .added: return "新增"
        case .deleted: return "删除"
        case .unversioned: return "未纳入版本控制"
        case .external: return "外部工作副本"
        case .ignored: return "已忽略"
        case .normal: return "正常"
        case .other: return "其他"
        }
    }

    var color: Color {
        switch self {
        case .conflicted: return .red
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .pink
        case .unversioned: return .secondary
        case .external: return .blue
        case .ignored: return .secondary
        case .normal: return .secondary
        case .other: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .conflicted: return "exclamationmark.triangle.fill"
        case .modified: return "pencil.circle.fill"
        case .added: return "plus.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .unversioned: return "questionmark.circle"
        case .external: return "link.circle.fill"
        case .ignored: return "eye.slash"
        case .normal: return "checkmark.circle"
        case .other: return "circle.dashed"
        }
    }

    var sortOrder: Int {
        switch self {
        case .conflicted: return 0
        case .modified: return 1
        case .added: return 2
        case .deleted: return 3
        case .unversioned: return 4
        case .external: return 5
        case .other: return 6
        case .ignored: return 7
        case .normal: return 8
        }
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

struct ConflictBadges: View {
    let flags: ConflictFlags

    var body: some View {
        HStack(spacing: 3) {
            if flags.contains(.text) {
                StatusBadge(text: "文本冲突", color: .red)
            }
            if flags.contains(.property) {
                StatusBadge(text: "属性冲突", color: .purple)
            }
            if flags.contains(.tree) {
                StatusBadge(text: "树冲突", color: .red)
            }
        }
    }
}

/// Relative time formatting used in history and task lists.
enum RelativeTime {
    static func string(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
