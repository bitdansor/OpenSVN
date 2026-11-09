import AppKit
import SwiftUI
import OpenSVNCore

/// Quick Look / Terminal / Finder menu items for a Changes row.
///
/// These are provided as a standalone view so the row's context menu can adopt
/// them with a single line, without this file having to own the row. The host
/// supplies `onQuickLook` so it can present its own preview sheet.
struct ChangesRowQuickActions: View {
    let url: URL
    let onQuickLook: (URL) -> Void

    var body: some View {
        Button(L.t("快速查看")) { onQuickLook(url) }
        Button(L.t("在终端打开")) { FileActions.openInTerminal(url.deletingLastPathComponent()) }
        Button(L.t("在 Finder 中显示")) { FileActions.revealInFinder([url]) }
    }
}

/// Makes a row a drag source for Finder (file URL copy / export).
///
/// `svn export` needs an explicit destination directory, which a Finder drop
/// cannot provide; the drag therefore offers the versioned file, while the
/// "导出所选…" command in the main window performs a real `svn export`.
struct ChangesRowDragSource: ViewModifier {
    let url: URL

    func body(content: Content) -> some View {
        content.onDrag {
            NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
    }
}
