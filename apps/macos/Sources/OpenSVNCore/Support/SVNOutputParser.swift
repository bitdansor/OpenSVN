import Foundation

/// Result of a `svn diff` invocation.
public struct DiffResult: Sendable, Hashable {
    public var text: String
    public var isTruncated: Bool
    public var byteCount: Int

    public init(text: String, isTruncated: Bool = false, byteCount: Int = 0) {
        self.text = text
        self.isTruncated = isTruncated
        self.byteCount = byteCount
    }

    public var isEmpty: Bool { text.isEmpty }
}

/// Parses the human-readable progress output of `svn update` / `svn commit`.
///
/// This is the one place where reading non-XML output is acceptable: these lines
/// are *only* used for progress display and summaries. Every decision (status,
/// conflict state, revision) is taken from XML elsewhere.
public enum SVNOutputParser {
    public struct UpdateOutput: Sendable {
        public var updated: [String] = []
        public var added: [String] = []
        public var deleted: [String] = []
        public var conflicted: [String] = []
        public var merged: [String] = []
    }

    public static func parseUpdate(_ output: String) -> UpdateOutput {
        var result = UpdateOutput()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            guard let first = text.first, "ADUCGER".contains(first) else { continue }
            // Status column is followed by whitespace padding, then the path.
            let remainder = text.dropFirst()
            let trimmed = remainder.drop(while: { $0 == " " })
            guard !trimmed.isEmpty, !trimmed.hasPrefix("'") else { continue }
            let path = String(trimmed)
            switch first {
            case "A": result.added.append(path)
            case "D": result.deleted.append(path)
            case "C": result.conflicted.append(path)
            case "G": result.merged.append(path)
            case "U", "E", "R": result.updated.append(path)
            default: break
            }
        }
        return result
    }

    public static func parseUpdatedRevision(_ output: String) -> Int64? {
        guard let range = output.range(of: #"(?i)(updated to|at) revision (\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = output[range]
        guard let digits = match.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int64(match[digits])
    }

    public struct CommitOutput: Sendable {
        public var revision: Int64?
        public var sending: [String] = []
        public var adding: [String] = []
        public var deleting: [String] = []
        public var replacing: [String] = []
        /// `svn commit` prints "Transmitting file data ..." then "Committed revision N."
        public var committed: Bool { revision != nil }
    }

    public static func parseCommit(_ output: String) -> CommitOutput {
        var result = CommitOutput()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            let lower = text.lowercased()
            if lower.hasPrefix("committed revision") {
                if let digits = text.range(of: #"\d+"#, options: .regularExpression) {
                    result.revision = Int64(text[digits])
                }
                continue
            }
            for (prefix, keyPath) in [
                ("sending ", \CommitOutput.sending),
                ("adding ", \CommitOutput.adding),
                ("deleting ", \CommitOutput.deleting),
                ("replacing ", \CommitOutput.replacing)
            ] {
                if lower.hasPrefix(prefix) {
                    let path = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    result[keyPath: keyPath].append(path)
                    break
                }
            }
        }
        return result
    }

    /// True when `svn` reported that the working copy is already at the newest
    /// revision ("At revision 7." / "Updated to revision 7.").
    public static func isUpToDate(_ output: String) -> Bool {
        output.range(of: #"(?im)^(at|updated to) revision \d+\.?$"#, options: .regularExpression) != nil
    }
}
