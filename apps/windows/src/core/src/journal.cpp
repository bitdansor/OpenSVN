#include "opensvn/journal.hpp"

#include "opensvn/text.hpp"

#include <windows.h>

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <stdexcept>

namespace opensvn {

namespace {

using json = nlohmann::json;

constexpr int current_version = 1;

std::filesystem::path environment_path(const wchar_t* name) {
    std::wstring buffer(32768, L'\0');
    const DWORD length = GetEnvironmentVariableW(name, buffer.data(),
                                                 static_cast<DWORD>(buffer.size()));
    if (length == 0 || length >= buffer.size()) return {};
    buffer.resize(length);
    return std::filesystem::path(buffer);
}

std::string sanitized_stamp(Timestamp value) {
    std::string stamp = format_iso8601(value);
    std::replace(stamp.begin(), stamp.end(), ':', '-');
    return stamp;
}

std::string read_file(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot open " + text::path_to_utf8(path));
    std::string data((std::istreambuf_iterator<char>(input)),
                     std::istreambuf_iterator<char>());
    return data;
}

void write_file_atomically(const std::filesystem::path& path, const std::string& data) {
    std::error_code error_code;
    std::filesystem::create_directories(path.parent_path(), error_code);
    if (error_code) {
        throw std::runtime_error("cannot create " + text::path_to_utf8(path.parent_path()) +
                                 ": " + error_code.message());
    }
    const std::filesystem::path temporary =
        path.parent_path() / (path.filename().wstring() + L".tmp-" +
                              text::to_wide(text::random_suffix()));
    {
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        if (!output) throw std::runtime_error("cannot open " + text::path_to_utf8(temporary));
        output.write(data.data(), static_cast<std::streamsize>(data.size()));
        output.flush();
        if (!output) throw std::runtime_error("cannot write " + text::path_to_utf8(temporary));
    }
    // MOVEFILE_WRITE_THROUGH flushes the move, not the file contents. A
    // write-ahead record is useless if a power loss leaves an empty file.
    {
        HANDLE handle = CreateFileW(temporary.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (handle == INVALID_HANDLE_VALUE) {
            const DWORD code = GetLastError();
            DeleteFileW(temporary.c_str());
            throw std::runtime_error("cannot flush " + text::path_to_utf8(temporary) +
                                     " (Windows error " + std::to_string(code) + ")");
        }
        const BOOL flushed = FlushFileBuffers(handle);
        const DWORD code = GetLastError();
        CloseHandle(handle);
        if (!flushed) {
            DeleteFileW(temporary.c_str());
            throw std::runtime_error("cannot flush " + text::path_to_utf8(temporary) +
                                     " (Windows error " + std::to_string(code) + ")");
        }
    }
    if (!MoveFileExW(temporary.c_str(), path.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        const DWORD code = GetLastError();
        DeleteFileW(temporary.c_str());
        throw std::runtime_error("cannot replace " + text::path_to_utf8(path) +
                                 " (Windows error " + std::to_string(code) + ")");
    }
}

/// Serialises read-modify-write cycles across processes. The journal is
/// replaced by rename, so locking the journal file itself would lock an inode
/// that the next writer swaps out; a sidecar file has a stable identity.
class CrossProcessLock {
public:
    explicit CrossProcessLock(const std::filesystem::path& journal_path) {
        std::error_code error_code;
        std::filesystem::create_directories(journal_path.parent_path(), error_code);
        if (error_code) {
            throw std::runtime_error("cannot create " +
                                     text::path_to_utf8(journal_path.parent_path()) + ": " +
                                     error_code.message());
        }
        lock_path_ = journal_path;
        lock_path_ += L".lock";
        handle_ = CreateFileW(lock_path_.c_str(), GENERIC_READ | GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
        if (handle_ == INVALID_HANDLE_VALUE) {
            const DWORD error = GetLastError();
            throw std::runtime_error("cannot open " + text::path_to_utf8(lock_path_) +
                                     " (Windows error " + std::to_string(error) + ")");
        }
        OVERLAPPED overlapped{};
        if (!LockFileEx(handle_, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &overlapped)) {
            const DWORD error = GetLastError();
            CloseHandle(handle_);
            handle_ = INVALID_HANDLE_VALUE;
            throw std::runtime_error("cannot lock " + text::path_to_utf8(lock_path_) +
                                     " (Windows error " + std::to_string(error) + ")");
        }
    }

    ~CrossProcessLock() {
        if (handle_ != INVALID_HANDLE_VALUE) {
            OVERLAPPED overlapped{};
            UnlockFileEx(handle_, 0, 1, 0, &overlapped);
            CloseHandle(handle_);
        }
    }

    CrossProcessLock(const CrossProcessLock&) = delete;
    CrossProcessLock& operator=(const CrossProcessLock&) = delete;

private:
    std::filesystem::path lock_path_;
    HANDLE handle_ = INVALID_HANDLE_VALUE;
};

OperationJournal::EntryKind parse_kind(std::string_view token) {
    if (token == "checkout") return OperationJournal::EntryKind::checkout;
    if (token == "update") return OperationJournal::EntryKind::update;
    if (token == "commit") return OperationJournal::EntryKind::commit;
    if (token == "add") return OperationJournal::EntryKind::add;
    if (token == "delete") return OperationJournal::EntryKind::delete_;
    if (token == "revert") return OperationJournal::EntryKind::revert;
    if (token == "resolve") return OperationJournal::EntryKind::resolve;
    if (token == "cleanup") return OperationJournal::EntryKind::cleanup;
    if (token == "property") return OperationJournal::EntryKind::property;
    if (token == "lock") return OperationJournal::EntryKind::lock;
    if (token == "unlock") return OperationJournal::EntryKind::unlock;
    return OperationJournal::EntryKind::update;
}

json entry_to_json(const OperationJournal::Entry& entry) {
    return json{{"id", entry.id},
                {"kind", OperationJournal::kind_token(entry.kind)},
                {"workingCopy", entry.working_copy},
                {"summary", entry.summary},
                {"startedAt", format_iso8601(entry.started_at)},
                {"runIdentifier", entry.run_identifier},
                {"processIdentifier", entry.process_identifier}};
}

std::optional<OperationJournal::Entry> entry_from_json(const json& value) {
    if (!value.is_object()) return std::nullopt;
    try {
        OperationJournal::Entry entry;
        entry.id = value.value("id", "");
        entry.kind = parse_kind(value.value("kind", "update"));
        entry.working_copy = value.value("workingCopy", "");
        entry.summary = value.value("summary", "");
        entry.started_at = parse_svn_date(value.value("startedAt", ""))
                               .value_or(Timestamp{});
        entry.run_identifier = value.value("runIdentifier", "");
        entry.process_identifier = value.value("processIdentifier", 0u);
        if (entry.id.empty()) return std::nullopt;
        return entry;
    } catch (...) {
        return std::nullopt;
    }
}

} // namespace

std::string_view OperationJournal::kind_token(EntryKind kind) {
    switch (kind) {
    case EntryKind::checkout: return "checkout";
    case EntryKind::update: return "update";
    case EntryKind::commit: return "commit";
    case EntryKind::add: return "add";
    case EntryKind::delete_: return "delete";
    case EntryKind::revert: return "revert";
    case EntryKind::resolve: return "resolve";
    case EntryKind::cleanup: return "cleanup";
    case EntryKind::property: return "property";
    case EntryKind::lock: return "lock";
    case EntryKind::unlock: return "unlock";
    }
    return "update";
}

std::string OperationJournal::Entry::title() const {
    switch (kind) {
    case EntryKind::checkout: return "检出";
    case EntryKind::update: return "更新";
    case EntryKind::commit: return "提交";
    case EntryKind::add: return "添加";
    case EntryKind::delete_: return "删除";
    case EntryKind::revert: return "还原";
    case EntryKind::resolve: return "解决冲突";
    case EntryKind::cleanup: return "清理";
    case EntryKind::property: return "修改属性";
    case EntryKind::lock: return "锁定";
    case EntryKind::unlock: return "解锁";
    }
    return "操作";
}

std::string OperationJournal::Entry::recovery_advice() const {
    switch (kind) {
    case EntryKind::commit:
        return "提交可能已经到达服务器，也可能没有。先刷新状态确认，不要直接重复提交。";
    case EntryKind::checkout:
        return "检出可能只完成了一部分。确认目录内容后再决定是继续还是删掉重来。";
    case EntryKind::update:
    case EntryKind::revert:
    case EntryKind::resolve:
    case EntryKind::delete_:
    case EntryKind::add:
    case EntryKind::property:
        return "工作副本可能停在中间状态。运行「清理」后再刷新状态。";
    case EntryKind::lock:
        return "锁可能已在服务器上生效。刷新锁定状态确认，再决定是否重试。";
    case EntryKind::unlock:
        return "锁可能已释放。刷新锁定状态确认，不要直接重复解锁。";
    case EntryKind::cleanup:
        return "上次清理没有完成。重新运行「清理」即可。";
    }
    return "运行「清理」后再刷新状态。";
}

std::filesystem::path OperationJournal::default_directory() {
    auto local_app_data = environment_path(L"LOCALAPPDATA");
    if (local_app_data.empty()) {
        const auto profile = environment_path(L"USERPROFILE");
        if (!profile.empty()) local_app_data = profile / "AppData" / "Local";
    }
    if (local_app_data.empty()) local_app_data = std::filesystem::temp_directory_path();
    return local_app_data / "OpenSVN";
}

OperationJournal::OperationJournal(std::optional<std::filesystem::path> directory,
                                   std::string run_identifier)
    : file_path_((directory.value_or(default_directory())) / "journal.json"),
      run_identifier_(run_identifier.empty() ? text::random_uuid()
                                             : std::move(run_identifier)) {
    std::lock_guard lock(mutex_);
    CrossProcessLock file_lock(file_path_);
    const Loaded loaded = load_locked();
    quarantined_ = loaded.quarantined;
}

OperationJournal::Loaded OperationJournal::load_locked() const {
    Loaded loaded;
    std::error_code error_code;
    if (!std::filesystem::exists(file_path_, error_code)) return loaded;

    try {
        const std::string data = read_file(file_path_);
        const json payload = json::parse(data);
        const int version = payload.value("version", 0);
        if (version > current_version) {
            const std::filesystem::path quarantine =
                file_path_.parent_path() /
                ("journal.corrupt-" + sanitized_stamp(std::chrono::system_clock::now()) +
                 ".json");
            std::filesystem::rename(file_path_, quarantine, error_code);
            if (!error_code) loaded.quarantined = quarantine;
            return loaded;
        }
        if (!payload.contains("entries") || !payload["entries"].is_array()) {
            throw std::runtime_error("journal has no entries array");
        }
        for (const auto& item : payload["entries"]) {
            if (auto entry = entry_from_json(item)) loaded.entries.push_back(std::move(*entry));
        }
    } catch (...) {
        const std::filesystem::path quarantine =
            file_path_.parent_path() /
            ("journal.corrupt-" + sanitized_stamp(std::chrono::system_clock::now()) + "-" +
             text::random_suffix() + ".json");
        std::filesystem::rename(file_path_, quarantine, error_code);
        if (!error_code) loaded.quarantined = quarantine;
        loaded.entries.clear();
    }
    return loaded;
}

std::vector<OperationJournal::Entry> OperationJournal::load_entries_locked() const {
    Loaded loaded = load_locked();
    if (loaded.quarantined) quarantined_ = loaded.quarantined;
    return loaded.entries;
}

std::vector<OperationJournal::Entry> OperationJournal::trimmed(std::vector<Entry> entries) {
    if (entries.size() <= maximum_entries) return entries;
    std::sort(entries.begin(), entries.end(), [](const Entry& lhs, const Entry& rhs) {
        return lhs.started_at > rhs.started_at;
    });
    entries.resize(maximum_entries);
    return entries;
}

void OperationJournal::persist_locked(const std::vector<Entry>& entries) {
    json payload;
    payload["version"] = current_version;
    payload["entries"] = json::array();
    for (const auto& entry : entries) payload["entries"].push_back(entry_to_json(entry));
    try {
        write_file_atomically(file_path_, payload.dump(2));
        last_write_failure_.reset();
    } catch (const std::exception& error) {
        // Losing the journal is bad; refusing to run the operation is worse.
        last_write_failure_ = error.what();
        throw;
    }
}

std::string OperationJournal::begin(EntryKind kind, const std::filesystem::path& working_copy,
                                    const std::string& summary, Timestamp now) {
    std::lock_guard lock(mutex_);
    CrossProcessLock file_lock(file_path_);
    std::vector<Entry> entries = load_entries_locked();

    Entry entry;
    entry.id = text::random_uuid();
    entry.kind = kind;
    entry.working_copy = text::path_to_utf8(std::filesystem::absolute(working_copy));
    entry.summary = summary;
    entry.started_at = now;
    entry.run_identifier = run_identifier_;
    entry.process_identifier = GetCurrentProcessId();
    const std::string id = entry.id;

    entries.push_back(std::move(entry));
    persist_locked(trimmed(std::move(entries)));
    return id;
}

void OperationJournal::finish(const std::optional<std::string>& ticket) {
    if (!ticket) return;
    std::lock_guard lock(mutex_);
    CrossProcessLock file_lock(file_path_);
    std::vector<Entry> entries = load_entries_locked();
    const auto before = entries.size();
    entries.erase(std::remove_if(entries.begin(), entries.end(),
                                 [&](const Entry& entry) { return entry.id == *ticket; }),
                  entries.end());
    if (entries.size() != before) persist_locked(entries);
}

std::vector<OperationJournal::Entry> OperationJournal::unfinished(
    std::size_t limit) const {
    std::lock_guard lock(mutex_);
    CrossProcessLock file_lock(file_path_);
    std::vector<Entry> entries = load_entries_locked();
    entries.erase(std::remove_if(entries.begin(), entries.end(),
                                 [&](const Entry& entry) {
                                     return entry.run_identifier == run_identifier_;
                                 }),
                  entries.end());
    std::sort(entries.begin(), entries.end(), [](const Entry& lhs, const Entry& rhs) {
        return lhs.started_at > rhs.started_at;
    });
    if (entries.size() > limit) entries.resize(limit);
    return entries;
}

void OperationJournal::discard(const std::string& id) {
    std::lock_guard lock(mutex_);
    CrossProcessLock file_lock(file_path_);
    std::vector<Entry> entries = load_entries_locked();
    entries.erase(std::remove_if(entries.begin(), entries.end(),
                                 [&](const Entry& entry) { return entry.id == id; }),
                  entries.end());
    try {
        persist_locked(entries);
    } catch (...) {
    }
}

void OperationJournal::discard_all() {
    std::lock_guard lock(mutex_);
    CrossProcessLock file_lock(file_path_);
    std::vector<Entry> entries = load_entries_locked();
    entries.erase(std::remove_if(entries.begin(), entries.end(),
                                 [&](const Entry& entry) {
                                     return entry.run_identifier != run_identifier_;
                                 }),
                  entries.end());
    try {
        persist_locked(entries);
    } catch (...) {
    }
}

std::vector<OperationJournal::Entry> OperationJournal::all_entries() const {
    std::lock_guard lock(mutex_);
    CrossProcessLock file_lock(file_path_);
    return load_entries_locked();
}

std::optional<std::filesystem::path> OperationJournal::quarantine_path() const {
    std::lock_guard lock(mutex_);
    return quarantined_;
}

std::optional<std::string> OperationJournal::write_failure() const {
    std::lock_guard lock(mutex_);
    return last_write_failure_;
}

} // namespace opensvn
