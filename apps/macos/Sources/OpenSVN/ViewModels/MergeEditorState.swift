import Foundation
import Observation
import OpenSVNCore

/// State for one open merge editor.
///
/// The merge itself is a pure function in the core (`ThreeWayMerge`); this object
/// only holds the decisions. Keeping them apart means the interesting part —
/// which regions conflict, what each side says — is testable without a window.
@MainActor
@Observable
final class MergeEditorState: Identifiable {
    let id = UUID()
    let path: String
    let url: URL
    let artifacts: ConflictArtifacts
    let result: MergeResult
    /// The two sides as text, for the inline preview columns.
    let mineText: String
    let theirsText: String

    private(set) var choices: [Int: MergeChoice] = [:]

    init(
        path: String,
        url: URL,
        artifacts: ConflictArtifacts,
        result: MergeResult,
        mineText: String,
        theirsText: String
    ) {
        self.path = path
        self.url = url
        self.artifacts = artifacts
        self.result = result
        self.mineText = mineText
        self.theirsText = theirsText
    }

    var conflicts: [MergeConflict] { result.conflicts }

    var unresolved: [MergeConflict] {
        conflicts.filter { choices[$0.id] == nil }
    }

    var isReadyToWrite: Bool { unresolved.isEmpty }

    func choice(for id: Int) -> MergeChoice? { choices[id] }

    func choose(_ choice: MergeChoice, for id: Int) {
        choices[id] = choice
    }

    /// Convenience for the "I trust one side" case. Still one click per decision
    /// in the model, so the user can review and change any single one afterwards.
    func chooseAll(_ choice: MergeChoice) {
        for conflict in conflicts { choices[conflict.id] = choice }
    }

    /// The file that would be written. nil while anything is undecided — the
    /// renderer refuses to guess, and so does the UI.
    var renderedText: String? {
        try? result.render(choices)
    }
}
