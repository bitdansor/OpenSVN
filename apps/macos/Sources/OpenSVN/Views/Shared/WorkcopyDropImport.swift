import SwiftUI
import UniformTypeIdentifiers

/// Drop target for importing Finder items into the selected working copy.
///
/// Attached to the Changes page. The dashed highlight is the first feedback;
/// `DropImporter` then gathers every file URL of the drop and asks the session
/// for confirmation before a single file is written. The import itself is
/// reported by the task center and by the refreshed Changes list.
struct WorkcopyDropImport: ViewModifier {
    let session: RepositorySession?
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                DropImporter.handle(providers, session: session)
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
    }
}
