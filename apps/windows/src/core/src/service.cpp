#include "opensvn/service.hpp"

#include "opensvn/error_mapper.hpp"
#include "opensvn/errors.hpp"
#include "opensvn/output_parser.hpp"
#include "opensvn/parsing.hpp"
#include "opensvn/redaction.hpp"
#include "opensvn/text.hpp"

#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <unordered_map>

namespace opensvn {

namespace {

std::filesystem::path absolute_path(const std::filesystem::path& path) {
    std::error_code error_code;
    std::filesystem::path absolute = std::filesystem::absolute(path, error_code);
    if (error_code) return path.lexically_normal();
    return absolute.lexically_normal();
}

std::string path_text(const std::filesystem::path& path) {
    return text::path_to_utf8(path);
}

// svn parses the last `@` in a target as a peg revision. A literal filename
// such as `asset@2x.png` must be disambiguated with a trailing `@`.
std::string literal_target(std::string target) {
    if (target.find('@') != std::string::npos) target.push_back('@');
    return target;
}

std::vector<std::string> absolute_texts(
    const std::vector<std::filesystem::path>& paths) {
    std::vector<std::string> result;
    result.reserve(paths.size());
    for (const auto& path : paths) result.push_back(literal_target(path_text(absolute_path(path))));
    return result;
}

std::string join_names(const std::vector<std::filesystem::path>& paths,
                       std::string_view separator) {
    std::string result;
    for (std::size_t index = 0; index < paths.size(); ++index) {
        if (index != 0) result += separator;
        result += text::path_to_utf8(paths[index].filename());
    }
    return result;
}

bool is_valid_utf8(std::string_view text) {
    if (text.empty()) return true;
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                               static_cast<int>(text.size()), nullptr, 0) > 0;
}

std::string truncate_utf8(std::string_view text, std::size_t max_bytes) {
    if (text.size() <= max_bytes) return std::string(text);
    std::size_t position = max_bytes;
    // Do not cut a multi-byte code point in half: move back to its lead byte.
    while (position > 0 &&
           (static_cast<unsigned char>(text[position]) & 0xC0) == 0x80) {
        --position;
    }
    return std::string(text.substr(0, position));
}

std::string timestamp_directory_name(Timestamp now) {
    std::string stamp = format_iso8601(now);
    for (char& c : stamp) {
        if (c == ':' || c == '.') c = '-';
    }
    return stamp;
}

std::string hash_key(std::string_view text) {
    const std::size_t value = std::hash<std::string>{}(std::string(text));
    char buffer[32]{};
    std::snprintf(buffer, sizeof(buffer), "%016llx",
                  static_cast<unsigned long long>(value));
    return buffer;
}

std::string safe_reason(std::string reason) {
    for (char& c : reason) {
        if (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' ||
            c == '<' || c == '>' || c == '|') {
            c = '-';
        }
    }
    return reason;
}

bool remote_outcome_unknown(SVNErrorCode code) {
    switch (code) {
    case SVNErrorCode::timeout:
    case SVNErrorCode::cancelled:
    case SVNErrorCode::network_failure:
    case SVNErrorCode::command_failed:
    case SVNErrorCode::xml_parse_failure:
    case SVNErrorCode::unknown:
        return true;
    default:
        return false;
    }
}

bool has_prefix(std::string_view value, std::string_view prefix) {
    return value.size() >= prefix.size() && value.substr(0, prefix.size()) == prefix;
}

bool has_prefix(const std::string& value, const std::string& prefix) {
    return has_prefix(std::string_view(value), std::string_view(prefix));
}

/// Rejects empty paths and paths from different working copies, then returns
/// the serialization key the caller should hold while writing.
std::string require_same_working_copy(
    const std::vector<std::filesystem::path>& paths) {
    if (paths.empty()) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "没有选择路径");
    }
    for (const auto& path : paths) {
        if (path.empty()) {
            throw_svn_error(SVNErrorCode::invalid_invocation, "路径不能为空");
        }
    }
    const std::string key = WorkingCopyLocator::comparison_key(paths.front());
    for (const auto& path : paths) {
        if (WorkingCopyLocator::comparison_key(path) != key) {
            throw_svn_error(SVNErrorCode::invalid_invocation,
                            "一次操作只能针对同一个工作副本",
                            "「" + path_text(path) + "」与「" +
                                path_text(paths.front()) + "」不属于同一个工作副本。");
        }
    }
    return path_text(WorkingCopyLocator::serialization_key(paths.front()));
}

/// Property values travel through a temporary file, because svn reads the
/// value from -F and there is no safe argv encoding for arbitrary bytes. The
/// name is random and created with CREATE_NEW, so a planted file or symlink
/// cannot redirect the write.
class PropertyValueFile {
public:
    explicit PropertyValueFile(std::string_view content) {
        std::error_code error_code;
        const std::filesystem::path directory =
            std::filesystem::temp_directory_path(error_code);
        if (error_code) {
            throw_svn_error(SVNErrorCode::permission_denied,
                            "无法访问临时目录：" + error_code.message());
        }

        DWORD last_error = ERROR_FILE_EXISTS;
        for (int attempt = 0; attempt < 8 && handle_ == INVALID_HANDLE_VALUE; ++attempt) {
            path_ = directory /
                    text::path_from_utf8("opensvn-property-" + text::random_suffix());
            handle_ = CreateFileW(path_.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                                  FILE_ATTRIBUTE_TEMPORARY, nullptr);
            if (handle_ == INVALID_HANDLE_VALUE) last_error = GetLastError();
        }
        if (handle_ == INVALID_HANDLE_VALUE) {
            throw_svn_error(SVNErrorCode::permission_denied,
                            "无法创建临时文件来传递属性值（Windows 错误 " +
                                std::to_string(last_error) + "）");
        }

        try {
            std::string_view remaining = content;
            while (!remaining.empty()) {
                const DWORD chunk = static_cast<DWORD>(
                    std::min<std::size_t>(remaining.size(), 1u << 20));
                DWORD written = 0;
                if (!WriteFile(handle_, remaining.data(), chunk, &written, nullptr) ||
                    written == 0) {
                    const DWORD error = GetLastError();
                    remove();
                    throw_svn_error(SVNErrorCode::permission_denied,
                                    "无法写入临时文件来传递属性值（Windows 错误 " +
                                        std::to_string(error) + "）");
                }
                remaining.remove_prefix(written);
            }
        } catch (...) {
            remove();
            throw;
        }
        close();
    }

    ~PropertyValueFile() { remove(); }

    PropertyValueFile(const PropertyValueFile&) = delete;
    PropertyValueFile& operator=(const PropertyValueFile&) = delete;

    const std::filesystem::path& path() const { return path_; }

private:
    void close() noexcept {
        if (handle_ != INVALID_HANDLE_VALUE) {
            CloseHandle(handle_);
            handle_ = INVALID_HANDLE_VALUE;
        }
    }

    void remove() noexcept {
        close();
        if (!path_.empty()) DeleteFileW(path_.c_str());
    }

    std::filesystem::path path_;
    HANDLE handle_ = INVALID_HANDLE_VALUE;
};

} // namespace

std::string_view to_string(CheckoutDepth depth) {
    switch (depth) {
    case CheckoutDepth::infinity: return "infinity";
    case CheckoutDepth::immediates: return "immediates";
    case CheckoutDepth::files: return "files";
    case CheckoutDepth::empty: return "empty";
    }
    return "infinity";
}

SVNService::SVNService(SVNServiceConfiguration configuration)
    : installation_(std::move(configuration.installation)),
      credentials_(configuration.credentials ? configuration.credentials
                                             : std::make_shared<InMemoryCredentialStore>()),
      runner_(installation_.executable, configuration.environment, configuration.timeout),
      timeout_(configuration.timeout),
      conflict_backup_root_(configuration.conflict_backup_root.value_or(
          OperationJournal::default_directory() / "ConflictBackups")),
      journal_(std::move(configuration.journal)) {}

ProcessResult SVNService::invoke(const std::vector<std::string>& arguments,
                                 const std::vector<std::string>& positionals,
                                 const std::optional<std::filesystem::path>& working_directory,
                                 std::optional<SVNCredential> credential,
                                 const std::optional<std::string>& repository_url,
                                 const SVNProgressCallback* progress, std::stop_token stop,
                                 std::size_t maximum_captured_bytes) const {
    std::optional<CredentialScope> scope;
    if (repository_url) scope = CredentialScope::from_repository_url(*repository_url);

    std::optional<SVNCredential> effective = credential;
    if (!effective && scope) {
        try {
            effective = credentials_->credential(*scope);
        } catch (...) {
            effective.reset();
        }
    }

    std::vector<std::string> final_arguments = {"--non-interactive", "--no-auth-cache"};
    final_arguments.insert(final_arguments.end(), arguments.begin(), arguments.end());

    if (effective) {
        if (installation_.version < SVNVersion{1, 10, 0}) {
            throw_svn_error(SVNErrorCode::invalid_invocation,
                            "svn " + installation_.version.to_string() +
                                " 不支持从 stdin 读取密码，需要 1.10 或更高版本");
        }
        final_arguments.push_back("--username");
        final_arguments.push_back(effective->username);
        final_arguments.push_back("--password-from-stdin");
    }

    // Everything after "--" is an operand. Keeping positionals in a separate
    // list means option-looking values (including a message that is literally
    // "--") can never be mistaken for the separator.
    final_arguments.push_back("--");
    final_arguments.insert(final_arguments.end(), positionals.begin(), positionals.end());

    ProcessInvocation invocation;
    invocation.arguments = final_arguments;
    invocation.working_directory = working_directory;
    invocation.timeout = timeout_;
    invocation.maximum_captured_bytes = maximum_captured_bytes;
    if (effective) invocation.standard_input = effective->password + "\n";

    OutputLineCallback line_callback;
    if (progress) {
        line_callback = [progress](std::string_view line) { (*progress)(line); };
    }

    const ProcessResult result = runner_.run(invocation, stop, line_callback);

    if (result.was_cancelled) {
        throw_svn_error(SVNErrorCode::cancelled, "操作已取消",
                        LogRedactor::redact(result.standard_error), std::nullopt,
                        result.exit_code);
    }
    if (result.timed_out) {
        throw_svn_error(SVNErrorCode::timeout,
                        "操作超时（" +
                            std::to_string(timeout_.count() / 1000) + " 秒）",
                        LogRedactor::redact(result.standard_error), std::nullopt,
                        result.exit_code);
    }

    if (!result.success()) {
        const auto mapped = SVNErrorMapper::error_from(result);
        if (mapped && is_authentication_related(mapped->code)) {
            if (!credential && scope) {
                try {
                    credentials_->remove(*scope);
                } catch (...) {
                }
            }
            const std::string message =
                scope ? "需要登录 " + scope->host : std::string("需要登录");
            throw_svn_error(SVNErrorCode::authentication_required, message,
                            mapped->diagnostic_output, mapped->svn_code, result.exit_code);
        }
        if (mapped) throw SVNException(*mapped);
        throw_svn_error(SVNErrorCode::command_failed, "svn 执行失败",
                        LogRedactor::redact(result.standard_error), std::nullopt,
                        result.exit_code);
    }

    if (effective && scope) {
        try {
            credentials_->save(*effective, *scope);
        } catch (...) {
        }
    }
    return result;
}

std::optional<std::string> SVNService::repository_url_for(const std::string& path,
                                                          std::stop_token stop) const {
    if (path.find("://") != std::string::npos) return path;
    try {
        // `path` is a raw target here; info() applies the literal-@ escaping.
        const InfoReport report = info(path, std::nullopt, stop);
        if (report.primary()) return report.primary()->url;
    } catch (...) {
    }
    return std::nullopt;
}

std::optional<std::string> SVNService::begin_journal(OperationJournal::EntryKind kind,
                                                     const std::filesystem::path& working_copy,
                                                     const std::string& summary) const {
    if (!journal_) return std::nullopt;
    try {
        return journal_->begin(kind, working_copy, summary);
    } catch (...) {
        return std::nullopt;
    }
}

void SVNService::finish_journal(const std::optional<std::string>& ticket) const {
    if (!journal_ || !ticket) return;
    try {
        journal_->finish(ticket);
    } catch (...) {
    }
}

StatusSnapshot SVNService::status(const std::filesystem::path& target, bool include_ignored,
                                  bool check_repository,
                                  std::optional<SVNCredential> credential,
                                  std::stop_token stop) const {
    std::vector<std::string> args = {"status", "--xml"};
    if (include_ignored) args.push_back("--no-ignore");
    if (check_repository) args.push_back("--show-updates");
    const std::string target_text = literal_target(path_text(absolute_path(target)));
    const auto repository_url =
        check_repository
            ? repository_url_for(path_text(absolute_path(target)), stop)
            : std::nullopt;
    const ProcessResult result = invoke(args, {target_text}, std::nullopt,
                                        std::move(credential), repository_url, nullptr, stop);
    return parsing::parse_status(result.standard_output);
}

RemotePreview SVNService::remote_preview(const std::filesystem::path& target,
                                         std::optional<SVNCredential> credential,
                                         std::stop_token stop) const {
    return RemotePreview::make(status(target, false, true, std::move(credential), stop));
}

InfoReport SVNService::info(const std::string& target,
                            std::optional<SVNCredential> credential,
                            std::stop_token stop) const {
    const bool is_url = target.find("://") != std::string::npos;
    const std::string path =
        is_url ? target : literal_target(path_text(absolute_path(text::path_from_utf8(target))));
    const ProcessResult result = invoke({"info", "--xml"}, {path}, std::nullopt,
                                        std::move(credential),
                                        is_url ? std::optional<std::string>(target)
                                               : std::nullopt,
                                        nullptr, stop);
    return parsing::parse_info(result.standard_output);
}

LogPage SVNService::log(const std::string& target, int limit,
                        std::optional<std::int64_t> start_revision,
                        std::optional<std::int64_t> end_revision,
                        std::optional<SVNCredential> credential,
                        const SVNProgressCallback& progress, std::stop_token stop) const {
    const bool is_url = target.find("://") != std::string::npos;
    const std::string path =
        is_url ? target : literal_target(path_text(absolute_path(text::path_from_utf8(target))));
    std::vector<std::string> args = {"log", "--xml", "-v", "-l",
                                     std::to_string(std::max(1, limit))};
    if (start_revision && end_revision) {
        args.push_back("-r");
        args.push_back(std::to_string(*start_revision) + ":" +
                       std::to_string(*end_revision));
    } else if (start_revision) {
        args.push_back("-r");
        args.push_back(std::to_string(*start_revision) + ":1");
    } else if (end_revision) {
        args.push_back("-r");
        args.push_back(std::to_string(*end_revision) + ":1");
    }
    const auto repository_url =
        is_url ? std::optional<std::string>(target) : repository_url_for(path, stop);
    const ProcessResult result = invoke(args, {path}, std::nullopt, std::move(credential),
                                        repository_url,
                                        progress ? &progress : nullptr, stop);
    LogPage page;
    page.entries = parsing::parse_log(result.standard_output);
    page.target = target;
    page.limit = limit;
    page.has_more = static_cast<int>(page.entries.size()) >= limit;
    return page;
}

DiffResult SVNService::diff_working_copy(const std::filesystem::path& target,
                                         int context_lines, std::size_t max_bytes,
                                         std::stop_token stop) const {
    const std::size_t capture_limit = max_bytes == 0 ? 2'000'000 : max_bytes;
    const ProcessResult result = invoke(
        {"diff", "--internal-diff", "-x", "-U" + std::to_string(std::max(0, context_lines))},
        {literal_target(path_text(absolute_path(target)))}, std::nullopt, std::nullopt,
        std::nullopt, nullptr, stop, capture_limit);
    DiffResult diff;
    diff.byte_count = result.standard_output_bytes;
    const std::size_t display_limit = max_bytes == 0 ? capture_limit : max_bytes;
    if (!result.output_truncated && diff.byte_count <= display_limit) {
        diff.text = result.standard_output;
        return diff;
    }
    diff.text = truncate_utf8(result.standard_output, display_limit);
    diff.text += "\n\n… 差异过大，已截断显示（共 " +
                 std::to_string(diff.byte_count) + " 字节）。";
    diff.is_truncated = true;
    return diff;
}

DiffResult SVNService::diff_revision(const std::filesystem::path& target,
                                     std::int64_t revision,
                                     std::optional<SVNCredential> credential,
                                     int context_lines, std::size_t max_bytes,
                                     std::stop_token stop) const {
    const auto repository_url =
        repository_url_for(path_text(absolute_path(target)), stop);
    const std::size_t capture_limit = max_bytes == 0 ? 2'000'000 : max_bytes;
    const ProcessResult result = invoke(
        {"diff", "-c", std::to_string(revision), "--internal-diff", "-x",
         "-U" + std::to_string(std::max(0, context_lines))},
        {literal_target(path_text(absolute_path(target)))}, std::nullopt,
        std::move(credential), repository_url, nullptr, stop, capture_limit);
    DiffResult diff;
    diff.byte_count = result.standard_output_bytes;
    const std::size_t display_limit = max_bytes == 0 ? capture_limit : max_bytes;
    if (!result.output_truncated && diff.byte_count <= display_limit) {
        diff.text = result.standard_output;
        return diff;
    }
    diff.text = truncate_utf8(result.standard_output, display_limit);
    diff.text += "\n\n… 差异过大，已截断显示（共 " +
                 std::to_string(diff.byte_count) + " 字节）。";
    diff.is_truncated = true;
    return diff;
}

void SVNService::checkout(const std::string& url, const std::filesystem::path& destination,
                          std::optional<std::int64_t> revision, CheckoutDepth depth,
                          std::optional<SVNCredential> credential,
                          const SVNProgressCallback& progress, std::stop_token stop) {
    if (url.empty()) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "仓库地址不能为空");
    }
    if (destination.empty()) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "检出目标不能为空");
    }
    std::error_code error_code;
    if (std::filesystem::exists(destination, error_code)) {
        if (!std::filesystem::is_directory(destination, error_code)) {
            throw_svn_error(SVNErrorCode::invalid_invocation,
                            "目标已存在且不是目录：" + path_text(destination));
        }
        if (!std::filesystem::is_empty(destination, error_code)) {
            throw_svn_error(SVNErrorCode::invalid_invocation,
                            "目标目录非空，无法检出：" + path_text(destination));
        }
    }

    const std::filesystem::path destination_absolute = absolute_path(destination);
    std::vector<std::string> args = {"checkout", "--depth",
                                     std::string(to_string(depth))};
    if (revision) {
        args.push_back("-r");
        args.push_back(std::to_string(*revision));
    }

    const auto ticket = begin_journal(OperationJournal::EntryKind::checkout,
                                      destination_absolute,
                                      "检出到 " + path_text(destination.filename()));
    try {
        gate_.with_lock(path_text(destination_absolute), stop, [&] {
            invoke(args, {url, path_text(destination_absolute)}, std::nullopt,
                   std::move(credential), url, progress ? &progress : nullptr, stop);
        });
        finish_journal(ticket);
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

UpdateSummary SVNService::update(const std::filesystem::path& target,
                                 std::optional<std::int64_t> revision,
                                 std::optional<SVNCredential> credential,
                                 const SVNProgressCallback& progress,
                                 std::stop_token stop) {
    const std::string key = path_text(WorkingCopyLocator::serialization_key(target));
    const auto ticket = begin_journal(OperationJournal::EntryKind::update,
                                      text::path_from_utf8(key),
                                      "更新 " + path_text(target.filename()));
    try {
        UpdateSummary summary = gate_.with_lock(key, stop, [&] {
            std::vector<std::string> args = {"update", "--accept", "postpone"};
            if (revision) {
                args.push_back("-r");
                args.push_back(std::to_string(*revision));
            }
            const std::string target_text = literal_target(path_text(absolute_path(target)));

            const auto repository_url =
                repository_url_for(path_text(absolute_path(target)), stop);
            const ProcessResult result = invoke(args, {target_text}, std::nullopt, credential,
                                                repository_url,
                                                progress ? &progress : nullptr, stop);
            const auto parsed = SVNOutputParser::parse_update(result.standard_output);
            UpdateSummary result_summary;
            result_summary.target = path_text(target);
            result_summary.to_revision =
                SVNOutputParser::parse_updated_revision(result.standard_output);
            result_summary.updated_paths = parsed.updated;
            result_summary.added_paths = parsed.added;
            result_summary.merged_paths = parsed.merged;
            result_summary.conflicted_paths = parsed.conflicted;
            result_summary.removed_paths = parsed.deleted;
            result_summary.raw_output = LogRedactor::redact(result.standard_output);
            try {
                const InfoReport report = info(path_text(target), std::nullopt, stop);
                if (report.primary()) result_summary.to_revision = report.primary()->revision;
            } catch (...) {
            }
            try {
                if (stop.stop_requested()) {
                    result_summary.conflicts_verified = false;
                } else {
                    const StatusSnapshot after =
                        status(target, false, false, std::nullopt, stop);
                    result_summary.conflicted_paths.clear();
                    for (const auto& entry : after.conflicted()) {
                        result_summary.conflicted_paths.push_back(entry.path);
                    }
                    result_summary.conflicts_verified = true;
                }
            } catch (...) {
                // The update itself succeeded. Without a readable status the
                // caller must not be told "no conflicts".
                result_summary.conflicts_verified = false;
            }
            return result_summary;
        });
        finish_journal(ticket);
        return summary;
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

void SVNService::add(const std::vector<std::filesystem::path>& paths, bool force,
                     bool include_ignored, std::stop_token stop) {
    if (paths.empty()) return;
    const std::string key = require_same_working_copy(paths);
    const auto ticket = begin_journal(OperationJournal::EntryKind::add,
                                      text::path_from_utf8(key),
                                      "添加 " + std::to_string(paths.size()) + " 个路径");
    try {
        gate_.with_lock(key, stop, [&] {
            std::vector<std::string> args = {"add"};
            if (force) args.push_back("--force");
            if (include_ignored) args.push_back("--no-ignore");
            invoke(args, absolute_texts(paths), std::nullopt, std::nullopt, std::nullopt,
                   nullptr, stop);
        });
        finish_journal(ticket);
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

OperationPreview SVNService::preview_delete(
    const std::vector<std::filesystem::path>& paths) const {
    std::vector<std::string> discarded;
    for (const auto& path : paths) {
        const StatusSnapshot snapshot = status(path);
        for (const auto& entry : snapshot.entries) {
            if (entry.item.is(WCItemStatus::Kind::modified) ||
                entry.item.is(WCItemStatus::Kind::added) ||
                entry.item.is(WCItemStatus::Kind::unversioned) ||
                entry.item.is(WCItemStatus::Kind::replaced) ||
                entry.properties.is(WCItemStatus::Kind::modified)) {
                discarded.push_back(entry.path);
            }
        }
    }
    std::string detail = discarded.empty()
                             ? "这些文件会从磁盘和下次提交中移除。"
                             : "以下 " + std::to_string(discarded.size()) +
                                   " 项本地内容会一并丢失：\n";
    for (std::size_t index = 0; index < discarded.size() && index < 20; ++index) {
        if (index != 0) detail += "\n";
        detail += discarded[index];
    }
    OperationPreview preview;
    preview.summary = "删除「" + join_names(paths, "、") + "」并纳入版本控制";
    preview.detail = detail;
    preview.risk = discarded.empty() ? OperationPreview::Risk::medium
                                     : OperationPreview::Risk::high;
    for (const auto& path : paths) preview.affected_paths.push_back(path_text(path));
    preview.discarded_paths = std::move(discarded);
    return preview;
}

void SVNService::delete_paths(const std::vector<std::filesystem::path>& paths,
                              bool confirmed, bool force, std::stop_token stop) {
    if (paths.empty()) return;
    if (!confirmed) {
        const OperationPreview preview = preview_delete(paths);
        throw_svn_error(SVNErrorCode::confirmation_required, preview.summary, preview.detail);
    }
    const std::string key = require_same_working_copy(paths);
    const auto ticket = begin_journal(OperationJournal::EntryKind::delete_,
                                      text::path_from_utf8(key),
                                      "删除 " + std::to_string(paths.size()) + " 个路径");
    try {
        gate_.with_lock(key, stop, [&] {
            std::vector<std::string> args = {"delete"};
            if (force) args.push_back("--force");
            invoke(args, absolute_texts(paths), std::nullopt, std::nullopt, std::nullopt,
                   nullptr, stop);
        });
        finish_journal(ticket);
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

OperationPreview SVNService::preview_revert(
    const std::vector<std::filesystem::path>& paths) const {
    std::vector<std::string> discarded;
    for (const auto& path : paths) {
        const StatusSnapshot snapshot = status(path);
        for (const auto& entry : snapshot.entries) {
            if (entry.item.is(WCItemStatus::Kind::modified) ||
                entry.item.is(WCItemStatus::Kind::added) ||
                entry.item.is(WCItemStatus::Kind::deleted) ||
                entry.item.is(WCItemStatus::Kind::replaced) ||
                entry.properties.is(WCItemStatus::Kind::modified)) {
                discarded.push_back(entry.path);
            }
        }
    }
    std::string detail = discarded.empty()
                             ? "所选路径没有可还原的本地修改。"
                             : "以下本地修改会被丢弃，且无法恢复：\n";
    for (std::size_t index = 0; index < discarded.size() && index < 20; ++index) {
        if (index != 0) detail += "\n";
        detail += discarded[index];
    }
    detail += "\n未纳入版本控制的文件不受影响，不会被删除。";
    OperationPreview preview;
    preview.summary = "还原 " + std::to_string(paths.size()) + " 个路径的本地修改";
    preview.detail = detail;
    preview.risk = discarded.empty() ? OperationPreview::Risk::low
                                     : OperationPreview::Risk::high;
    for (const auto& path : paths) preview.affected_paths.push_back(path_text(path));
    preview.discarded_paths = std::move(discarded);
    return preview;
}

void SVNService::revert(const std::vector<std::filesystem::path>& paths, bool recursive,
                        bool confirmed, std::stop_token stop) {
    if (paths.empty()) return;
    if (!confirmed) {
        const OperationPreview preview = preview_revert(paths);
        throw_svn_error(SVNErrorCode::confirmation_required, preview.summary, preview.detail);
    }
    const std::string key = require_same_working_copy(paths);
    const auto ticket = begin_journal(OperationJournal::EntryKind::revert,
                                      text::path_from_utf8(key),
                                      "还原 " + std::to_string(paths.size()) + " 个路径");
    try {
        gate_.with_lock(key, stop, [&] {
            std::vector<std::string> args = {"revert", "--depth",
                                             recursive ? "infinity" : "empty"};
            invoke(args, absolute_texts(paths), std::nullopt, std::nullopt, std::nullopt,
                   nullptr, stop);
        });
        finish_journal(ticket);
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

CommitSummary SVNService::commit(const std::vector<std::filesystem::path>& paths,
                                 const std::string& message,
                                 std::optional<SVNCredential> credential,
                                 const SVNProgressCallback& progress,
                                 std::stop_token stop) {
    if (paths.empty()) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "没有选择要提交的路径");
    }
    const std::string trimmed = text::trim(message);
    if (trimmed.empty()) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "提交说明不能为空");
    }

    const std::string key = require_same_working_copy(paths);
    const auto ticket = begin_journal(OperationJournal::EntryKind::commit,
                                      text::path_from_utf8(key),
                                      "提交 " + std::to_string(paths.size()) + " 个路径");
    bool command_started = false;
    try {
        CommitSummary summary = gate_.with_lock(key, stop, [&] {
            bool has_directory = false;
            for (const auto& path : paths) {
                if (stop.stop_requested()) {
                    throw_svn_error(SVNErrorCode::cancelled, "提交已取消");
                }
                const StatusSnapshot snapshot =
                    status(path, false, false, std::nullopt, stop);
                const auto conflicted = snapshot.conflicted();
                if (!conflicted.empty()) {
                    throw_svn_error(SVNErrorCode::conflict_remains,
                                    "存在未解决的冲突：" + conflicted.front().path,
                                    "请先解决冲突并标记 resolve 后再提交。");
                }
                std::error_code error_code;
                if (std::filesystem::is_directory(path, error_code)) has_directory = true;
            }
            if (stop.stop_requested()) {
                throw_svn_error(SVNErrorCode::cancelled, "提交已取消");
            }
            const auto repository_url =
                repository_url_for(path_text(absolute_path(paths.front())), stop);
            std::vector<std::string> args = {"commit", "-m", trimmed, "--encoding", "UTF-8"};
            // A directory target would otherwise commit every modified
            // descendant. The depth applies to the whole command, so keep it
            // empty for all targets. SVN still performs copies recursively,
            // while plain added children must be among the explicit targets;
            // unselected children are left out.
            if (has_directory) {
                args.push_back("--depth");
                args.push_back("empty");
            }
            command_started = true;
            const ProcessResult result = invoke(args, absolute_texts(paths), std::nullopt,
                                                credential, repository_url,
                                                progress ? &progress : nullptr, stop);
            const auto parsed = SVNOutputParser::parse_commit(result.standard_output);
            CommitSummary result_summary;
            result_summary.revision = parsed.revision;
            result_summary.committed_paths = parsed.sending;
            result_summary.committed_paths.insert(result_summary.committed_paths.end(),
                                                  parsed.adding.begin(), parsed.adding.end());
            result_summary.committed_paths.insert(result_summary.committed_paths.end(),
                                                  parsed.deleting.begin(),
                                                  parsed.deleting.end());
            result_summary.committed_paths.insert(result_summary.committed_paths.end(),
                                                  parsed.replacing.begin(),
                                                  parsed.replacing.end());
            result_summary.raw_output = LogRedactor::redact(result.standard_output);
            return result_summary;
        });
        finish_journal(ticket);
        return summary;
    } catch (const SVNException& exception) {
        if (!command_started || !remote_outcome_unknown(exception.error().code)) {
            finish_journal(ticket);
            throw;
        }
        // The server may already have accepted the commit. Keep the journal
        // entry so recovery cannot be mistaken for "nothing happened".
        SVNError error = exception.error();
        error.message += "；提交结果未知，请先刷新历史确认，不要直接重复提交。";
        throw SVNException(std::move(error));
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

LockOutcome SVNService::lock(const std::vector<std::filesystem::path>& paths,
                             std::optional<std::string> comment, bool steal, bool confirmed,
                             std::optional<SVNCredential> credential,
                             std::stop_token stop) {
    if (paths.empty()) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "没有选择要锁定的路径");
    }
    if (steal && !confirmed) {
        throw_svn_error(SVNErrorCode::confirmation_required,
                        "「强制锁定」会抢占他人持有的锁",
                        "持有者将无法提交该路径，直到他注意到锁已易主。");
    }
    const std::string key = require_same_working_copy(paths);
    const auto ticket = begin_journal(OperationJournal::EntryKind::lock,
                                      text::path_from_utf8(key),
                                      "锁定 " + std::to_string(paths.size()) + " 个路径");
    try {
        LockOutcome outcome = gate_.with_lock(key, stop, [&] {
            std::vector<std::string> args = {"lock"};
            const std::string trimmed = text::trim(comment.value_or(""));
            if (!trimmed.empty()) {
                args.push_back("-m");
                args.push_back(trimmed);
            }
            if (steal) args.push_back("--force");
            const auto repository_url =
                repository_url_for(path_text(absolute_path(paths.front())), stop);
            const ProcessResult result = invoke(args, absolute_texts(paths), std::nullopt,
                                                credential, repository_url, nullptr, stop);
            const auto reported = LockOutputParser::locked_paths(result.standard_output);
            LockOutcome parsed;
            if (!reported.empty()) {
                parsed.locked_paths = reported;
            } else {
                for (const auto& path : paths) {
                    parsed.locked_paths.push_back(path_text(absolute_path(path)));
                }
            }
            parsed.owner = LockOutputParser::owner(result.standard_output);
            parsed.raw_output = LogRedactor::redact(result.standard_output);
            return parsed;
        });
        finish_journal(ticket);
        return outcome;
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

UnlockOutcome SVNService::unlock(const std::vector<std::filesystem::path>& paths,
                                 bool break_lock, bool confirmed,
                                 std::optional<SVNCredential> credential,
                                 std::stop_token stop) {
    if (paths.empty()) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "没有选择要解锁的路径");
    }
    if (break_lock && !confirmed) {
        throw_svn_error(SVNErrorCode::confirmation_required,
                        "「强制解除」会移除他人持有的锁",
                        "对方可能正在编辑该文件；解除后两人的提交都可能互相覆盖。");
    }
    const std::string key = require_same_working_copy(paths);
    const auto ticket = begin_journal(OperationJournal::EntryKind::unlock,
                                      text::path_from_utf8(key),
                                      "解锁 " + std::to_string(paths.size()) + " 个路径");
    try {
        UnlockOutcome outcome = gate_.with_lock(key, stop, [&] {
            std::vector<std::string> args = {"unlock"};
            if (break_lock) args.push_back("--force");
            const auto repository_url =
                repository_url_for(path_text(absolute_path(paths.front())), stop);
            const ProcessResult result = invoke(args, absolute_texts(paths), std::nullopt,
                                                credential, repository_url, nullptr, stop);
            const auto reported = LockOutputParser::unlocked_paths(result.standard_output);
            UnlockOutcome parsed;
            if (!reported.empty()) {
                parsed.unlocked_paths = reported;
            } else {
                for (const auto& path : paths) {
                    parsed.unlocked_paths.push_back(path_text(absolute_path(path)));
                }
            }
            parsed.raw_output = LogRedactor::redact(result.standard_output);
            return parsed;
        });
        finish_journal(ticket);
        return outcome;
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

LockSnapshot SVNService::locks(const std::filesystem::path& target,
                               std::optional<SVNCredential> credential,
                               std::stop_token stop) const {
    return LockSnapshot::from(status(target, false, true, std::move(credential), stop));
}

void SVNService::cleanup(const std::filesystem::path& target, std::stop_token stop) {
    const std::string key = path_text(WorkingCopyLocator::serialization_key(target));
    const auto ticket = begin_journal(OperationJournal::EntryKind::cleanup,
                                      text::path_from_utf8(key),
                                      "清理 " + path_text(target.filename()));
    try {
        gate_.with_lock(key, stop, [&] {
            invoke({"cleanup"}, {literal_target(path_text(absolute_path(target)))},
                   std::nullopt, std::nullopt, std::nullopt, nullptr, stop);
        });
        finish_journal(ticket);
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

ResolveOutcome SVNService::resolve(const std::vector<std::filesystem::path>& paths,
                                   ResolveStrategy strategy, bool confirmed, bool backup,
                                   std::stop_token stop) {
    if (paths.empty()) return {};
    if (is_destructive(strategy) && !confirmed) {
        throw_svn_error(SVNErrorCode::confirmation_required,
                        "「" + std::string(resolve_title(strategy)) + "」会覆盖本地或服务器端内容",
                        std::string(resolve_consequence(strategy)));
    }

    const std::string key = require_same_working_copy(paths);
    const auto ticket = begin_journal(OperationJournal::EntryKind::resolve,
                                      text::path_from_utf8(key),
                                      "解决 " + std::to_string(paths.size()) + " 个冲突");
    try {
        ResolveOutcome outcome = gate_.with_lock(key, stop, [&] {
            std::optional<ConflictBackup> record;
            if (backup) {
                record = backup_conflicts(paths, "resolve-" + std::string(to_string(strategy)));
            }
            std::vector<std::string> args = {"resolve",
                                             "--accept=" + std::string(to_string(strategy))};
            invoke(args, absolute_texts(paths), std::nullopt, std::nullopt, std::nullopt,
                   nullptr, stop);

            ResolveOutcome result;
            for (const auto& path : paths) result.resolved_paths.push_back(path_text(absolute_path(path)));
            result.backup = std::move(record);
            result.scans = scan_conflicts(paths);
            return result;
        });
        finish_journal(ticket);
        if (const auto root = WorkingCopyLocator::root(paths.front())) {
            prune_conflict_backups(*root);
        }
        return outcome;
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

std::vector<PropertyTarget> SVNService::properties(const std::filesystem::path& target,
                                                   bool recursive,
                                                   std::stop_token stop) const {
    std::vector<std::string> args = {"proplist", "--xml", "--verbose"};
    if (recursive) args.push_back("--recursive");
    const ProcessResult result = invoke(
        args, {literal_target(path_text(absolute_path(target)))}, std::nullopt,
        std::nullopt, std::nullopt, nullptr, stop);
    return parsing::parse_properties(result.standard_output);
}

std::optional<std::string> SVNService::property_value(const std::string& name,
                                                      const std::filesystem::path& target,
                                                      std::stop_token stop) const {
    const auto targets = properties(target, false, stop);
    if (targets.empty()) return std::nullopt;
    return targets.front().value_of(name);
}

void SVNService::set_property(const std::string& name, const std::string& value,
                              const std::vector<std::filesystem::path>& targets,
                              std::stop_token stop) {
    if (targets.empty()) return;
    SVNPropertyName::validate(name);
    for (const auto& target : targets) {
        for (const auto& holder : properties(target, false, stop)) {
            for (const auto& property : holder.properties) {
                if (property.name != name || !property.is_encoded()) continue;
                throw_svn_error(
                    SVNErrorCode::invalid_invocation,
                    "属性「" + name + "」是 " + *property.encoding +
                        " 编码的二进制值，不能用文本编辑器覆盖",
                    "请使用能够写入原始字节的 SVN 工具修改该属性。");
            }
        }
    }
    write_property({"propset", name}, value, targets, "设置属性 " + name, stop);
}

int SVNService::delete_property(const std::string& name,
                                const std::vector<std::filesystem::path>& targets,
                                std::stop_token stop) {
    if (targets.empty()) return 0;
    SVNPropertyName::validate(name);
    std::vector<std::filesystem::path> holders;
    for (const auto& target : targets) {
        if (property_value(name, target, stop)) holders.push_back(target);
    }
    if (holders.empty()) return 0;
    write_property({"propdel", name}, std::nullopt, holders, "删除属性 " + name, stop);
    return static_cast<int>(holders.size());
}

bool SVNService::add_ignore_pattern(const std::string& pattern,
                                    const std::filesystem::path& directory,
                                    std::stop_token stop) {
    const std::string trimmed = text::trim(pattern);
    if (trimmed.empty()) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "忽略规则不能为空");
    }
    const std::string key = require_same_working_copy({directory});
    const auto ticket = begin_journal(OperationJournal::EntryKind::property,
                                      text::path_from_utf8(key),
                                      "添加忽略规则 " + trimmed);
    try {
        const bool changed = gate_.with_lock(key, stop, [&] {
            const auto existing = property_value("svn:ignore", directory, stop);
            const auto entries = IgnoreList::entries(existing);
            if (std::find(entries.begin(), entries.end(), trimmed) != entries.end()) {
                return false;
            }
            std::vector<std::string> updated = entries;
            updated.push_back(trimmed);
            std::string value;
            for (std::size_t index = 0; index < updated.size(); ++index) {
                if (index != 0) value.push_back('\n');
                value += updated[index];
            }
            invoke_property_write({"propset", "svn:ignore"}, value, {directory}, stop);
            return true;
        });
        finish_journal(ticket);
        return changed;
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

IgnoreOutcome SVNService::ignore(const std::vector<std::filesystem::path>& paths,
                                 std::stop_token stop) {
    IgnoreOutcome outcome;
    if (paths.empty()) return outcome;

    const std::string key = require_same_working_copy(paths);
    const auto ticket = begin_journal(OperationJournal::EntryKind::property,
                                      text::path_from_utf8(key),
                                      "忽略 " + std::to_string(paths.size()) + " 个文件");
    try {
        outcome = gate_.with_lock(key, stop, [&] {
            IgnoreOutcome result;
            std::map<std::string, std::vector<std::filesystem::path>> groups;
            for (const auto& path : paths) {
                groups[path_text(path.parent_path())].push_back(path);
            }

            for (auto& [directory_key, files] : groups) {
                std::sort(files.begin(), files.end(), [](const auto& lhs, const auto& rhs) {
                    return text::path_to_utf8(lhs.filename()) <
                           text::path_to_utf8(rhs.filename());
                });
                std::optional<std::string> value =
                    property_value("svn:ignore", text::path_from_utf8(directory_key), stop);
                std::vector<std::string> added_here;

                for (const auto& file : files) {
                    const std::string name = path_text(file.filename());
                    if (const auto updated = IgnoreList::adding(name, value)) {
                        value = updated;
                        added_here.push_back(name);
                    } else {
                        result.already.push_back(name);
                    }
                }
                if (added_here.empty() || !value) continue;
                invoke_property_write({"propset", "svn:ignore"}, *value,
                                      {text::path_from_utf8(directory_key)}, stop);
                result.added.insert(result.added.end(), added_here.begin(), added_here.end());
            }
            return result;
        });
        finish_journal(ticket);
        return outcome;
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

void SVNService::invoke_property_write(const std::vector<std::string>& arguments,
                                       const std::optional<std::string>& value,
                                       const std::vector<std::filesystem::path>& targets,
                                       std::stop_token stop) {
    std::optional<PropertyValueFile> value_file;
    std::vector<std::string> args = arguments;
    if (value) {
        value_file.emplace(*value);
        args.push_back("-F");
        args.push_back(path_text(value_file->path()));
    }
    invoke(args, absolute_texts(targets), std::nullopt, std::nullopt, std::nullopt, nullptr,
           stop);
}

void SVNService::write_property(const std::vector<std::string>& arguments,
                                const std::optional<std::string>& value,
                                const std::vector<std::filesystem::path>& targets,
                                const std::string& summary, std::stop_token stop) {
    const std::string key = require_same_working_copy(targets);
    const auto ticket = begin_journal(OperationJournal::EntryKind::property,
                                      text::path_from_utf8(key), summary);
    try {
        gate_.with_lock(key, stop, [&] {
            invoke_property_write(arguments, value, targets, stop);
        });
        finish_journal(ticket);
    } catch (...) {
        finish_journal(ticket);
        throw;
    }
}

std::optional<ConflictArtifacts> SVNService::conflict_artifacts(
    const std::filesystem::path& target, std::stop_token stop) const {
    const ProcessResult result =
        invoke({"info", "--xml"}, {literal_target(path_text(absolute_path(target)))},
               std::nullopt, std::nullopt, std::nullopt, nullptr, stop);
    return parsing::parse_conflict_artifacts(result.standard_output);
}

std::optional<ConflictBackup> SVNService::backup_conflict_artifacts(
    const std::vector<std::filesystem::path>& paths, const std::string& reason) const {
    return backup_conflicts(paths, reason);
}

ConflictBackup SVNService::backup_conflicts(
    const std::vector<std::filesystem::path>& paths, const std::string& reason) const {
    if (paths.empty()) return {};
    const std::filesystem::path working_copy =
        WorkingCopyLocator::root(paths.front()).value_or(absolute_path(paths.front()).parent_path());
    const std::string working_copy_name =
        working_copy.filename().empty() ? std::string("working-copy")
                                        : path_text(working_copy.filename());
    const std::filesystem::path directory =
        conflict_backup_root_ / (working_copy_name + "-" + hash_key(path_text(working_copy))) /
        (timestamp_directory_name(std::chrono::system_clock::now()) + "-" +
         safe_reason(reason));

    ConflictBackup backup;
    backup.directory = path_text(directory);
    std::error_code error_code;

    try {
        for (const auto& path : paths) {
            std::vector<std::filesystem::path> artifacts;
            artifacts.push_back(path);
            for (const char* suffix : {".mine", ".working", ".orig", ".rej"}) {
                artifacts.push_back(text::path_from_utf8(path_text(path) + suffix));
            }
            if (std::filesystem::is_directory(path.parent_path(), error_code)) {
                const std::string prefix = text::path_to_utf8(path.filename()) + ".r";
                for (const auto& entry :
                     std::filesystem::directory_iterator(path.parent_path(), error_code)) {
                    const std::string name = text::path_to_utf8(entry.path().filename());
                    if (has_prefix(name, prefix)) artifacts.push_back(entry.path());
                }
            }

            for (const auto& artifact : artifacts) {
                if (!std::filesystem::is_regular_file(artifact, error_code)) continue;
                std::filesystem::path relative =
                    std::filesystem::relative(artifact, working_copy, error_code);
                if (error_code || relative.empty() ||
                    has_prefix(text::path_to_utf8(relative), "..")) {
                    relative = artifact.filename();
                }
                const std::filesystem::path destination = directory / relative;
                std::filesystem::create_directories(destination.parent_path(), error_code);
                if (error_code) {
                    throw_svn_error(SVNErrorCode::backup_failed,
                                    "无法创建备份目录：" + path_text(destination.parent_path()) +
                                        "（" + error_code.message() + "）");
                }
                std::filesystem::copy_file(artifact, destination,
                                           std::filesystem::copy_options::overwrite_existing,
                                           error_code);
                if (error_code) {
                    throw_svn_error(SVNErrorCode::backup_failed,
                                    "无法备份 " + path_text(artifact) + "（" +
                                        error_code.message() + "）");
                }
                backup.files.push_back(path_text(relative));
            }
        }
    } catch (...) {
        std::filesystem::remove_all(directory, error_code);
        throw;
    }
    return backup;
}

std::vector<ConflictMarkerScan> SVNService::scan_conflicts(
    const std::vector<std::filesystem::path>& paths) const {
    std::vector<ConflictMarkerScan> scans;
    for (const auto& path : paths) {
        ConflictMarkerScan scan;
        scan.path = path_text(path);
        std::error_code error_code;
        if (!std::filesystem::is_regular_file(path, error_code)) {
            scan.skipped = true;
            scan.skip_reason = "文件不存在";
            scans.push_back(std::move(scan));
            continue;
        }
        const auto size = std::filesystem::file_size(path, error_code);
        if (error_code || size > 8 * 1024 * 1024) {
            scan.skipped = true;
            scan.skip_reason = "超过 8 MB";
            scans.push_back(std::move(scan));
            continue;
        }
        std::ifstream input(path, std::ios::binary);
        if (!input) {
            scan.skipped = true;
            scan.skip_reason = "无法读取文件";
            scans.push_back(std::move(scan));
            continue;
        }
        std::string content((std::istreambuf_iterator<char>(input)),
                            std::istreambuf_iterator<char>());
        if (content.find('\0') != std::string::npos) {
            scan.skipped = true;
            scan.skip_reason = "二进制文件";
            scans.push_back(std::move(scan));
            continue;
        }
        if (!is_valid_utf8(content)) {
            scan.skipped = true;
            scan.skip_reason = "非 UTF-8 文件";
            scans.push_back(std::move(scan));
            continue;
        }
        const auto lines = text::split_lines(content);
        for (std::size_t index = 0; index < lines.size(); ++index) {
            const std::string_view line(lines[index]);
            if (has_prefix(line, "<<<<<<<") || has_prefix(line, ">>>>>>>") ||
                has_prefix(line, "|||||||")) {
                scan.marker_lines.push_back(index + 1);
            }
        }
        scans.push_back(std::move(scan));
    }
    return scans;
}

void SVNService::prune_conflict_backups(
    const std::filesystem::path& working_copy_root) const {
    std::error_code error_code;
    const std::filesystem::path parent =
        conflict_backup_root_ /
        (path_text(working_copy_root.filename()) + "-" + hash_key(path_text(working_copy_root)));
    if (!std::filesystem::is_directory(parent, error_code)) return;

    std::vector<std::filesystem::path> directories;
    for (const auto& entry : std::filesystem::directory_iterator(parent, error_code)) {
        if (entry.is_directory(error_code)) directories.push_back(entry.path());
    }
    if (directories.size() <= 10) return;
    std::sort(directories.begin(), directories.end(), [](const auto& lhs, const auto& rhs) {
        return text::path_to_utf8(lhs.filename()) < text::path_to_utf8(rhs.filename());
    });
    for (std::size_t index = 0; index + 10 < directories.size(); ++index) {
        std::filesystem::remove_all(directories[index], error_code);
    }
}

std::string SVNService::describe(const std::vector<std::string>& arguments) {
    std::vector<std::string> parts;
    for (std::size_t index = 0; index < arguments.size(); ++index) {
        const std::string& argument = arguments[index];
        if (argument == "-m" || argument == "--message" || argument == "-F" ||
            argument == "--file") {
            parts.push_back(argument);
            parts.push_back(argument == "-F" || argument == "--file" ? "<file>" : "<message>");
            ++index;
            continue;
        }
        parts.push_back(argument);
    }
    std::string joined;
    for (const auto& part : parts) {
        if (!joined.empty()) joined.push_back(' ');
        joined += part;
    }
    joined = LogRedactor::redact(joined);
    if (joined.size() > 300) joined = joined.substr(0, 300) + "…";
    return joined;
}

void SVNService::forget_credential(const CredentialScope& scope) {
    credentials_->remove(scope);
}

std::vector<CredentialScope> SVNService::credential_scopes() {
    return credentials_->scopes();
}

void SVNService::forget_all_credentials() { credentials_->remove_all(); }

std::shared_ptr<SVNService> make_service(const SVNDiscovery& discovery,
                                         std::shared_ptr<CredentialStoring> credentials,
                                         std::shared_ptr<OperationJournal> journal,
                                         std::chrono::milliseconds timeout,
                                         std::optional<std::filesystem::path> conflict_backup_root,
                                         std::stop_token stop) {
    SVNServiceConfiguration configuration;
    configuration.installation = discovery.resolve(stop);
    configuration.credentials = std::move(credentials);
    configuration.environment = discovery.environment;
    configuration.timeout = timeout;
    configuration.conflict_backup_root = std::move(conflict_backup_root);
    configuration.journal = std::move(journal);
    return std::make_shared<SVNService>(std::move(configuration));
}

} // namespace opensvn
