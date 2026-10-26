import AppKit
import SwiftUI

/// A filter field that lives in the content, directly above the list it filters.
///
/// `List` + `.searchable(placement: .toolbar)` puts the field in the window
/// toolbar, shoulder to shoulder with actions that belong to the whole window
/// (add a working copy, check out, refresh). A filter belongs to one list, and a
/// control that only means something on one page should not sit in furniture
/// shared by all of them — so this one is part of the page.
///
/// The system field's affordances are rebuilt here rather than forked away:
/// Esc clears, ⌘F focuses, and the clear button appears only when there is
/// something to clear. The hint is drawn as an overlay instead of passed as a
/// `TextField` placeholder, because a placeholder in a row that reflows gets
/// painted at the position it had before the reflow — outside the border.
struct FilterField: View {
    @Binding var text: String
    let prompt: String

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($focused)
            }

            if !text.isEmpty {
                // No confirmation and no animation: clearing a filter is a way of
                // looking, not an edit.
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("清除筛选内容")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        // Clicking the padding should land in the field, not on nothing.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onExitCommand { text = "" }
        .background {
            // A system search field registers ⌘F itself. This one has to say so;
            // the button is 1 pt and invisible, but it is what puts the shortcut
            // in the responder chain.
            Button("筛选") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.borderless)
                .frame(width: 1, height: 1)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}
