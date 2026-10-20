import SwiftUI
import OpenSVNCore

struct TaskCenterView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("任务中心")
                    .font(.headline)
                Spacer()
                Button("清除已完成") { appState.taskCenter.dismissFinished() }
                    .disabled(appState.taskCenter.items.allSatisfy(\.isRunning))
            }
            .padding(14)

            Divider()

            if appState.taskCenter.items.isEmpty {
                ContentUnavailableView("没有任务", systemImage: "checklist")
                    .frame(maxHeight: .infinity)
            } else {
                List(appState.taskCenter.items) { item in
                    row(item)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 520, height: 420)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func row(_ item: TaskCenter.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon(for: item)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                    if item.attempts > 1 {
                        Text("第 \(item.attempts) 次尝试")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let duration = item.duration {
                    Text(String(format: "%.1f 秒", duration))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if item.isRunning {
                Button("取消") { appState.taskCenter.cancel(item.id) }
                    .buttonStyle(.borderless)
            } else if item.canRetry {
                Button("重试") {
                    Task { await appState.retryTask(item.id) }
                }
                .buttonStyle(.borderless)
                .help("重新执行同一项请求。不会跳过任何确认，也不改变第一次失败时的参数。")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func icon(for item: TaskCenter.Item) -> some View {
        switch item.status {
        case .running:
            ProgressView().controlSize(.small)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
    }
}
