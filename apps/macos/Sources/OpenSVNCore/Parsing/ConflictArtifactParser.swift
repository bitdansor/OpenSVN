import Foundation

/// The three versions `svn` leaves on disk for a text conflict.
///
/// `mine` / `base` / `theirs` are the files a three-way merge needs. They are
/// **not** guessed from the file name: `svn` writes `<file>.mine` and one
/// `<file>.r<N>` per side, and which `r<N>` is the ancestor depends on the
/// operation. `svn info --xml` states it, so it is read from there.
public struct ConflictArtifacts: Sendable, Hashable {
    public let path: String
    /// Common ancestor (`.r<N>` for the left side).
    public let base: URL?
    /// My working file before the merge (`.mine`).
    public let mine: URL?
    /// The incoming version (`.r<N>` for the right side).
    public let theirs: URL?
    /// `update`, `merge`, `switch`, … — what produced this conflict.
    public let operation: String?
    /// `text`, `tree`, `property`.
    public let kind: String?

    /// A three-way merge is only meaningful when all three versions exist on disk
    /// and the conflict is textual. A tree conflict has no ancestor to diff
    /// against; a stale `info` result may name files that a cleanup removed.
    public var supportsMerge: Bool {
        guard kind == "text" else { return false }
        return [base, mine, theirs].allSatisfy { url in
            guard let url else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}

public enum ConflictArtifactError: Error, Equatable, Sendable {
    case malformedXML(String)
}

/// Parses the `<conflict>` block of `svn info --xml`.
///
/// Shape (svn 1.14), abbreviated:
///
///     <entry path="f.txt" revision="2">
///       <conflict operation="update" type="text">
///         <version side="source-left"  revision="1" …/>
///         <version side="source-right" revision="2" …/>
///         <prev-base-file>…/f.txt.r1</prev-base-file>
///         <prev-wc-file>…/f.txt.mine</prev-wc-file>
///         …
///       </conflict>
///     </entry>
public enum ConflictArtifactParser {
    public static func parse(infoXML data: Data) throws -> ConflictArtifacts? {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [])
        } catch {
            throw ConflictArtifactError.malformedXML(error.localizedDescription)
        }

        guard let entry = try document.nodes(forXPath: "/info/entry").first as? XMLElement else {
            return nil
        }
        guard let conflict = try entry.nodes(forXPath: "conflict").first as? XMLElement else {
            return nil
        }

        let path = entry.attribute(forName: "path")?.stringValue ?? ""
        let operation = conflict.attribute(forName: "operation")?.stringValue
        let kind = conflict.attribute(forName: "type")?.stringValue

        func file(_ name: String) -> URL? {
            guard let node = try? conflict.nodes(forXPath: name).first else { return nil }
            guard let value = node.stringValue, !value.isEmpty else { return nil }
            return URL(fileURLWithPath: value)
        }

        let base = file("prev-base-file")
        let mine = file("prev-wc-file")

        // The incoming side is not written to a named element; it is the `.r<N>`
        // sibling whose revision matches the right-hand version. Building the path
        // from the stated revision is exact, unlike picking the newest `.r*` file
        // (a second update would leave several). Whether it still exists is
        // `supportsMerge`'s business, not the parser's.
        var theirs: URL?
        let versions = (try? conflict.nodes(forXPath: "version")) as? [XMLElement] ?? []
        let right = versions.first { $0.attribute(forName: "side")?.stringValue == "source-right" }
        if let revision = right?.attribute(forName: "revision")?.stringValue,
           let minePath = mine?.path,
           minePath.hasSuffix(".mine") {
            let stem = String(minePath.dropLast(".mine".count))
            theirs = URL(fileURLWithPath: "\(stem).r\(revision)")
        }

        return ConflictArtifacts(
            path: path,
            base: base,
            mine: mine,
            theirs: theirs,
            operation: operation,
            kind: kind
        )
    }
}
