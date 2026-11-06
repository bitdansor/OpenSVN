import AppKit
import QuickLookUI
import SwiftUI

/// A single-item Quick Look preview backed by `QLPreviewView`.
///
/// Wrapping the AppKit view avoids the shared `QLPreviewPanel` and its
/// dataSource lifetime: the sheet owns the preview for as long as it is open.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        // `QLPreviewView(frame:style:)` is a failable initialiser in Swift.
        // Returning a labelled placeholder keeps the sheet usable when Quick
        // Look cannot create a view, instead of forcing an unwrap that crashes.
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            let label = NSTextField(labelWithString: "无法创建快速查看预览")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            return label
        }
        view.previewItem = QuickLookItem(url)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? QLPreviewView else { return }
        view.previewItem = QuickLookItem(url)
    }
}

private final class QuickLookItem: NSObject, QLPreviewItem {
    let url: URL

    init(_ url: URL) { self.url = url }

    var previewItemURL: URL! { url }
    var previewItemTitle: String? { url.lastPathComponent }
}

/// The sheet that presents Quick Look for one file.
struct QuickLookSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            QuickLookPreview(url: url)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
