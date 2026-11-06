import Foundation
import SwiftUI

/// A read-only text view whose ticket references are clickable links.
///
/// Used for history messages and commit-message previews. The template is read
/// from the shared UserDefaults key, so the settings pane and this view always
/// agree.
struct TicketLinkedText: View {
    let text: String
    @AppStorage(UIExtensionSettings.ticketURLTemplateKey)
    private var template = UIExtensionSettings.defaultTicketURLTemplate

    var body: some View {
        Text(TicketLinkDetector.attributed(text, template: template))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A compact row of explicit `Link`s for the references found in a message.
///
/// The commit message is an editable `TextEditor`, so inline links would fight
/// with editing. Showing the detected tickets as separate links underneath is
/// both discoverable and unambiguous.
struct TicketLinksBar: View {
    let text: String
    @AppStorage(UIExtensionSettings.ticketURLTemplateKey)
    private var template = UIExtensionSettings.defaultTicketURLTemplate

    var body: some View {
        let matches = TicketLinkDetector.matches(in: text)
        if !matches.isEmpty {
            HStack(spacing: 8) {
                Text("识别到工单")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(matches, id: \.offset) { match in
                    if let url = TicketLinkDetector.url(match: match, template: template) {
                        Link(match.raw, destination: url)
                            .font(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
