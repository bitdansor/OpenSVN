import Foundation

/// Configuration for an external three-way merge program.
///
/// The executable and the argument template are stored separately so the
/// command can be launched with `Process.arguments` — an argument array, never
/// a shell string. Placeholders are substituted into individual tokens, so a
/// path containing spaces still arrives as one argument.
struct ExternalMergeConfiguration {
    let executable: URL
    let argumentTemplate: String

    static func load() -> ExternalMergeConfiguration? {
        let path = UIExtensionSettings.mergeExecutablePath
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return ExternalMergeConfiguration(
            executable: URL(fileURLWithPath: path),
            argumentTemplate: UIExtensionSettings.mergeArgumentTemplate
        )
    }

    /// Expands the template into an argument array.
    ///
    /// Splitting happens before substitution: each token is replaced as a whole,
    /// which keeps paths with spaces intact and also supports forms like
    /// `--base={base}`.
    func arguments(
        base: URL,
        mine: URL,
        theirs: URL,
        merged: URL,
        working: URL
    ) -> [String] {
        argumentTemplate
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { token in
                token
                    .replacingOccurrences(of: "{base}", with: base.path)
                    .replacingOccurrences(of: "{mine}", with: mine.path)
                    .replacingOccurrences(of: "{theirs}", with: theirs.path)
                    .replacingOccurrences(of: "{merged}", with: merged.path)
                    .replacingOccurrences(of: "{file}", with: working.path)
            }
    }
}
