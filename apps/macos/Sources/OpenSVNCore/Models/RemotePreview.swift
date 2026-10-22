import Foundation

/// One path the server has changed since this working copy's base revision.
public struct RemoteChange: Sendable, Hashable, Identifiable {
    public var path: String
    /// What the server did: `added`, `modified`, `deleted`, or `none` for a
    /// pure property change.
    public var item: WCItemStatus
    /// What the server did to properties, independently of the file body.
    public var properties: WCItemStatus
    /// What this working copy has at the same path, for the conflict warning.
    public var localItem: WCItemStatus
    public var localProperties: WCItemStatus

    public init(
        path: String,
        item: WCItemStatus,
        properties: WCItemStatus = .none,
        localItem: WCItemStatus = .normal,
        localProperties: WCItemStatus = .none
    ) {
        self.path = path
        self.item = item
        self.properties = properties
        self.localItem = localItem
        self.localProperties = localProperties
    }

    public var id: String { path }

    /// The text is unchanged on the server; only properties moved.
    public var isPropertyOnly: Bool {
        item != .modified && item != .added && item != .deleted && properties == .modified
    }

    /// A warning, not a verdict.
    ///
    /// `svn update` merges disjoint edits silently and only reports a conflict
    /// when the same lines moved. Predicting the merge outcome would require the
    /// content, so the sheet says "可能" and the number of files where both
    /// sides touched the same path — the one fact that matters before updating.
    public var conflictsWithLocal: Bool {
        switch item {
        case .modified:
            switch localItem {
            case .modified, .conflicted, .added, .replaced, .missing, .deleted:
                return true
            default:
                return localProperties == .modified
            }
        case .deleted:
            switch localItem {
            case .modified, .conflicted, .added, .replaced:
                return true
            default:
                return false
            }
        case .added:
            // A server-side add at a path we already have unversioned is the
            // classic `obstructed` update failure.
            switch localItem {
            case .unversioned, .added, .modified, .conflicted, .obstructed, .replaced:
                return true
            default:
                return false
            }
        default:
            return properties == .modified && localProperties == .modified
        }
    }
}

/// What `svn update` would bring in, computed before running it.
///
/// The point of this type is to answer one question at the moment the user is
/// about to press 更新: **will this quietly merge, or is it about to conflict
/// with what I have not committed yet?** Everything else here exists to make
/// that answer readable.
public struct RemotePreview: Sendable, Hashable {
    /// Paths with a server-side change. The working-copy root is not one of
    /// them: it only appears in `--show-updates` because a child moved.
    public var changes: [RemoteChange]
    /// A property change on the working-copy root itself, which svn reports as
    /// a change to `"."` and which has no other entry to represent it.
    public var rootPropertyChange: RemoteChange?
    public var workingCopyRevision: Int64?
    public var serverRevision: Int64?

    public init(
        changes: [RemoteChange] = [],
        rootPropertyChange: RemoteChange? = nil,
        workingCopyRevision: Int64? = nil,
        serverRevision: Int64? = nil
    ) {
        self.changes = changes
        self.rootPropertyChange = rootPropertyChange
        self.workingCopyRevision = workingCopyRevision
        self.serverRevision = serverRevision
    }

    public var isEmpty: Bool { changes.isEmpty && rootPropertyChange == nil }

    public var addedCount: Int { changes.filter { $0.item == .added }.count }
    public var modifiedCount: Int {
        changes.filter { $0.item == .modified || $0.isPropertyOnly }.count
    }
    public var deletedCount: Int { changes.filter { $0.item == .deleted }.count }

    /// Paths where both sides have work, so the update may stop on a conflict.
    public var conflictRisks: [RemoteChange] {
        changes.filter(\.conflictsWithLocal)
    }

    public var hasConflictsWithLocal: Bool { !conflictRisks.isEmpty }

    /// Builds the preview from a `svn status --show-updates` snapshot.
    ///
    /// `<repos-status>` is absent for unchanged paths, so `remoteItem == nil`
    /// means "nothing new on the server". The root entry is filtered out
    /// because it is reported whenever any child changed, and listing it would
    /// make a three-file update look like four changes.
    public static func make(from snapshot: StatusSnapshot) -> RemotePreview {
        let root = normalizedRoot(snapshot)

        var changes: [RemoteChange] = []
        var rootPropertyChange: RemoteChange?

        for entry in snapshot.entries {
            let remoteItem = entry.remoteItem
            let remoteProperties = entry.remoteProperties ?? .none
            // A path with neither a remote item nor a remote property change is
            // simply unchanged on the server.
            guard remoteItem != nil || remoteProperties == .modified else { continue }
            let item = remoteItem ?? .none
            let isUnchangedItem = (item == .none || item == .normal)
            guard !isUnchangedItem || remoteProperties == .modified else { continue }

            let change = RemoteChange(
                path: entry.path,
                item: item,
                properties: remoteProperties,
                localItem: entry.item,
                localProperties: entry.properties
            )

            if isRootEntry(entry.path, root: root) {
                // The root is only interesting when it carries its own property
                // change; otherwise it is a duplicate of its children.
                if item == .none || item == .normal {
                    rootPropertyChange = change
                }
                continue
            }
            changes.append(change)
        }

        changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        // A directory is reported as modified whenever one of its children
        // moved, so listing it next to that child counts one change twice and
        // makes a three-file update look like five. An ancestor is dropped only
        // when it has a changed child *and* no property change of its own —
        // a directory whose properties really moved is still worth a row.
        let paths = Set(changes.map(\.path))
        changes.removeAll { change in
            guard change.item == .modified, change.properties != .modified else { return false }
            let prefix = change.path.hasSuffix("/") ? change.path : change.path + "/"
            return paths.contains { $0 != change.path && $0.hasPrefix(prefix) }
        }

        return RemotePreview(
            changes: changes,
            rootPropertyChange: rootPropertyChange,
            workingCopyRevision: snapshot.workingCopyRevision,
            serverRevision: snapshot.serverRevision
        )
    }

    private static func normalizedRoot(_ snapshot: StatusSnapshot) -> String? {
        guard let target = snapshot.target, !target.isEmpty else { return nil }
        var value = target
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func isRootEntry(_ path: String, root: String?) -> Bool {
        if path.isEmpty || path == "." || path == "./" { return true }
        guard let root else { return false }
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value == root
    }
}
