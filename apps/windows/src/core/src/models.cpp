#include "opensvn/models.hpp"

#include "opensvn/errors.hpp"
#include "opensvn/text.hpp"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <regex>
#include <sstream>

namespace opensvn {

namespace {

bool is_digit(char c) { return c >= '0' && c <= '9'; }

int read_int(std::string_view text, std::size_t position, std::size_t length) {
    int value = 0;
    for (std::size_t index = 0; index < length; ++index) {
        const char c = text[position + index];
        if (!is_digit(c)) return -1;
        value = value * 10 + (c - '0');
    }
    return value;
}

std::string normalize_separators(std::string_view path) {
    std::string result(path);
    std::replace(result.begin(), result.end(), '\\', '/');
    return result;
}

std::string without_trailing_separator(std::string path) {
    while (path.size() > 1 && (path.back() == '/' || path.back() == '\\')) path.pop_back();
    return path;
}

bool has_path_prefix(const std::string& path, const std::string& prefix) {
    return path.size() > prefix.size() && path.compare(0, prefix.size(), prefix) == 0;
}

int compare_paths(const std::string& lhs, const std::string& rhs) {
    // Case-insensitive first, ordinal second: "A.txt" and "a.txt" must still
    // have a deterministic order on a case-preserving volume.
    const int folded = _stricmp(lhs.c_str(), rhs.c_str());
    return folded != 0 ? folded : lhs.compare(rhs);
}

std::optional<Timestamp> parse_offset(std::string_view text) {
    return parse_svn_date(text);
}

} // namespace

std::optional<Timestamp> parse_svn_date(std::string_view raw) {
    const std::string text = text::trim(raw);
    if (text.size() < 19) return std::nullopt;
    if (text[4] != '-' || text[7] != '-' || (text[10] != 'T' && text[10] != ' ')) {
        return std::nullopt;
    }
    if (text[13] != ':' || text[16] != ':') return std::nullopt;

    const int year = read_int(text, 0, 4);
    const int month = read_int(text, 5, 2);
    const int day = read_int(text, 8, 2);
    const int hour = read_int(text, 11, 2);
    const int minute = read_int(text, 14, 2);
    const int second = read_int(text, 17, 2);
    if (year < 0 || month < 0 || day < 0 || hour < 0 || minute < 0 || second < 0) {
        return std::nullopt;
    }

    std::size_t position = 19;
    std::int64_t fraction_ns = 0;
    if (position < text.size() && text[position] == '.') {
        ++position;
        std::int64_t scale = 100'000'000;
        while (position < text.size() && is_digit(text[position])) {
            fraction_ns += (text[position] - '0') * scale;
            scale /= 10;
            ++position;
        }
    }

    int offset_seconds = 0;
    if (position < text.size()) {
        const char zone = text[position];
        if (zone == 'Z' || zone == 'z') {
            ++position;
        } else if (zone == '+' || zone == '-') {
            if (position + 5 >= text.size()) return std::nullopt;
            const int offset_hours = read_int(text, position + 1, 2);
            const int offset_minutes = read_int(text, position + 4, 2);
            if (offset_hours < 0 || offset_minutes < 0) return std::nullopt;
            offset_seconds = (offset_hours * 60 + offset_minutes) * 60;
            if (zone == '-') offset_seconds = -offset_seconds;
            position += 6;
        }
        if (position < text.size() && text[position] != ' ') {
            // Trailing garbage means this is not the timestamp shape we know.
            return std::nullopt;
        }
    }

    const std::chrono::year_month_day date{
        std::chrono::year{year}, std::chrono::month{static_cast<unsigned>(month)},
        std::chrono::day{static_cast<unsigned>(day)}};
    if (!date.ok()) return std::nullopt;

    using namespace std::chrono;
    const auto point = sys_days{date} + hours{hour} + minutes{minute} + seconds{second} +
                       nanoseconds{fraction_ns} - seconds{offset_seconds};
    return std::chrono::time_point_cast<Timestamp::duration>(point);
}

std::string format_iso8601(Timestamp value) {
    using namespace std::chrono;
    const auto millis = duration_cast<milliseconds>(value.time_since_epoch());
    std::int64_t seconds_part = millis.count() / 1000;
    std::int64_t millis_part = millis.count() % 1000;
    if (millis_part < 0) {
        millis_part += 1000;
        --seconds_part;
    }
    const std::time_t raw = static_cast<std::time_t>(seconds_part);
    std::tm utc{};
    gmtime_s(&utc, &raw);
    char buffer[40]{};
    std::snprintf(buffer, sizeof(buffer), "%04d-%02d-%02dT%02d:%02d:%02d.%03lldZ",
                  utc.tm_year + 1900, utc.tm_mon + 1, utc.tm_mday, utc.tm_hour, utc.tm_min,
                  utc.tm_sec, static_cast<long long>(millis_part));
    return buffer;
}

WCItemStatus::WCItemStatus(std::string raw) : raw_(std::move(raw)) {
    const std::string& value = raw_;
    if (value == "added") kind_ = Kind::added;
    else if (value == "conflicted") kind_ = Kind::conflicted;
    else if (value == "deleted") kind_ = Kind::deleted;
    else if (value == "external") kind_ = Kind::external;
    else if (value == "ignored") kind_ = Kind::ignored;
    else if (value == "incomplete") kind_ = Kind::incomplete;
    else if (value == "invalid") kind_ = Kind::invalid;
    else if (value == "merged") kind_ = Kind::merged;
    else if (value == "missing") kind_ = Kind::missing;
    else if (value == "modified") kind_ = Kind::modified;
    else if (value == "none") kind_ = Kind::none;
    else if (value == "normal") kind_ = Kind::normal;
    else if (value == "obstructed") kind_ = Kind::obstructed;
    else if (value == "replaced") kind_ = Kind::replaced;
    else if (value == "unversioned") kind_ = Kind::unversioned;
    else kind_ = Kind::unknown;
}

bool WCItemStatus::is_committable_change() const {
    switch (kind_) {
    case Kind::added:
    case Kind::deleted:
    case Kind::modified:
    case Kind::replaced:
    case Kind::merged:
        return true;
    default:
        return false;
    }
}

bool WCItemStatus::is_blocking() const {
    switch (kind_) {
    case Kind::conflicted:
    case Kind::obstructed:
    case Kind::incomplete:
    case Kind::missing:
        return true;
    default:
        return false;
    }
}

std::vector<std::string> conflict_codes(ConflictFlags flags) {
    std::vector<std::string> codes;
    if (has_flag(flags, ConflictFlags::text)) codes.emplace_back("text");
    if (has_flag(flags, ConflictFlags::property)) codes.emplace_back("property");
    if (has_flag(flags, ConflictFlags::tree)) codes.emplace_back("tree");
    return codes;
}

std::string_view to_string(StatusCategory category) {
    switch (category) {
    case StatusCategory::conflicted: return "conflicted";
    case StatusCategory::modified: return "modified";
    case StatusCategory::added: return "added";
    case StatusCategory::deleted: return "deleted";
    case StatusCategory::unversioned: return "unversioned";
    case StatusCategory::ignored: return "ignored";
    case StatusCategory::normal: return "normal";
    case StatusCategory::other: return "other";
    }
    return "other";
}

std::optional<RepositoryLock> StatusEntry::effective_lock() const {
    if (repository_lock) return repository_lock;
    return remote_lock;
}

std::string StatusEntry::file_name() const {
    const std::size_t position = path.find_last_of("/\\");
    return position == std::string::npos ? path : path.substr(position + 1);
}

StatusCategory StatusEntry::category() const {
    if (has_conflicts()) return StatusCategory::conflicted;
    switch (item.kind()) {
    case WCItemStatus::Kind::added:
    case WCItemStatus::Kind::replaced:
        return StatusCategory::added;
    case WCItemStatus::Kind::deleted:
    case WCItemStatus::Kind::missing:
        return StatusCategory::deleted;
    case WCItemStatus::Kind::modified:
    case WCItemStatus::Kind::merged:
        return StatusCategory::modified;
    case WCItemStatus::Kind::unversioned:
        return StatusCategory::unversioned;
    case WCItemStatus::Kind::ignored:
    case WCItemStatus::Kind::external:
        return StatusCategory::ignored;
    case WCItemStatus::Kind::normal:
    case WCItemStatus::Kind::none:
        return properties.is(WCItemStatus::Kind::modified) ? StatusCategory::modified
                                                           : StatusCategory::normal;
    default:
        return StatusCategory::other;
    }
}

std::vector<StatusEntry> StatusSnapshot::conflicted() const {
    std::vector<StatusEntry> result;
    for (const auto& entry : entries) {
        if (entry.has_conflicts()) result.push_back(entry);
    }
    return result;
}

std::vector<StatusEntry> StatusSnapshot::changed() const {
    std::vector<StatusEntry> result;
    for (const auto& entry : entries) {
        if (entry.item.is_committable_change() ||
            entry.properties.is(WCItemStatus::Kind::modified)) {
            result.push_back(entry);
        }
    }
    return result;
}

std::vector<StatusEntry> StatusSnapshot::unversioned() const {
    std::vector<StatusEntry> result;
    for (const auto& entry : entries) {
        if (entry.item.is(WCItemStatus::Kind::unversioned)) result.push_back(entry);
    }
    return result;
}

std::vector<StatusEntry> StatusSnapshot::missing() const {
    std::vector<StatusEntry> result;
    for (const auto& entry : entries) {
        if (entry.item.is(WCItemStatus::Kind::missing)) result.push_back(entry);
    }
    return result;
}

ChangedPath::Action parse_changed_path_action(std::string_view token) {
    if (token == "A") return ChangedPath::Action::added;
    if (token == "D") return ChangedPath::Action::deleted;
    if (token == "M") return ChangedPath::Action::modified;
    if (token == "R") return ChangedPath::Action::replaced;
    return ChangedPath::Action::unknown;
}

std::string_view to_string(ChangedPath::Action action) {
    switch (action) {
    case ChangedPath::Action::added: return "A";
    case ChangedPath::Action::deleted: return "D";
    case ChangedPath::Action::modified: return "M";
    case ChangedPath::Action::replaced: return "R";
    case ChangedPath::Action::unknown: return "?";
    }
    return "?";
}

std::optional<std::int64_t> LogPage::oldest_revision() const {
    if (entries.empty()) return std::nullopt;
    std::int64_t value = entries.front().revision;
    for (const auto& entry : entries) value = std::min(value, entry.revision);
    return value;
}

std::optional<std::int64_t> LogPage::newest_revision() const {
    if (entries.empty()) return std::nullopt;
    std::int64_t value = entries.front().revision;
    for (const auto& entry : entries) value = std::max(value, entry.revision);
    return value;
}

NodeKind parse_node_kind(std::string_view token) {
    if (token == "file") return NodeKind::file;
    if (token == "dir") return NodeKind::dir;
    if (token == "none") return NodeKind::none;
    return NodeKind::unknown;
}

std::string_view to_string(NodeKind kind) {
    switch (kind) {
    case NodeKind::file: return "file";
    case NodeKind::dir: return "dir";
    case NodeKind::none: return "none";
    case NodeKind::unknown: return "unknown";
    }
    return "unknown";
}

std::optional<std::string> RepositoryInfo::host() const {
    static const std::regex scheme(R"(^([a-zA-Z][a-zA-Z0-9+.\-]*)://([^/?\#]*))");
    std::smatch match;
    if (!std::regex_search(url, match, scheme)) return std::nullopt;
    std::string authority = match[2].str();
    if (authority.empty()) return std::nullopt;
    const std::size_t at = authority.rfind('@');
    if (at != std::string::npos) authority = authority.substr(at + 1);
    if (!authority.empty() && authority.front() == '[') {
        const std::size_t close = authority.find(']');
        if (close != std::string::npos) return authority.substr(0, close + 1);
    }
    const std::size_t colon = authority.find(':');
    if (colon != std::string::npos) authority = authority.substr(0, colon);
    if (authority.empty()) return std::nullopt;
    return authority;
}

bool SVNProperty::is_reserved() const {
    return name.rfind("svn:entry:", 0) == 0 || name.rfind("svn:wc:", 0) == 0;
}

std::vector<std::string> SVNProperty::ignore_entries() const {
    std::vector<std::string> result;
    for (const auto& line : text::split_lines(value)) {
        const std::string trimmed = text::trim(line);
        if (!trimmed.empty()) result.push_back(trimmed);
    }
    return result;
}

std::optional<std::string> PropertyTarget::value_of(std::string_view name) const {
    for (const auto& property : properties) {
        if (property.name == name) return property.value;
    }
    return std::nullopt;
}

void SVNPropertyName::validate(std::string_view name) {
    const std::string trimmed = text::trim(name);
    if (trimmed.empty()) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "属性名不能为空");
    }
    if (trimmed != name) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "属性名不能以空白开头或结尾");
    }
    if (trimmed.front() == '-') {
        throw_svn_error(SVNErrorCode::invalid_invocation,
                        "属性名不能以短横线开头：" + std::string(name));
    }
    for (const char c : name) {
        const bool allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                             (c >= '0' && c <= '9') || c == ':' || c == '.' || c == '_' ||
                             c == '-';
        if (!allowed) {
            throw_svn_error(SVNErrorCode::invalid_invocation,
                            "属性名只能包含字母、数字、冒号、点、下划线和短横线：" +
                                std::string(name));
        }
    }
    if (name.rfind("svn:entry:", 0) == 0 || name.rfind("svn:wc:", 0) == 0) {
        throw_svn_error(SVNErrorCode::invalid_invocation,
                        "「" + std::string(name) + "」是 Subversion 内部使用的属性，不能手动设置");
    }
    if (name.find(':') == std::string_view::npos) {
        throw_svn_error(SVNErrorCode::invalid_invocation,
                        "自定义属性必须带命名空间，例如 custom:" + std::string(name));
    }
}

std::string IgnoreList::pattern(std::string_view name) {
    std::string result;
    result.reserve(name.size());
    for (const char c : name) {
        switch (c) {
        case '*': result += "[*]"; break;
        case '?': result += "[?]"; break;
        case '[': result += "[[]"; break;
        case ']': result += "[]]"; break;
        default: result.push_back(c); break;
        }
    }
    return result;
}

std::vector<std::string> IgnoreList::entries(const std::optional<std::string>& value) {
    if (!value) return {};
    std::vector<std::string> result;
    for (const auto& line : text::split_lines(*value)) {
        const std::string trimmed = text::trim(line);
        if (!trimmed.empty()) result.push_back(trimmed);
    }
    return result;
}

std::optional<std::string> IgnoreList::adding(std::string_view name,
                                              const std::optional<std::string>& value) {
    const std::string escaped = pattern(name);
    std::vector<std::string> existing = entries(value);
    if (std::find(existing.begin(), existing.end(), std::string(name)) != existing.end() ||
        std::find(existing.begin(), existing.end(), escaped) != existing.end()) {
        return std::nullopt;
    }
    existing.push_back(escaped);
    std::string joined;
    for (std::size_t index = 0; index < existing.size(); ++index) {
        if (index != 0) joined.push_back('\n');
        joined += existing[index];
    }
    return joined;
}

bool RemoteChange::is_property_only() const {
    return item.kind() != WCItemStatus::Kind::modified &&
           item.kind() != WCItemStatus::Kind::added &&
           item.kind() != WCItemStatus::Kind::deleted &&
           properties.is(WCItemStatus::Kind::modified);
}

bool RemoteChange::conflicts_with_local() const {
    switch (item.kind()) {
    case WCItemStatus::Kind::modified:
        switch (local_item.kind()) {
        case WCItemStatus::Kind::modified:
        case WCItemStatus::Kind::conflicted:
        case WCItemStatus::Kind::added:
        case WCItemStatus::Kind::replaced:
        case WCItemStatus::Kind::missing:
        case WCItemStatus::Kind::deleted:
            return true;
        default:
            return local_properties.is(WCItemStatus::Kind::modified);
        }
    case WCItemStatus::Kind::deleted:
        switch (local_item.kind()) {
        case WCItemStatus::Kind::modified:
        case WCItemStatus::Kind::conflicted:
        case WCItemStatus::Kind::added:
        case WCItemStatus::Kind::replaced:
            return true;
        default:
            return false;
        }
    case WCItemStatus::Kind::added:
        switch (local_item.kind()) {
        case WCItemStatus::Kind::unversioned:
        case WCItemStatus::Kind::added:
        case WCItemStatus::Kind::modified:
        case WCItemStatus::Kind::conflicted:
        case WCItemStatus::Kind::obstructed:
        case WCItemStatus::Kind::replaced:
            return true;
        default:
            return false;
        }
    default:
        return properties.is(WCItemStatus::Kind::modified) &&
               local_properties.is(WCItemStatus::Kind::modified);
    }
}

int RemotePreview::added_count() const {
    return static_cast<int>(std::count_if(changes.begin(), changes.end(), [](const auto& change) {
        return change.item.is(WCItemStatus::Kind::added);
    }));
}

int RemotePreview::modified_count() const {
    return static_cast<int>(std::count_if(changes.begin(), changes.end(), [](const auto& change) {
        return change.item.is(WCItemStatus::Kind::modified) || change.is_property_only();
    }));
}

int RemotePreview::deleted_count() const {
    return static_cast<int>(std::count_if(changes.begin(), changes.end(), [](const auto& change) {
        return change.item.is(WCItemStatus::Kind::deleted);
    }));
}

std::vector<RemoteChange> RemotePreview::conflict_risks() const {
    std::vector<RemoteChange> result;
    for (const auto& change : changes) {
        if (change.conflicts_with_local()) result.push_back(change);
    }
    return result;
}

RemotePreview RemotePreview::make(const StatusSnapshot& snapshot) {
    std::optional<std::string> root;
    if (snapshot.target && !snapshot.target->empty()) {
        root = without_trailing_separator(*snapshot.target);
    }

    std::vector<RemoteChange> changes;
    std::optional<RemoteChange> root_property_change;

    for (const auto& entry : snapshot.entries) {
        const bool has_remote_item = entry.remote_item.has_value();
        const WCItemStatus remote_properties =
            entry.remote_properties.value_or(WCItemStatus::none());
        if (!has_remote_item && !remote_properties.is(WCItemStatus::Kind::modified)) continue;

        const WCItemStatus item = entry.remote_item.value_or(WCItemStatus::none());
        const bool unchanged_item =
            item.is(WCItemStatus::Kind::none) || item.is(WCItemStatus::Kind::normal);
        if (unchanged_item && !remote_properties.is(WCItemStatus::Kind::modified)) continue;

        RemoteChange change{entry.path,
                            item,
                            remote_properties,
                            entry.item,
                            entry.properties};

        const std::string normalized_entry = without_trailing_separator(entry.path);
        const bool is_root = entry.path.empty() || entry.path == "." || entry.path == "./" ||
                             (root && normalized_entry == *root);
        if (is_root) {
            if (unchanged_item) root_property_change = std::move(change);
            continue;
        }
        changes.push_back(std::move(change));
    }

    std::sort(changes.begin(), changes.end(), [](const auto& lhs, const auto& rhs) {
        return compare_paths(lhs.path, rhs.path) < 0;
    });

    std::vector<std::string> paths;
    paths.reserve(changes.size());
    for (const auto& change : changes) paths.push_back(without_trailing_separator(change.path));
    changes.erase(std::remove_if(changes.begin(), changes.end(),
                                 [&](const RemoteChange& change) {
                                     if (!change.item.is(WCItemStatus::Kind::modified) ||
                                         change.properties.is(WCItemStatus::Kind::modified)) {
                                         return false;
                                     }
                                     const std::string prefix =
                                         without_trailing_separator(change.path) + "/";
                                     for (const auto& candidate : paths) {
                                         if (candidate != without_trailing_separator(change.path) &&
                                             has_path_prefix(candidate, prefix)) {
                                             return true;
                                         }
                                     }
                                     return false;
                                 }),
                  changes.end());

    return RemotePreview{std::move(changes), std::move(root_property_change),
                         snapshot.working_copy_revision, snapshot.server_revision};
}

std::optional<RepositoryLock> LockSnapshot::lock_for(std::string_view path) const {
    const std::string normalized = normalize_separators(path);
    const std::string trimmed = without_trailing_separator(normalized);

    auto exact = locks.find(std::string(path));
    if (exact != locks.end()) return exact->second;

    for (const auto& [key, lock] : locks) {
        const std::string normalized_key = without_trailing_separator(normalize_separators(key));
        if (normalized_key == trimmed) return lock;
        const std::string suffix = "/" + trimmed;
        const std::string key_suffix = "/" + normalized_key;
        if (normalized_key.size() > suffix.size() &&
            normalized_key.compare(normalized_key.size() - suffix.size(), suffix.size(), suffix) == 0) {
            return lock;
        }
        if (trimmed.size() > key_suffix.size() &&
            trimmed.compare(trimmed.size() - key_suffix.size(), key_suffix.size(), key_suffix) == 0) {
            return lock;
        }
    }
    return std::nullopt;
}

bool LockSnapshot::is_own_lock(std::string_view path) const {
    const std::string normalized = without_trailing_separator(normalize_separators(path));
    for (const auto& own : own_paths) {
        const std::string candidate = without_trailing_separator(normalize_separators(own));
        if (candidate == normalized) return true;
        if (candidate.size() < normalized.size() &&
            normalized.compare(normalized.size() - candidate.size() - 1, candidate.size() + 1,
                               "/" + candidate) == 0) {
            return true;
        }
        if (normalized.size() < candidate.size() &&
            candidate.compare(candidate.size() - normalized.size() - 1, normalized.size() + 1,
                              "/" + normalized) == 0) {
            return true;
        }
    }
    return false;
}

std::vector<std::string> LockSnapshot::foreign_locks(
    const std::vector<std::string>& candidates) const {
    std::vector<std::string> result;
    for (const auto& path : candidates) {
        if (lock_for(path) && !is_own_lock(path)) result.push_back(path);
    }
    return result;
}

LockSnapshot LockSnapshot::from(const StatusSnapshot& status) {
    LockSnapshot snapshot;
    for (const auto& entry : status.entries) {
        if (entry.repository_lock) {
            snapshot.locks[entry.path] = *entry.repository_lock;
            snapshot.own_paths.insert(entry.path);
        } else if (entry.remote_lock) {
            snapshot.locks[entry.path] = *entry.remote_lock;
        }
    }
    return snapshot;
}

std::vector<std::string> LockOutputParser::locked_paths(std::string_view stdout_text) {
    static const std::regex expression(R"(^'(.+)' locked by user '[^']*'\.?$)");
    std::vector<std::string> result;
    for (const auto& line : text::split_lines(stdout_text)) {
        std::smatch match;
        if (std::regex_match(line, match, expression)) result.push_back(match[1].str());
    }
    return result;
}

std::vector<std::string> LockOutputParser::unlocked_paths(std::string_view stdout_text) {
    static const std::regex expression(R"(^'(.+)' unlocked\.?$)");
    std::vector<std::string> result;
    for (const auto& line : text::split_lines(stdout_text)) {
        std::smatch match;
        if (std::regex_match(line, match, expression)) result.push_back(match[1].str());
    }
    return result;
}

std::optional<std::string> LockOutputParser::owner(std::string_view stdout_text) {
    static const std::regex expression(R"(locked by user '([^']*)')");
    std::optional<std::string> result;
    const std::string input(stdout_text);
    for (std::sregex_iterator it(input.begin(), input.end(), expression), end; it != end; ++it) {
        result = (*it)[1].str();
    }
    return result;
}

std::string_view to_string(ResolveStrategy strategy) {
    switch (strategy) {
    case ResolveStrategy::working: return "working";
    case ResolveStrategy::mine_full: return "mine-full";
    case ResolveStrategy::theirs_full: return "theirs-full";
    case ResolveStrategy::base: return "base";
    }
    return "working";
}

bool is_destructive(ResolveStrategy strategy) {
    return strategy != ResolveStrategy::working;
}

std::string_view resolve_title(ResolveStrategy strategy) {
    switch (strategy) {
    case ResolveStrategy::working: return "保留当前内容，仅清除冲突标记";
    case ResolveStrategy::mine_full: return "用我的版本覆盖（丢弃服务器改动）";
    case ResolveStrategy::theirs_full: return "用服务器版本覆盖（丢弃我的改动）";
    case ResolveStrategy::base: return "恢复基线版本（丢弃双方改动）";
    }
    return "";
}

std::string_view resolve_consequence(ResolveStrategy strategy) {
    switch (strategy) {
    case ResolveStrategy::working:
        return "保留磁盘上的当前内容（可能仍含冲突标记），仅清除冲突状态。";
    case ResolveStrategy::mine_full:
        return "丢弃服务器带来的修改，只保留本地版本。此操作不可撤销。";
    case ResolveStrategy::theirs_full:
        return "丢弃全部本地修改，改用服务器版本。此操作不可撤销。";
    case ResolveStrategy::base:
        return "还原到冲突前的基线版本，本地与该次服务器修改都会被丢弃。";
    }
    return "";
}

std::vector<std::string> ResolveOutcome::paths_with_residual_markers() const {
    std::vector<std::string> result;
    for (const auto& scan : scans) {
        if (!scan.skipped && !scan.marker_lines.empty()) result.push_back(scan.path);
    }
    return result;
}

} // namespace opensvn
