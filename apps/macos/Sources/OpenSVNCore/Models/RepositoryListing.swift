import Foundation

/// One child of a repository directory, from `svn list --xml`.
///
/// Unlike `StatusEntry` this describes the *server*, not a working copy: there is
/// no schedule, no conflict state, and no local modification — only what the
/// repository holds at the revision that was asked for.
public struct RemoteEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var kind: NodeKind
    /// Present for files only; svn omits it for directories.
    public var size: Int64?
    public var revision: Int64?
    public var author: String?
    public var date: Date?

    public var id: String { name }

    public init(
        name: String,
        kind: NodeKind,
        size: Int64? = nil,
        revision: Int64? = nil,
        author: String? = nil,
        date: Date? = nil
    ) {
        self.name = name
        self.kind = kind
        self.size = size
        self.revision = revision
        self.author = author
        self.date = date
    }

    public var isDirectory: Bool { kind == .dir }
}

/// The contents of one repository directory.
public struct RepositoryListing: Sendable, Hashable {
    /// The URL that was listed, as svn echoed it back.
    public var path: String
    public var entries: [RemoteEntry]

    public init(path: String, entries: [RemoteEntry]) {
        self.path = path
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Directories first, then files, each alphabetically.
    ///
    /// The same order Finder uses, because this list is read by the same eyes:
    /// mixing files and directories by name makes a tree look flat.
    public var sortedEntries: [RemoteEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// A URL split into the parts a breadcrumb needs.
///
/// Kept in the core rather than assembled in the view: "where am I, and what is
/// one level up" is the same question in every repository browser, and getting
/// it wrong at the repository root is a crash waiting to happen.
public struct RepositoryPath: Sendable, Hashable {
    /// Full URL being browsed.
    public var url: String
    /// Repository root URL, when known. Breadcrumb stops here: above it is not
    /// another directory, it is the repository itself.
    public var rootURL: String?

    public init(url: String, rootURL: String? = nil) {
        self.url = url
        self.rootURL = rootURL
    }

    /// Path segments below the repository root, or below the URL's own scheme and
    /// host when the root is unknown.
    public var components: [String] {
        let base = baseURL
        var value = url
        if value.hasPrefix(base) {
            value = String(value.dropFirst(base.count))
        }
        return value
            .split(separator: "/")
            .map(String.init)
    }

    public var baseURL: String {
        rootURL ?? hostPrefix
    }

    private var hostPrefix: String {
        guard let schemeRange = url.range(of: "://") else { return url }
        let afterScheme = url[schemeRange.upperBound...]
        guard let slash = afterScheme.firstIndex(of: "/") else { return url }
        return String(url[..<slash])
    }

    public var lastComponent: String {
        components.last ?? (url as NSString).lastPathComponent
    }

    /// One level up, or `nil` at the repository root.
    public func parent() -> RepositoryPath? {
        var parts = components
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
        var next = baseURL
        for part in parts {
            next += "/" + part
        }
        return RepositoryPath(url: next, rootURL: rootURL)
    }

    public func appending(_ name: String) -> RepositoryPath {
        var value = url
        if !value.hasSuffix("/") { value += "/" }
        value += name
        return RepositoryPath(url: value, rootURL: rootURL)
    }

    /// Root-first breadcrumb, always including the repository root itself.
    public func breadcrumb() -> [(name: String, path: RepositoryPath)] {
        var items: [(String, RepositoryPath)] = [
            (repositoryLabel, RepositoryPath(url: baseURL, rootURL: rootURL))
        ]
        var current = baseURL
        for part in components {
            current += "/" + part
            items.append((part, RepositoryPath(url: current, rootURL: rootURL)))
        }
        return items
    }

    private var repositoryLabel: String {
        // `file://` URLs have no host at all, so the leaf name is the only thing
        // that can name the repository. Checking the host first labelled every
        // local repository "仓库" — the same word for all of them.
        if let rootURL {
            let leaf = (rootURL as NSString).lastPathComponent
            if !leaf.isEmpty { return leaf }
        }
        if let host = URL(string: rootURL ?? url)?.host, !host.isEmpty { return host }
        return "仓库"
    }
}

/// A remote write that svn performed and committed in one step.
///
/// `svn mkdir URL`, `svn copy URL URL`, `svn move URL URL` and `svn delete URL`
/// each create their own commit, so there is no staging step to model. The
/// revision is parsed from stdout and is optional on purpose: the exit code is
/// the contract, the message is a convenience, and a missing number must not turn
/// a successful operation into a failure.
public struct RemoteCommit: Sendable, Hashable {
    public var revision: Int64?
    public var summary: String

    public init(revision: Int64?, summary: String) {
        self.revision = revision
        self.summary = summary
    }

    /// Extracts `Committed revision 12.` without depending on the rest of svn's
    /// output, which varies by operation and locale.
    public static func parseRevision(_ output: String) -> Int64? {
        guard let range = output.range(of: "Committed revision ") else { return nil }
        let rest = output[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int64(digits)
    }
}
