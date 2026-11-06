import Foundation

/// UserDefaults keys for the UI extension features.
///
/// These are deliberately self-contained: the app's Settings scene owns its own
/// panes, so the same keys can be written there without this layer having to
/// touch those files. A value configured in either place is seen everywhere.
enum UIExtensionSettings {
    static let ticketURLTemplateKey = "cn.opensvn.ticketURLTemplate"
    static let taskNotificationsEnabledKey = "cn.opensvn.taskNotificationsEnabled"
    static let mergeExecutableKey = "cn.opensvn.mergeExecutablePath"
    static let mergeArgumentTemplateKey = "cn.opensvn.mergeArgumentTemplate"

    static let defaultTicketURLTemplate = "https://example.com/browse/{id}"
    static let defaultMergeArgumentTemplate = "{base} {mine} {theirs} {merged}"

    static var ticketURLTemplate: String {
        let raw = UserDefaults.standard.string(forKey: ticketURLTemplateKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultTicketURLTemplate : raw
    }

    static var taskNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: taskNotificationsEnabledKey) as? Bool ?? true
    }

    static var mergeExecutablePath: String {
        UserDefaults.standard.string(forKey: mergeExecutableKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var mergeArgumentTemplate: String {
        let raw = UserDefaults.standard.string(forKey: mergeArgumentTemplateKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultMergeArgumentTemplate : raw
    }
}
