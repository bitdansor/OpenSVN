import Foundation

/// Which side a conflicted region should be resolved with.
public enum MergeChoice: String, Sendable, Hashable, CaseIterable {
    /// Keep my lines, drop the incoming ones.
    case mine
    /// Take the incoming lines, drop mine.
    case theirs
    /// Keep both, mine first — the "we both added something" case.
    case both
}

/// A region both sides changed differently.
public struct MergeConflict: Sendable, Hashable, Identifiable {
    public let id: Int
    public let baseLines: [String]
    public let mineLines: [String]
    public let theirsLines: [String]

    /// Mine already equals base: taking `theirs` is not a loss.
    public var mineIsUnchanged: Bool { mineLines == baseLines }
    /// Theirs already equals base: taking `mine` is not a loss.
    public var theirsIsUnchanged: Bool { theirsLines == baseLines }
}

/// A rendered piece of the merge. The result text is these, concatenated.
public enum MergeChunk: Sendable, Hashable {
    /// Identical on all three sides.
    case common([String])
    /// Only mine changed here; no decision needed.
    case mine([String])
    /// Only theirs changed here; no decision needed.
    case theirs([String])
    /// Both changed; the user must pick.
    case conflict(MergeConflict)

    public var lines: [String] {
        switch self {
        case .common(let lines), .mine(let lines), .theirs(let lines): return lines
        case .conflict(let conflict): return conflict.baseLines
        }
    }
}

public enum MergeError: Error, Equatable, Sendable {
    /// Rendering was asked for while some conflicts had no choice.
    case unresolved([Int])
}

public struct MergeResult: Sendable {
    public let chunks: [MergeChunk]
    /// Trailing newline of the *mine* file, preserved so a merge does not show up
    /// as a whole-file diff at the end of the commit.
    public let endsWithNewline: Bool

    public var conflicts: [MergeConflict] {
        chunks.compactMap { chunk in
            if case .conflict(let conflict) = chunk { return conflict }
            return nil
        }
    }

    public var isFullyResolved: Bool { conflicts.isEmpty }

    /// Builds the final file. Throws instead of silently writing conflict markers
    /// or dropping a region — a half-merged file is worse than no merge.
    public func render(_ choices: [Int: MergeChoice] = [:]) throws -> String {
        var unresolved: [Int] = []
        var out: [String] = []
        for chunk in chunks {
            switch chunk {
            case .common(let lines), .mine(let lines), .theirs(let lines):
                out.append(contentsOf: lines)
            case .conflict(let conflict):
                guard let choice = choices[conflict.id] else {
                    unresolved.append(conflict.id)
                    continue
                }
                switch choice {
                case .mine: out.append(contentsOf: conflict.mineLines)
                case .theirs: out.append(contentsOf: conflict.theirsLines)
                case .both: out.append(contentsOf: conflict.mineLines + conflict.theirsLines)
                }
            }
        }
        if !unresolved.isEmpty {
            throw MergeError.unresolved(unresolved)
        }
        let body = out.joined(separator: "\n")
        if endsWithNewline && !body.isEmpty { return body + "\n" }
        return body
    }
}

/// Line-based three-way merge, the same shape as `diff3` but with the decisions
/// left to the caller.
///
/// The algorithm is deliberately the simple one: find the lines that are
/// unchanged in both sides (sync points), and everything between two sync points
/// is a region. A region changed on one side only is taken automatically; a
/// region changed on both sides differently becomes a conflict. This is what
/// makes a merge UI possible — the user is never shown a region that has only
/// one sensible answer.
///
/// Known limitation, shared with `diff3`: duplicated blocks can be paired up in
/// more than one way, and the result may then be larger than a human would make
/// it. It is still never *wrong* (nothing is dropped), just occasionally coarse.
public enum ThreeWayMerge {
    public static func merge(base: String, mine: String, theirs: String) -> MergeResult {
        let baseLines = lines(of: base)
        let mineLines = lines(of: mine)
        let theirsLines = lines(of: theirs)
        return merge(base: baseLines, mine: mineLines, theirs: theirsLines,
                     endsWithNewline: mine.hasSuffix("\n"))
    }

    public static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static func merge(
        base: [String],
        mine: [String],
        theirs: [String],
        endsWithNewline: Bool
    ) -> MergeResult {
        let mineMatch = lineMatches(base, mine)
        let theirsMatch = lineMatches(base, theirs)

        var chunks: [MergeChunk] = []
        var conflictID = 0
        var b = 0
        var m = 0
        var t = 0

        // Emits the region base[b..<baseEnd] using the mine/theirs slices that
        // were collected for it.
        //
        // The comparison is against the *base* slice, not against each other: a
        // side that did not touch this region still contributes its old lines
        // here, and treating those as "the other candidate" turns every one-sided
        // edit into a conflict.
        func emitRegion(baseEnd: Int, mineEnd: Int, theirsEnd: Int) {
            let baseSlice = Array(base[b..<baseEnd])
            let mineSlice = Array(mine[m..<mineEnd])
            let theirsSlice = Array(theirs[t..<theirsEnd])

            let mineUnchanged = mineSlice == baseSlice
            let theirsUnchanged = theirsSlice == baseSlice

            if mineUnchanged && theirsUnchanged {
                if !baseSlice.isEmpty { chunks.append(.common(baseSlice)) }
            } else if mineUnchanged {
                if !theirsSlice.isEmpty { chunks.append(.theirs(theirsSlice)) }
            } else if theirsUnchanged {
                if !mineSlice.isEmpty { chunks.append(.mine(mineSlice)) }
            } else if mineSlice == theirsSlice {
                // Both sides made the same edit.
                if !mineSlice.isEmpty { chunks.append(.common(mineSlice)) }
            } else {
                chunks.append(.conflict(MergeConflict(
                    id: conflictID,
                    baseLines: baseSlice,
                    mineLines: mineSlice,
                    theirsLines: theirsSlice
                )))
                conflictID += 1
            }
        }

        while b < base.count {
            // Next line that is unchanged in both sides: everything before it is
            // a region that somebody touched.
            var sync = b
            while sync < base.count, mineMatch[sync] == nil || theirsMatch[sync] == nil {
                sync += 1
            }

            let mineEnd = sync < base.count ? mineMatch[sync]! : mine.count
            let theirsEnd = sync < base.count ? theirsMatch[sync]! : theirs.count

            // `sync == b` alone is not enough to call the line common: both sides
            // may have *inserted* lines before it, in which case the cursors still
            // sit behind the match. Missing that check silently drops insertions
            // that precede an unchanged line — the exact case `mine = a, X, b`
            // over `base = a, b`.
            if sync == b, m == mineEnd, t == theirsEnd {
                chunks.append(.common([base[b]]))
                b += 1
                m += 1
                t += 1
                continue
            }

            emitRegion(baseEnd: sync, mineEnd: mineEnd, theirsEnd: theirsEnd)
            b = sync
            m = mineEnd
            t = theirsEnd

            if sync < base.count {
                chunks.append(.common([base[sync]]))
                b = sync + 1
                m = mineMatch[sync]! + 1
                t = theirsMatch[sync]! + 1
            }
        }

        // Content past the last base line: appends on either side, and the whole
        // file when the base is empty. Without this, two people adding a section
        // at the end of a file would silently get only one of them.
        if m < mine.count || t < theirs.count {
            emitRegion(baseEnd: base.count, mineEnd: mine.count, theirsEnd: theirs.count)
        }

        return MergeResult(chunks: chunks, endsWithNewline: endsWithNewline)
    }

    // MARK: - Matching

    /// For each base line, the index of the line it corresponds to on the other
    /// side, or nil when the line was changed or deleted.
    ///
    /// Common prefix and suffix are stripped first: real conflicts are local, and
    /// without the strip a two-line change in a ten-thousand-line file would build
    /// a ten-thousand-square table.
    static func lineMatches(_ a: [String], _ b: [String]) -> [Int: Int] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }

        var matches: [Int: Int] = [:]
        for i in 0..<prefix { matches[i] = i }

        let aMid = Array(a[prefix..<(a.count - suffix)])
        let bMid = Array(b[prefix..<(b.count - suffix)])
        for (i, j) in longestCommonSubsequence(aMid, bMid) {
            matches[prefix + i] = prefix + j
        }

        for k in 0..<suffix {
            matches[a.count - 1 - k] = b.count - 1 - k
        }
        return matches
    }

    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        // Bounded on purpose: an unbounded O(n·m) table over two large files is a
        // memory spike at the exact moment the app is already busy. Beyond the
        // bound the region is treated as one conflict — coarse, never wrong.
        guard a.count <= 1500, b.count <= 1500 else { return [] }

        var table = [Int32](repeating: 0, count: (a.count + 1) * (b.count + 1))
        let width = b.count + 1
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    table[i * width + j] = table[(i + 1) * width + j + 1] + 1
                } else {
                    table[i * width + j] = max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }

        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
