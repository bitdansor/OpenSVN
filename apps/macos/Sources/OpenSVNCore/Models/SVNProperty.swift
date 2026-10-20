import Foundation

/// One versioned property on a path.
///
/// Properties are metadata that travels with the node: `svn:ignore` on a
/// directory, `svn:eol-style` on a file, `custom:owner` from a team's own
/// convention. The GUI used to display "属性" as a status badge and nothing
/// else — reading and writing them needed the command line.
public struct SVNProperty: Sendable, Hashable, Identifiable {
    public var name: String
    public var value: String

    public var id: String { name }

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    /// Properties Subversion maintains itself. They are shown (hiding them makes
    /// `svn:entry:*` appear to vanish between `svn` versions) but never written:
    /// `svn` rejects them anyway, and a confusing failure is worse than a
    /// disabled control.
    public var isReserved: Bool {
        name.hasPrefix("svn:entry:") || name.hasPrefix("svn:wc:")
    }

    /// `svn:ignore` is the only property whose value is a list users edit by
    /// hand, so it gets a decoded view.
    public var isIgnoreList: Bool { name == "svn:ignore" }

    /// Non-empty lines, in order. `svn:ignore` is a newline-separated glob list.
    public var ignoreEntries: [String] {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Every property set on one path, as returned by `svn propget --xml`.
public struct PropertyTarget: Sendable, Hashable, Identifiable {
    public var path: String
    public var properties: [SVNProperty]

    public var id: String { path }

    public init(path: String, properties: [SVNProperty]) {
        self.path = path
        self.properties = properties
    }

    public func value(of name: String) -> String? {
        properties.first { $0.name == name }?.value
    }
}

/// Validation and formatting for property names.
///
/// Split out from the service so the rules can be tested without a working copy,
/// and so the UI can disable a control for the same reason the service would
/// reject the write.
public enum SVNPropertyName {
    /// Characters Subversion accepts in a property name. Everything outside this
    /// set fails in `svn` with a message about "bad property name", which is
    /// accurate and useless; catch it before spawning a process.
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:._-")

    /// - Throws: `SVNError(.invalidInvocation)` with a message naming the rule
    ///   that was broken.
    public static func validate(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SVNError(code: .invalidInvocation, message: "属性名不能为空")
        }
        guard trimmed == name else {
            throw SVNError(code: .invalidInvocation, message: "属性名不能以空白开头或结尾")
        }
        guard name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SVNError(
                code: .invalidInvocation,
                message: "属性名只能包含字母、数字、冒号、点、下划线和短横线：\(name)"
            )
        }
        if name.hasPrefix("svn:entry:") || name.hasPrefix("svn:wc:") {
            throw SVNError(
                code: .invalidInvocation,
                message: "「\(name)」是 Subversion 内部使用的属性，不能手动设置"
            )
        }
        // Custom properties need a namespace so they cannot collide with future
        // `svn:` properties. `svn` enforces this; the message here explains it.
        guard name.contains(":") else {
            throw SVNError(
                code: .invalidInvocation,
                message: "自定义属性必须带命名空间，例如 custom:\(name)"
            )
        }
    }
}

/// What `ignore` actually did, so the UI can say "已忽略 2 项，1 项本来就被忽略"
/// instead of guessing.
public struct IgnoreOutcome: Sendable, Hashable {
    /// File names that were appended to an `svn:ignore` list.
    public var added: [String]
    /// File names already covered by an existing pattern.
    public var already: [String]

    public init(added: [String] = [], already: [String] = []) {
        self.added = added
        self.already = already
    }

    public var changedAnything: Bool { !added.isEmpty }
}

/// The `svn:ignore` value is a newline-separated list of *glob* patterns, which
/// makes "ignore this file" harder than appending its name: a file called
/// `a[1].txt` appended literally would match something else entirely.
public enum IgnoreList {
    /// Escapes a literal file name so the glob matcher reads it as itself.
    ///
    /// `svn:ignore` uses fnmatch-style patterns, where `*`, `?` and `[...]` are
    /// special. Wrapping a character in brackets makes it literal, which is the
    /// only escape the pattern syntax offers.
    public static func pattern(for name: String) -> String {
        var result = ""
        result.reserveCapacity(name.count)
        for character in name {
            switch character {
            case "*": result += "[*]"
            case "?": result += "[?]"
            case "[": result += "[[]"
            case "]": result += "[]]"
            default: result.append(character)
            }
        }
        return result
    }

    public static func entries(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Returns the new value with `name` appended, or `nil` when the name is
    /// already covered — in which case no `propset` should run at all, because a
    /// no-op write would still show up as a property modification to commit.
    public static func adding(_ name: String, to value: String?) -> String? {
        let escaped = pattern(for: name)
        let existing = entries(value)
        if existing.contains(name) || existing.contains(escaped) { return nil }
        return (existing + [escaped]).joined(separator: "\n")
    }
}
