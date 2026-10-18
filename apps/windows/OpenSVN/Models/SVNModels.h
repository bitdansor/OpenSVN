// OpenSVN — shared data model for the Windows implementation.
//
// Mirrors `specifications/data-models.md` field for field. Names are snake_case
// per C++ convention; the comment on each field names the contract field it
// corresponds to. Nothing in this header touches Windows headers, so it can be
// compiled and unit-tested on any platform (the parser contract tests rely on
// that: the same fixture must produce the same JSON on both platforms).
//
// Status: the macOS side is implemented and tested against recorded fixtures.
// This header is written but has not yet been compiled on Windows — see
// apps/windows/README.md for what is verified and what is not.

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace opensvn {

// ---------------------------------------------------------------------------
// svn status tokens
// ---------------------------------------------------------------------------

// `wc-status@item` / `wc-status@props`. Unknown tokens are preserved verbatim in
// `WCItemStatus::unknown` — never dropped, never silently turned into `normal`
// (data-models.md §2).
struct WCItemStatus {
    enum class Kind {
        added, conflicted, deleted, external, ignored, incomplete, invalid,
        merged, missing, modified, none, normal, obstructed, replaced,
        unversioned, unknown
    };

    Kind kind = Kind::none;
    std::string raw;  // only meaningful when kind == unknown

    WCItemStatus() = default;
    explicit WCItemStatus(Kind value) : kind(value) {}
    WCItemStatus(Kind value, std::string original)
        : kind(value), raw(std::move(original)) {}

    static WCItemStatus Parse(std::string_view token);
    std::string_view ToString() const;  // raw token, suitable for the contract JSON
    bool IsUnknown() const { return kind == Kind::unknown; }

    bool operator==(const WCItemStatus&) const = default;
};

// ---------------------------------------------------------------------------
// Conflicts (data-models.md §3)
// ---------------------------------------------------------------------------

// A path can carry several at once. Serialised in the stable order
// text, property, tree — contract tests compare that order.
enum ConflictFlag : std::uint8_t {
    kConflictNone = 0,
    kConflictText = 1u << 0,
    kConflictProperty = 1u << 1,
    kConflictTree = 1u << 2,
};

struct ConflictFlags {
    std::uint8_t bits = kConflictNone;

    bool Has(ConflictFlag flag) const { return (bits & flag) != 0; }
    void Set(ConflictFlag flag) { bits |= flag; }
    bool IsEmpty() const { return bits == kConflictNone; }
    bool HasAny() const { return bits != kConflictNone; }

    // `["text", "property", "tree"]` subset, in that order.
    std::vector<std::string> ToList() const;

    bool operator==(const ConflictFlags&) const = default;
};

// ---------------------------------------------------------------------------
// Locks — two unrelated things that must never be conflated (data-models.md §1)
// ---------------------------------------------------------------------------

// Server-side `svn lock`, from `wc-status/lock` or `info/entry/lock`.
struct RepositoryLock {
    std::string token;
    std::string owner;
    std::string comment;
    std::string created;  // UTC ISO-8601, normalised like every other date
};

struct CommitInfo {
    std::int64_t revision = 0;
    std::optional<std::string> author;  // empty <author/> becomes nullopt
    std::string date;
};

struct StatusEntry {
    std::string path;                  // entry@path, verbatim, no realpath()
    WCItemStatus text_status;          // item
    WCItemStatus property_status;       // properties
    std::optional<std::int64_t> revision;  // wc-status@revision, else entry@revision
    bool is_copied = false;            // entry@copied / wc-status@copied
    ConflictFlags conflicts;
    std::optional<RepositoryLock> repository_lock;
    bool is_working_copy_locked = false;  // local lock: cleanup clears this
    std::optional<std::string> changelist;
    std::optional<CommitInfo> commit;
    std::optional<std::string> depth;

    bool HasConflicts() const { return conflicts.HasAny(); }
};

struct StatusSnapshot {
    std::string target;
    std::vector<StatusEntry> entries;
    std::optional<std::int64_t> working_copy_revision;
};

// Category used for grouping in the UI: conflict wins, then text status,
// `missing` folds into the deleted group (data-models.md §2, derived fields).
enum class StatusCategory { conflicted, modified, added, deleted, replaced, unversioned, ignored, normal, other };

StatusCategory CategoryOf(const StatusEntry& entry);

// ---------------------------------------------------------------------------
// History (data-models.md §4)
// ---------------------------------------------------------------------------

enum class NodeKind { none, file, dir, unknown };

struct ChangedPath {
    std::string action;  // A/D/M/R, '?' when svn emits something unexpected
    std::string path;    // repository-absolute, /trunk/...
    std::optional<std::string> copy_from_path;
    std::optional<std::int64_t> copy_from_revision;
};

struct LogEntry {
    std::int64_t revision = 0;
    std::optional<std::string> author;
    std::string date;
    std::string message;  // newlines preserved; empty string when absent
    std::vector<ChangedPath> changed_paths;
};

struct LogPage {
    std::vector<LogEntry> entries;
    std::size_t limit = 0;

    // Same rule as the macOS side: a full page means the next page may exist.
    bool has_more() const { return entries.size() >= limit; }
    std::optional<std::int64_t> oldest_revision() const;
};

// ---------------------------------------------------------------------------
// Info (data-models.md §5)
// ---------------------------------------------------------------------------

struct InfoReport {
    std::string path;
    std::string url;
    std::optional<std::string> repository_root;
    std::optional<std::string> repository_uuid;
    std::optional<std::int64_t> revision;
    NodeKind kind = NodeKind::none;
    std::optional<std::string> schedule;
    std::optional<std::string> depth;
    std::optional<std::string> working_copy_root;  // absent for URL targets
    std::optional<CommitInfo> last_changed;
    std::optional<RepositoryLock> repository_lock;
};

// ---------------------------------------------------------------------------
// Errors (error-codes.md)
// ---------------------------------------------------------------------------

// Mirrors `SVNErrorCode` in
// apps/macos/Sources/OpenSVNCore/Models/SVNError.swift case for case, and the
// table in specifications/error-codes.md. Identifiers are shared: a support
// report saying "SVN-0004" means the same thing on both platforms.
enum class SVNErrorCode {
    svnNotFound, unsupportedVersion, notAWorkingCopy, workingCopyLocked,
    workingCopyNeedsUpgrade, authenticationRequired, authorizationFailed,
    networkFailure, outOfDate, conflictRemains, pathNotFound, backupFailed,
    hostKeyVerificationFailed, timeout, cancelled, confirmationRequired,
    invalidInvocation, xmlParseFailure, commandFailed, unknown
};

// How the UI should present the failure (error-codes.md §severity).
enum class ErrorSeverity { recoverable, needsUserAction, fatal };

struct SVNError {
    SVNErrorCode code = SVNErrorCode::unknown;
    std::string message;             // redacted, safe to show
    std::string diagnostic_output;   // redacted
    std::string svn_code;            // e.g. E155004
    int exit_code = 0;

    std::string identifier() const;   // "SVN-0004", shared with macOS
    std::string remediation() const;  // one human sentence, zh-CN
    ErrorSeverity severity() const;

    // "[SVN-0004] … (E155004)\n<remediation>" — same shape as errorDescription.
    std::string Display() const;
};

// Resolve strategies. `working` keeps whatever is on disk; the other three
// discard either local or incoming edits and are therefore destructive.
enum class ResolveStrategy { working, mine_full, theirs_full, base };

bool IsDestructive(ResolveStrategy strategy);
std::string_view ToToken(ResolveStrategy strategy);  // --accept=<token>

// ---------------------------------------------------------------------------
// Progress (reported for every long-running operation)
// ---------------------------------------------------------------------------

struct TaskProgress {
    std::string operation;
    std::string detail;
    std::optional<double> fraction;
    std::optional<std::int64_t> bytes_done;
    std::optional<std::int64_t> bytes_total;
};

}  // namespace opensvn
