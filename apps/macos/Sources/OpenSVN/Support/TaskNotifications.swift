import Foundation
import OpenSVNCore
import UserNotifications

/// Sends a local notification when a task in the shared `TaskCenter` finishes
/// or fails.
///
/// `TaskCenter` lives in the core target and is not modified here; instead the
/// UI observes its item list and compares statuses with the previous snapshot.
/// Every UserNotifications call is guarded: a SwiftPM executable without a
/// bundle identifier, a denied authorization, or an unsigned build all degrade
/// to "no notification" instead of crashing or blocking the operation.
@MainActor
final class TaskNotificationBridge {
    static let shared = TaskNotificationBridge()

    private var knownStatuses: [UUID: TaskCenter.Item.Status] = [:]
    private var isPrimed = false
    private var didRequestAuthorization = false

    private init() {}

    /// Records the current items without notifying, so tasks that were already
    /// finished before the window appeared do not produce a burst of alerts.
    func prime(_ items: [TaskCenter.Item]) {
        knownStatuses = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.status) })
        isPrimed = true
    }

    func process(_ items: [TaskCenter.Item]) {
        guard UIExtensionSettings.taskNotificationsEnabled else {
            prime(items)
            return
        }
        let shouldNotify = isPrimed
        for item in items {
            let previous = knownStatuses[item.id]
            knownStatuses[item.id] = item.status
            guard shouldNotify, let previous, previous == .running else { continue }
            switch item.status {
            case .finished:
                notify(title: L.t("任务完成"), body: item.title)
            case .failed(let message):
                notify(title: L.t("任务失败"), body: "\(item.title)：\(message)")
            default:
                break
            }
        }
        isPrimed = true
    }

    /// Asks for authorization once, and only when the feature is enabled.
    func requestAuthorizationIfNeeded(force: Bool = false) {
        if force { didRequestAuthorization = false }
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        guard UIExtensionSettings.taskNotificationsEnabled,
              Bundle.main.bundleIdentifier != nil else { return }
        Task { @MainActor in
            do {
                // No `notificationSettings()` pre-check. Once the user has
                // answered, `requestAuthorization` returns the existing
                // decision immediately without prompting, so the round trip
                // only existed to avoid a prompt that cannot happen. It also
                // handed back a non-Sendable `UNNotificationSettings` across an
                // isolation boundary, which Swift 6.1 rejects outright.
                _ = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            } catch {
                // Unsigned or misconfigured builds: silently skip.
            }
        }
    }

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task { @MainActor in
            do {
                let center = UNUserNotificationCenter.current()
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                // `add` throws when this app is not allowed to post
                // notifications, and the catch below turns that into "no
                // notification" — the same outcome as an explicit
                // `authorizationStatus` check, without reading that value out of
                // a non-Sendable `UNNotificationSettings`.
                try await center.add(request)
            } catch {
                // No notification is better than a failed operation.
            }
        }
    }
}
