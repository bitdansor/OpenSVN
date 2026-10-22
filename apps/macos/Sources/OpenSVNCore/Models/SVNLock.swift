import Foundation

/// What a successful `svn lock` did, per path.
///
/// `svn lock` has no `--xml` form, so this is the one place in the core that
/// reads human-readable output. It is kept deliberately small: the paths we
/// asked for are the authority, and the parsed text only adds the owner name for
/// the confirmation message.
public struct LockOutcome: Sendable, Hashable {
    /// Paths as requested by the caller, in the same order.
    public var lockedPaths: [String]
    /// Lock owner reported by svn. A steal replaces the previous holder, so this
    /// is the *new* owner, not the one that was displaced.
    public var owner: String?
    /// Redacted stdout, for the task detail and diagnostics.
    public var rawOutput: String

    public init(lockedPaths: [String], owner: String? = nil, rawOutput: String = "") {
        self.lockedPaths = lockedPaths
        self.owner = owner
        self.rawOutput = rawOutput
    }
}

/// What a successful `svn unlock` did.
public struct UnlockOutcome: Sendable, Hashable {
    public var unlockedPaths: [String]
    public var rawOutput: String

    public init(unlockedPaths: [String], rawOutput: String = "") {
        self.unlockedPaths = unlockedPaths
        self.rawOutput = rawOutput
    }
}

/// Repository-side locks for one working copy, keyed by absolute path.
///
/// Separate from `StatusEntry.repositoryLock` because the two answer different
/// questions. `repositoryLock` is the token *this* working copy holds; a lock
/// held by someone else only appears after a network round trip
/// (`svn status --show-updates`). Showing the first as if it were the second is
/// how a user comes to believe a file is free when it is not.
public struct LockSnapshot: Sendable, Hashable {
    public var locks: [String: RepositoryLock]
    /// Paths whose lock token this working copy holds.
    ///
    /// The distinction the UI needs: a lock we hold can be released by
    /// `unlock`; a lock someone else holds can only be *broken* with `--force`,
    /// which is a different, confirming action.
    public var ownPaths: Set<String>

    public init(locks: [String: RepositoryLock] = [:], ownPaths: Set<String> = []) {
        self.locks = locks
        self.ownPaths = ownPaths
    }

    public var isEmpty: Bool { locks.isEmpty }
    public var count: Int { locks.count }

    /// Exact match first, then a path-suffix match.
    ///
    /// The suffix fallback exists because `svn status` reports paths relative to
    /// the target when the target is relative, and the UI always holds the
    /// absolute path it got from somewhere else.
    public func lock(for path: String) -> RepositoryLock? {
        matchingKey(for: path).flatMap { locks[$0] }
    }

    /// Whether the lock on `path` is held by this working copy.
    public func isOwnLock(for path: String) -> Bool {
        guard let key = matchingKey(for: path) else { return false }
        return ownPaths.contains(key)
    }

    /// Paths among `candidates` whose lock is held by someone else.
    public func foreignLocks(among candidates: [String]) -> [String] {
        candidates.filter { path in
            guard lock(for: path) != nil else { return false }
            return !isOwnLock(for: path)
        }
    }

    private func matchingKey(for path: String) -> String? {
        if locks[path] != nil { return path }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        return locks.keys.first { key in
            let keyNormalized = key.hasSuffix("/") ? String(key.dropLast()) : key
            return keyNormalized == normalized
                || keyNormalized.hasSuffix("/" + normalized)
                || normalized.hasSuffix("/" + keyNormalized)
        }
    }

    /// Builds the snapshot from a status taken with `--show-updates`. A lock this
    /// working copy holds is preferred over the server's copy of the same lock:
    /// the local token is what `unlock` will use.
    public static func from(status: StatusSnapshot) -> LockSnapshot {
        var locks: [String: RepositoryLock] = [:]
        var ownPaths: Set<String> = []
        for entry in status.entries {
            if let lock = entry.repositoryLock ?? entry.remoteLock {
                locks[entry.path] = lock
            }
            if entry.repositoryLock != nil {
                ownPaths.insert(entry.path)
            }
        }
        return LockSnapshot(locks: locks, ownPaths: ownPaths)
    }
}

/// Parses the human-readable lines `svn lock` / `svn unlock` print on success.
///
/// The output is stable across releases and locales because svn does not
/// translate it: `'<path>' locked by user '<owner>'.` and `'<path>' unlocked.`.
/// Everything here is best-effort — a parse miss must never fail an operation
/// that svn already reported as successful.
public enum LockOutputParser {
    /// Paths svn reported as newly locked, in output order.
    public static func lockedPaths(in stdout: String) -> [String] {
        matches(in: stdout, pattern: #"^'(.+)' locked by user '[^']*'\.?$"#)
    }

    /// Paths svn reported as unlocked, in output order.
    public static func unlockedPaths(in stdout: String) -> [String] {
        matches(in: stdout, pattern: #"^'(.+)' unlocked\.?$"#)
    }

    /// The owner from the last "locked by user" line, if any.
    public static func owner(in stdout: String) -> String? {
        let pattern = #"locked by user '([^']*)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(stdout.startIndex..., in: stdout)
        guard let match = regex.matches(in: stdout, range: range).last,
              match.numberOfRanges > 1,
              let ownerRange = Range(match.range(at: 1), in: stdout) else { return nil }
        return String(stdout[ownerRange])
    }

    private static func matches(in stdout: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        let range = NSRange(stdout.startIndex..., in: stdout)
        return regex.matches(in: stdout, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let pathRange = Range(match.range(at: 1), in: stdout) else { return nil }
            return String(stdout[pathRange])
        }
    }
}
