import Foundation

/// Parsers for the three machine-readable SVN documents OpenSVN relies on.
///
/// Only `--xml` output is parsed (red line R7). Each function is pure: same
/// bytes in, same model out, on any machine.
public enum SVNXMLParser {

    // MARK: - status

    public static func parseStatus(_ data: Data) throws -> StatusSnapshot {
        let document = try loadDocument(data, kind: "status")
        guard let root = document.rootElement(), root.name == "status" else {
            throw parseError("根元素不是 <status>", data)
        }

        let targetPath = root.elements(forName: "target").first?
            .attribute(forName: "path")?.stringValue

        var entries: [StatusEntry] = []
        for target in root.elements(forName: "target") {
            for entryElement in target.elements(forName: "entry") {
                if let entry = parseStatusEntry(entryElement) {
                    entries.append(entry)
                }
            }
        }

        let revision = entries.compactMap(\.revision).min()
        return StatusSnapshot(target: targetPath, entries: entries, workingCopyRevision: revision)
    }

    private static func parseStatusEntry(_ element: XMLElement) -> StatusEntry? {
        guard let path = element.attribute(forName: "path")?.stringValue else { return nil }

        let wcStatus = element.elements(forName: "wc-status").first
        let reposStatus = element.elements(forName: "repos-status").first

        let itemToken = wcStatus?.attribute(forName: "item")?.stringValue ?? "none"
        let propToken = wcStatus?.attribute(forName: "props")?.stringValue ?? "none"
        let item = WCItemStatus(rawValue: itemToken)
        let properties = WCItemStatus(rawValue: propToken)

        var conflicts: ConflictFlags = []
        if item == .conflicted { conflicts.insert(.text) }
        if properties == .conflicted { conflicts.insert(.property) }
        let treeConflicted = wcStatus?.attribute(forName: "tree-conflicted")?.stringValue == "true"
        if treeConflicted { conflicts.insert(.tree) }

        var revision: Int64?
        if let raw = wcStatus?.attribute(forName: "revision")?.stringValue {
            revision = Int64(raw)
        } else if let raw = element.attribute(forName: "revision")?.stringValue {
            revision = Int64(raw)
        }

        let isCopied = element.attribute(forName: "copied")?.stringValue == "true"
            || wcStatus?.attribute(forName: "copied")?.stringValue == "true"

        var repositoryLock: RepositoryLock?
        if let lockElement = wcStatus?.elements(forName: "lock").first {
            repositoryLock = parseLock(lockElement)
        }
        // `<repos-status>` only appears with `--show-updates`. Its lock is the
        // server's view, which is how another user's lock becomes visible at all.
        var remoteLock: RepositoryLock?
        if let lockElement = reposStatus?.elements(forName: "lock").first {
            remoteLock = parseLock(lockElement)
        }

        var commit: CommitInfo?
        if let commitElement = wcStatus?.elements(forName: "commit").first,
           let rawRevision = commitElement.attribute(forName: "revision")?.stringValue,
           let commitRevision = Int64(rawRevision) {
            commit = CommitInfo(
                revision: commitRevision,
                author: commitElement.elements(forName: "author").first?.stringValue,
                date: SVNDateParser.parse(commitElement.elements(forName: "date").first?.stringValue)
            )
        }

        _ = reposStatus // repos-status carries server-side state; only its lock is used.

        return StatusEntry(
            path: path,
            item: item,
            properties: properties,
            revision: revision,
            isCopied: isCopied,
            conflicts: conflicts,
            repositoryLock: repositoryLock,
            remoteLock: remoteLock,
            // `incomplete` means an earlier operation left the working copy in a
            // state that needs `svn cleanup`; it is a local lock signal, not a
            // repository lock.
            isWorkingCopyLocked: item == .incomplete,
            changelist: element.attribute(forName: "changelist")?.stringValue,
            commit: commit,
            depth: wcStatus?.attribute(forName: "depth")?.stringValue
        )
    }

    /// `<lock>` appears in both `<wc-status>` and `<repos-status>`, with the same
    /// shape. `token` is intentionally kept in the model but never logged: it is
    /// the credential that authorises `unlock`.
    private static func parseLock(_ element: XMLElement) -> RepositoryLock {
        RepositoryLock(
            token: element.elements(forName: "token").first?.stringValue,
            owner: element.elements(forName: "owner").first?.stringValue,
            comment: element.elements(forName: "comment").first?.stringValue,
            createdAt: SVNDateParser.parse(element.elements(forName: "created").first?.stringValue)
        )
    }

    // MARK: - log

    public static func parseLog(_ data: Data) throws -> [LogEntry] {
        let document = try loadDocument(data, kind: "log")
        guard let root = document.rootElement(), root.name == "log" else {
            throw parseError("根元素不是 <log>", data)
        }

        return root.elements(forName: "logentry").compactMap { entryElement in
            guard let raw = entryElement.attribute(forName: "revision")?.stringValue,
                  let revision = Int64(raw) else { return nil }

            let paths = entryElement.elements(forName: "paths").first?
                .elements(forName: "path")
                .compactMap { pathElement -> ChangedPath? in
                    guard let value = pathElement.stringValue else { return nil }
                    let actionToken = pathElement.attribute(forName: "action")?.stringValue ?? "?"
                    return ChangedPath(
                        path: value,
                        action: ChangedPath.Action(rawValue: actionToken) ?? .unknown,
                        kind: pathElement.attribute(forName: "kind")?.stringValue,
                        copyFromPath: pathElement.attribute(forName: "copyfrom-path")?.stringValue,
                        copyFromRevision: pathElement.attribute(forName: "copyfrom-rev")?.stringValue.flatMap(Int64.init)
                    )
                } ?? []

            let author = entryElement.elements(forName: "author").first?.stringValue
            return LogEntry(
                revision: revision,
                author: (author?.isEmpty ?? true) ? nil : author,
                date: SVNDateParser.parse(entryElement.elements(forName: "date").first?.stringValue),
                message: entryElement.elements(forName: "msg").first?.stringValue ?? "",
                changedPaths: paths
            )
        }
    }

    // MARK: - info

    public static func parseInfo(_ data: Data) throws -> InfoReport {
        let document = try loadDocument(data, kind: "info")
        guard let root = document.rootElement(), root.name == "info" else {
            throw parseError("根元素不是 <info>", data)
        }

        let entries = root.elements(forName: "entry").compactMap(parseInfoEntry)
        guard !entries.isEmpty else {
            throw parseError("<info> 中没有 <entry>", data)
        }
        return InfoReport(entries: entries)
    }

    private static func parseInfoEntry(_ element: XMLElement) -> RepositoryInfo? {
        guard let path = element.attribute(forName: "path")?.stringValue,
              let url = element.elements(forName: "url").first?.stringValue else {
            return nil
        }

        let repository = element.elements(forName: "repository").first
        let wcInfo = element.elements(forName: "wc-info").first
        let commit = element.elements(forName: "commit").first

        let kindToken = element.attribute(forName: "kind")?.stringValue ?? "none"
        let rawRevision = element.attribute(forName: "revision")?.stringValue

        var repositoryLock: RepositoryLock?
        if let lockElement = element.elements(forName: "lock").first {
            repositoryLock = RepositoryLock(
                token: lockElement.elements(forName: "token").first?.stringValue,
                owner: lockElement.elements(forName: "owner").first?.stringValue,
                comment: lockElement.elements(forName: "comment").first?.stringValue,
                createdAt: SVNDateParser.parse(lockElement.elements(forName: "created").first?.stringValue)
            )
        }

        return RepositoryInfo(
            path: path,
            url: url,
            repositoryRoot: repository?.elements(forName: "root").first?.stringValue,
            repositoryUUID: repository?.elements(forName: "uuid").first?.stringValue,
            revision: rawRevision.flatMap(Int64.init),
            kind: NodeKind(rawValue: kindToken),
            schedule: wcInfo?.elements(forName: "schedule").first?.stringValue,
            depth: wcInfo?.elements(forName: "depth").first?.stringValue,
            workingCopyRoot: wcInfo?.elements(forName: "wcroot-abspath").first?.stringValue,
            lastChangedRevision: commit?.attribute(forName: "revision")?.stringValue.flatMap(Int64.init),
            lastChangedAuthor: commit?.elements(forName: "author").first?.stringValue,
            lastChangedDate: SVNDateParser.parse(commit?.elements(forName: "date").first?.stringValue),
            repositoryLock: repositoryLock
        )
    }

    // MARK: - properties

    /// `svn proplist --xml --verbose [--recursive] <path>`.
    ///
    /// A path with no properties produces an empty `<properties>` element — no
    /// `<target>` at all — so an empty array means "nothing is set". A `<target>`
    /// with no children does not occur from svn itself but is accepted, because a
    /// future version emitting it would otherwise break the read path silently.
    public static func parseProperties(_ data: Data) throws -> [PropertyTarget] {
        let document = try loadDocument(data, kind: "propget")
        guard let root = document.rootElement(), root.name == "properties" else {
            throw parseError("根元素不是 <properties>", data)
        }

        return root.elements(forName: "target").map { element in
            let path = element.attribute(forName: "path")?.stringValue ?? ""
            let properties = element.elements(forName: "property").compactMap { property -> SVNProperty? in
                guard let name = property.attribute(forName: "name")?.stringValue else { return nil }
                // The value is the element's text, which may be empty: `svn
                // propset name "" path` is legal and means "present but empty",
                // which is different from "absent".
                return SVNProperty(name: name, value: property.stringValue ?? "")
            }
            return PropertyTarget(path: path, properties: properties)
        }
    }

    // MARK: - helpers

    private static func loadDocument(_ data: Data, kind: String) throws -> XMLDocument {
        guard !data.isEmpty else {
            throw parseError("空的 \(kind) XML", data)
        }
        do {
            return try XMLDocument(data: data, options: [])
        } catch {
            throw SVNError(
                code: .xmlParseFailure,
                message: "无法解析 svn \(kind) XML：\(error.localizedDescription)",
                diagnosticOutput: String(decoding: data.prefix(2048), as: UTF8.self)
            )
        }
    }

    private static func parseError(_ message: String, _ data: Data) -> SVNError {
        SVNError(
            code: .xmlParseFailure,
            message: message,
            diagnosticOutput: String(decoding: data.prefix(2048), as: UTF8.self)
        )
    }
}
