import Foundation

/// A local filter over already-loaded history.
///
/// Deliberately separate from the server-side search: `svn log --search` matches
/// any of author/date/message/changed paths with a single pattern and cannot be
/// narrowed to a field, while this filter is field-aware and instant. The two
/// are offered side by side rather than pretending one is the other.
public struct LogFilter: Sendable, Hashable {
    /// Free text, matched against message, author, revision number (`r123`), and
    /// changed paths. Whitespace-separated terms must all match.
    public var text: String
    public var author: String?
    /// Substring of at least one changed path.
    public var path: String?
    /// Inclusive lower bound on the commit date.
    public var from: Date?
    /// Inclusive upper bound on the commit date.
    public var to: Date?

    public init(
        text: String = "",
        author: String? = nil,
        path: String? = nil,
        from: Date? = nil,
        to: Date? = nil
    ) {
        self.text = text
        self.author = author
        self.path = path
        self.from = from
        self.to = to
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && author == nil
            && path == nil
            && from == nil
            && to == nil
    }

    /// How many independent conditions are active. Used by the UI to decide
    /// whether to show a "清除筛选" affordance and how to describe the state.
    public var conditionCount: Int {
        var count = 0
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if author != nil { count += 1 }
        if path != nil { count += 1 }
        if from != nil || to != nil { count += 1 }
        return count
    }

    public func matches(_ entry: LogEntry) -> Bool {
        if let author, !author.isEmpty {
            guard (entry.author ?? "") == author else { return false }
        }

        if let path, !path.isEmpty {
            let needle = path.lowercased()
            guard entry.changedPaths.contains(where: { $0.path.lowercased().contains(needle) }) else {
                return false
            }
        }

        if let from {
            guard let date = entry.date, date >= from else { return false }
        }
        if let to {
            guard let date = entry.date, date <= to else { return false }
        }

        let terms = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        guard !terms.isEmpty else { return true }

        let revisionToken = "r\(entry.revision)"
        let haystack = ([entry.message, entry.author ?? "", revisionToken]
            + entry.changedPaths.map(\.path))
            .joined(separator: "\n")
            .lowercased()

        return terms.allSatisfy { haystack.contains($0) }
    }

    public func apply(to entries: [LogEntry]) -> [LogEntry] {
        guard !isEmpty else { return entries }
        return entries.filter(matches)
    }

    /// The pattern handed to `svn log --search` when the user asks the server.
    ///
    /// Only the free text can travel: svn cannot search "author equals X" or
    /// "changed in the last week". Sending a field condition would silently
    /// change its meaning into "any field contains this", so it is dropped and
    /// the reason is reported by the caller.
    public var serverSearchPattern: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Conditions that the server search cannot honour.
    public var conditionsNotSearchableOnServer: [String] {
        var names: [String] = []
        if author != nil { names.append("作者") }
        if path != nil { names.append("路径") }
        if from != nil || to != nil { names.append("日期") }
        return names
    }
}
