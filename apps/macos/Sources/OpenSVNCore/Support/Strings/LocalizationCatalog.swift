import Foundation

/// The English side of the catalog.
///
/// Keys are the Chinese source text, verbatim — including `String(format:)`
/// specifiers where the source used interpolation. Values are grouped into one
/// dictionary per area of the app so a translation stays next to the strings it
/// belongs with, and so no single file has to hold every entry.
///
/// `LocalizationCoverageTests` enforces the two properties this file cannot
/// state for itself: every user-visible Chinese literal in the sources has an
/// entry here, and no two chunks define the same key.
enum LocalizationCatalog {
    /// Ordered for reading, not for lookup.
    static let chunks: [[String: String]] = [
        StringsCore.table,
        StringsCoreOperations.table,
        StringsApp.table,
        StringsChanges.table,
        StringsHistory.table,
        StringsRepository.table,
        StringsSettings.table,
        StringsShared.table
    ]

    static let english: [String: String] = {
        var merged: [String: String] = [:]
        for chunk in chunks {
            // `first` wins so the assembled table is independent of chunk order;
            // duplicates are a mistake the tests report by count, not something
            // to resolve silently at runtime.
            merged.merge(chunk) { first, _ in first }
        }
        return merged
    }()

    /// Sum of the chunk sizes. Equal to `english.count` unless a key is defined
    /// twice, which is what the duplicate test compares.
    static var declaredEntryCount: Int {
        chunks.reduce(0) { $0 + $1.count }
    }
}
