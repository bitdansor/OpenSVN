import AppKit
import Foundation

/// Finder and Terminal integration for a file or a folder.
///
/// Both go through `NSWorkspace` with `URL` values. Opening a terminal never
/// builds a shell command string: the directory URL is handed to Terminal.app
/// directly, which keeps paths containing spaces or quotes safe.
enum FileActions {
    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func openInTerminal(_ directory: URL) {
        guard let application = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: application,
            configuration: configuration,
            completionHandler: nil
        )
    }
}
