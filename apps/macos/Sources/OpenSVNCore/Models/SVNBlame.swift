import Foundation

/// One line of `svn blame --xml`.
///
/// The XML carries only the annotation, not the text: it emits
/// `<entry line-number="1"><commit revision=…><author/>…</entry>`. The content is
/// paired in afterwards from the working file.
///
/// `revision == nil` is meaningful, not missing data: `svn blame` on a working
/// copy reports locally modified lines with no revision at all (the CLI prints
/// `-` in both columns). That is how uncommitted work is told apart from an
/// empty or unparsable answer.
public struct BlameLine: Sendable, Hashable, Identifiable {
    public var lineNumber: Int
    public var revision: Int64?
    public var author: String?
    public var date: Date?
    /// The file's text at that line, filled in after the fact.
    public var content: String

    public var id: Int { lineNumber }

    public init(
        lineNumber: Int,
        revision: Int64? = nil,
        author: String? = nil,
        date: Date? = nil,
        content: String = ""
    ) {
        self.lineNumber = lineNumber
        self.revision = revision
        self.author = author
        self.date = date
        self.content = content
    }
}

/// The result of one `svn blame`.
public struct BlameResult: Sendable, Hashable {
    public var target: String?
    public var lines: [BlameLine]

    public init(target: String? = nil, lines: [BlameLine]) {
        self.target = target
        self.lines = lines
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// Lines that exist only in the working copy.
    public var uncommittedLineCount: Int { lines.filter { $0.revision == nil }.count }

    public var hasLocalEdits: Bool { uncommittedLineCount > 0 }

    /// Authors in first-appearance order, with how many lines each owns.
    ///
    /// Annotating a file is usually a question about one person — "who wrote
    /// this, and how much of it is theirs" — so the summary is worth computing
    /// once here rather than in the view. Uncommitted lines are left out: they
    /// belong to nobody yet, and counting them under a name would invent an
    /// author.
    public var authorship: [(author: String, lines: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for line in lines {
            guard let name = line.author, !name.isEmpty else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    /// Pairs the annotation with the file's text.
    ///
    /// Length is allowed to differ. `svn blame` annotates the *BASE* revision of
    /// a working copy file, so a locally edited file can have more or fewer
    /// lines than the annotation; the surplus is dropped and the missing tail is
    /// left empty rather than shifting every row by one, which would silently
    /// attribute text to the wrong revision.
    public mutating func attachContents(_ text: String) {
        var raw = text.components(separatedBy: "\n")
        // A trailing newline produces a final empty component that is not a line.
        if raw.last == "" { raw.removeLast() }

        for index in lines.indices {
            guard lines[index].lineNumber > 0,
                  lines[index].lineNumber <= raw.count else { continue }
            lines[index].content = raw[lines[index].lineNumber - 1]
        }
    }
}
