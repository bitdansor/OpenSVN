#pragma once

#include <chrono>
#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace opensvn {

using Timestamp = std::chrono::system_clock::time_point;

/// Parses the timestamps SVN emits (`2026-10-18T04:28:11.123456Z`, UTC).
std::optional<Timestamp> parse_svn_date(std::string_view text);

/// `2026-10-18T04:28:11.123Z` — the contract's canonical form.
std::string format_iso8601(Timestamp value);

/// One `svn status` item token, preserving unknown values.
class WCItemStatus {
public:
    enum class Kind {
        added,
        conflicted,
        deleted,
        external,
        ignored,
        incomplete,
        invalid,
        merged,
        missing,
        modified,
        none,
        normal,
        obstructed,
        replaced,
        unversioned,
        unknown
    };

    WCItemStatus() = default;
    explicit WCItemStatus(std::string raw);

    static WCItemStatus from_raw(std::string raw) { return WCItemStatus(std::move(raw)); }
    static constexpr WCItemStatus none() { return WCItemStatus("none", Kind::none); }
    static constexpr WCItemStatus normal() { return WCItemStatus("normal", Kind::normal); }
    static constexpr WCItemStatus modified() { return WCItemStatus("modified", Kind::modified); }
    static constexpr WCItemStatus unversioned() { return WCItemStatus("unversioned", Kind::unversioned); }

    Kind kind() const { return kind_; }
    const std::string& raw() const { return raw_; }
    bool is(Kind kind) const { return kind_ == kind; }
    bool is_unknown() const { return kind_ == Kind::unknown; }

    bool is_committable_change() const;
    bool is_blocking() const;

    friend bool operator==(const WCItemStatus& lhs, const WCItemStatus& rhs) {
        return lhs.raw_ == rhs.raw_;
    }
    friend bool operator!=(const WCItemStatus& lhs, const WCItemStatus& rhs) { return !(lhs == rhs); }

private:
    constexpr WCItemStatus(std::string_view raw, Kind kind) : raw_(raw), kind_(kind) {}
    std::string raw_ = "none";
    Kind kind_ = Kind::none;
};

enum class ConflictFlags : std::uint8_t {
    none = 0,
    text = 1 << 0,
    property = 1 << 1,
    tree = 1 << 2,
    all = text | property | tree,
};

constexpr ConflictFlags operator|(ConflictFlags lhs, ConflictFlags rhs) {
    return static_cast<ConflictFlags>(static_cast<std::uint8_t>(lhs) |
                                       static_cast<std::uint8_t>(rhs));
}
constexpr ConflictFlags operator&(ConflictFlags lhs, ConflictFlags rhs) {
    return static_cast<ConflictFlags>(static_cast<std::uint8_t>(lhs) &
                                       static_cast<std::uint8_t>(rhs));
}
constexpr bool has_flag(ConflictFlags value, ConflictFlags flag) {
    return (static_cast<std::uint8_t>(value) & static_cast<std::uint8_t>(flag)) != 0;
}
/// `["text", "property", "tree"]` subset, in the contract's stable order.
std::vector<std::string> conflict_codes(ConflictFlags flags);

/// A repository-side lock, which is not the same thing as an internal
/// working-copy lock.
struct RepositoryLock {
    std::optional<std::string> token;
    std::optional<std::string> owner;
    std::optional<std::string> comment;
    std::optional<Timestamp> created_at;

    bool operator==(const RepositoryLock&) const = default;
};

struct CommitInfo {
    std::int64_t revision = 0;
    std::optional<std::string> author;
    std::optional<Timestamp> date;

    bool operator==(const CommitInfo&) const = default;
};

enum class StatusCategory {
    conflicted,
    modified,
    added,
    deleted,
    unversioned,
    ignored,
    normal,
    other,
};

std::string_view to_string(StatusCategory category);

/// One entry of `svn status --xml`.
struct StatusEntry {
    std::string path;
    WCItemStatus item;
    WCItemStatus properties = WCItemStatus::none();
    std::optional<std::int64_t> revision;
    bool is_copied = false;
    ConflictFlags conflicts = ConflictFlags::none;
    std::optional<RepositoryLock> repository_lock;
    std::optional<RepositoryLock> remote_lock;
    std::optional<WCItemStatus> remote_item;
    std::optional<WCItemStatus> remote_properties;
    bool is_working_copy_locked = false;
    std::optional<std::string> changelist;
    std::optional<CommitInfo> commit;
    std::optional<std::string> depth;

    bool has_conflicts() const { return conflicts != ConflictFlags::none; }
    std::optional<RepositoryLock> effective_lock() const;
    std::string file_name() const;
    StatusCategory category() const;

    bool operator==(const StatusEntry&) const = default;
};

struct StatusSnapshot {
    std::optional<std::string> target;
    std::vector<StatusEntry> entries;
    std::optional<std::int64_t> working_copy_revision;
    std::optional<std::int64_t> server_revision;

    std::vector<StatusEntry> conflicted() const;
    std::vector<StatusEntry> changed() const;
    std::vector<StatusEntry> unversioned() const;
    std::vector<StatusEntry> missing() const;
    bool empty() const { return entries.empty(); }
};

struct ChangedPath {
    enum class Action { added, deleted, modified, replaced, unknown };

    std::string path;
    Action action = Action::unknown;
    std::optional<std::string> kind;
    std::optional<std::string> copy_from_path;
    std::optional<std::int64_t> copy_from_revision;

    bool operator==(const ChangedPath&) const = default;
};

ChangedPath::Action parse_changed_path_action(std::string_view token);
std::string_view to_string(ChangedPath::Action action);

struct LogEntry {
    std::int64_t revision = 0;
    std::optional<std::string> author;
    std::optional<Timestamp> date;
    std::string message;
    std::vector<ChangedPath> changed_paths;

    bool operator==(const LogEntry&) const = default;
};

struct LogPage {
    std::vector<LogEntry> entries;
    std::optional<std::string> target;
    int limit = 50;
    bool has_more = false;

    std::optional<std::int64_t> oldest_revision() const;
    std::optional<std::int64_t> newest_revision() const;
};

enum class NodeKind { file, dir, none, unknown };

NodeKind parse_node_kind(std::string_view token);
std::string_view to_string(NodeKind kind);

struct RepositoryInfo {
    std::string path;
    std::string url;
    std::optional<std::string> repository_root;
    std::optional<std::string> repository_uuid;
    std::optional<std::int64_t> revision;
    NodeKind kind = NodeKind::none;
    std::optional<std::string> schedule;
    std::optional<std::string> depth;
    std::optional<std::string> working_copy_root;
    std::optional<std::int64_t> last_changed_revision;
    std::optional<std::string> last_changed_author;
    std::optional<Timestamp> last_changed_date;
    std::optional<RepositoryLock> repository_lock;
    std::optional<std::string> conflict_operation;
    std::optional<std::string> conflict_type;

    std::optional<std::string> host() const;

    bool operator==(const RepositoryInfo&) const = default;
};

struct InfoReport {
    std::vector<RepositoryInfo> entries;

    const RepositoryInfo* primary() const { return entries.empty() ? nullptr : &entries.front(); }
};

/// One versioned property on a path.
struct SVNProperty {
    std::string name;
    std::string value;
    /// Present when svn encoded the value (for example `base64`); such a value
    /// is not text and must not be written back as if it were.
    std::optional<std::string> encoding;

    bool is_reserved() const;
    bool is_ignore_list() const { return name == "svn:ignore"; }
    bool is_encoded() const { return encoding && !encoding->empty(); }
    std::vector<std::string> ignore_entries() const;
};

struct PropertyTarget {
    std::string path;
    std::vector<SVNProperty> properties;

    std::optional<std::string> value_of(std::string_view name) const;
};

/// Validation and formatting for property names.
class SVNPropertyName {
public:
    /// Throws `SVNException(invalid_invocation)` naming the broken rule.
    static void validate(std::string_view name);
};

struct IgnoreOutcome {
    std::vector<std::string> added;
    std::vector<std::string> already;

    bool changed_anything() const { return !added.empty(); }
};

class IgnoreList {
public:
    static std::string pattern(std::string_view name);
    static std::vector<std::string> entries(const std::optional<std::string>& value);
    /// Returns the new value, or nullopt when the name is already covered.
    static std::optional<std::string> adding(std::string_view name,
                                             const std::optional<std::string>& value);
};

/// One path the server changed since this working copy's base revision.
struct RemoteChange {
    std::string path;
    WCItemStatus item;
    WCItemStatus properties = WCItemStatus::none();
    WCItemStatus local_item = WCItemStatus::normal();
    WCItemStatus local_properties = WCItemStatus::none();

    bool is_property_only() const;
    bool conflicts_with_local() const;

    bool operator==(const RemoteChange&) const = default;
};

struct RemotePreview {
    std::vector<RemoteChange> changes;
    std::optional<RemoteChange> root_property_change;
    std::optional<std::int64_t> working_copy_revision;
    std::optional<std::int64_t> server_revision;

    bool empty() const { return changes.empty() && !root_property_change; }
    int added_count() const;
    int modified_count() const;
    int deleted_count() const;
    std::vector<RemoteChange> conflict_risks() const;
    bool has_conflicts_with_local() const { return !conflict_risks().empty(); }

    static RemotePreview make(const StatusSnapshot& snapshot);
};

struct OperationPreview {
    enum class Risk { low, medium, high };

    std::string summary;
    std::string detail;
    Risk risk = Risk::low;
    std::vector<std::string> affected_paths;
    std::vector<std::string> discarded_paths;
};

struct UpdateSummary {
    std::string target;
    std::optional<std::int64_t> from_revision;
    std::optional<std::int64_t> to_revision;
    std::vector<std::string> updated_paths;
    std::vector<std::string> added_paths;
    std::vector<std::string> merged_paths;
    std::vector<std::string> conflicted_paths;
    std::vector<std::string> removed_paths;
    bool conflicts_verified = true;
    std::string raw_output;
};

struct CommitSummary {
    std::optional<std::int64_t> revision;
    std::vector<std::string> committed_paths;
    std::string raw_output;
};

struct DiffResult {
    std::string text;
    bool is_truncated = false;
    std::size_t byte_count = 0;

    bool empty() const { return text.empty(); }
};

struct LockOutcome {
    std::vector<std::string> locked_paths;
    std::optional<std::string> owner;
    std::string raw_output;
};

struct UnlockOutcome {
    std::vector<std::string> unlocked_paths;
    std::string raw_output;
};

struct LockSnapshot {
    std::map<std::string, RepositoryLock> locks;
    std::set<std::string> own_paths;

    bool empty() const { return locks.empty(); }
    std::size_t count() const { return locks.size(); }
    std::optional<RepositoryLock> lock_for(std::string_view path) const;
    bool is_own_lock(std::string_view path) const;
    std::vector<std::string> foreign_locks(const std::vector<std::string>& candidates) const;

    static LockSnapshot from(const StatusSnapshot& status);
};

/// Parses the human-readable stdout of `svn lock` / `svn unlock`.
class LockOutputParser {
public:
    static std::vector<std::string> locked_paths(std::string_view stdout_text);
    static std::vector<std::string> unlocked_paths(std::string_view stdout_text);
    static std::optional<std::string> owner(std::string_view stdout_text);
};

/// How a conflict should be resolved. Mirrors `svn resolve --accept`.
enum class ResolveStrategy { working, mine_full, theirs_full, base };

std::string_view to_string(ResolveStrategy strategy);
bool is_destructive(ResolveStrategy strategy);
std::string_view resolve_title(ResolveStrategy strategy);
std::string_view resolve_consequence(ResolveStrategy strategy);

struct ConflictBackup {
    std::string directory;
    std::vector<std::string> files;
};

struct ConflictMarkerScan {
    std::string path;
    std::vector<std::size_t> marker_lines;
    bool skipped = false;
    std::string skip_reason;
};

struct ResolveOutcome {
    std::vector<std::string> resolved_paths;
    std::optional<ConflictBackup> backup;
    std::vector<ConflictMarkerScan> scans;

    std::vector<std::string> paths_with_residual_markers() const;
};

/// The three versions svn left behind for one text conflict.
struct ConflictArtifacts {
    std::string path;
    std::string operation;
    std::string type;
    std::optional<std::string> prev_base_file;
    std::optional<std::string> prev_wc_file;
    std::optional<std::string> cur_base_file;
    std::optional<std::string> source_left_path;
    std::optional<std::string> source_right_path;
    std::optional<std::int64_t> source_left_revision;
    std::optional<std::int64_t> source_right_revision;
};

} // namespace opensvn
