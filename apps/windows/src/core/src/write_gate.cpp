#include "opensvn/write_gate.hpp"

#include "opensvn/errors.hpp"
#include "opensvn/text.hpp"

#include <windows.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cwchar>
#include <limits>
#include <string>

namespace opensvn {

namespace {

std::filesystem::path normalized_absolute(const std::filesystem::path& path) {
    std::error_code error_code;
    std::filesystem::path absolute = std::filesystem::absolute(path, error_code);
    if (error_code) absolute = path;
    return absolute.lexically_normal();
}

bool path_is_directory(const std::filesystem::path& path) {
    std::error_code error_code;
    return std::filesystem::is_directory(path, error_code);
}

// NTFS is case-insensitive. Normalizing the key is what makes D:\Repo and
// d:\repo share one write slot; without it R4 is only true for one spelling.
std::string normalize_key(const std::string& key) {
    std::filesystem::path path = text::path_from_utf8(key).lexically_normal();
    std::wstring wide = path.native();
    std::replace(wide.begin(), wide.end(), L'\\', L'/');
    if (wide.empty()) return {};
    if (wide.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        return text::to_utf8(wide);
    }

    std::wstring folded(wide.size(), L'\0');
    const int written = LCMapStringEx(
        LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, wide.data(),
        static_cast<int>(wide.size()), folded.data(),
        static_cast<int>(folded.size()), nullptr, nullptr, 0);
    if (written <= 0) return text::to_utf8(wide);
    folded.resize(static_cast<std::size_t>(written));
    return text::to_utf8(folded);
}

// A stable FNV-1a hash keeps the name identical across processes and app
// versions; std::hash is only required to be stable within one process.
std::wstring cross_process_name(const std::string& normalized) {
    std::uint64_t hash = 1469598103934665603ull;
    for (const unsigned char byte : normalized) {
        hash ^= byte;
        hash *= 1099511628211ull;
    }
    wchar_t buffer[64]{};
    std::swprintf(buffer, 64, L"Local\\OpenSVN-WC-%016llx",
                  static_cast<unsigned long long>(hash));
    return buffer;
}

} // namespace

std::optional<std::filesystem::path> WorkingCopyLocator::root(
    const std::filesystem::path& path) {
    std::filesystem::path current = normalized_absolute(path);
    std::error_code error_code;
    if (!std::filesystem::exists(current, error_code) ||
        !std::filesystem::is_directory(current, error_code)) {
        if (!current.parent_path().empty()) current = current.parent_path();
    }

    for (;;) {
        if (path_is_directory(current / ".svn")) return current;
        if (!current.has_parent_path() || current.parent_path() == current) return std::nullopt;
        current = current.parent_path();
    }
}

bool WorkingCopyLocator::is_working_copy(const std::filesystem::path& path) {
    return root(path).has_value();
}

std::filesystem::path WorkingCopyLocator::serialization_key(
    const std::filesystem::path& path) {
    if (const auto found = root(path)) return *found;
    return normalized_absolute(path);
}

std::string WorkingCopyLocator::comparison_key(const std::filesystem::path& path) {
    return normalize_key(text::path_to_utf8(serialization_key(path)));
}

WCWriteGate::WCWriteGate(int max_concurrent) { set_max_concurrent(max_concurrent); }

bool WCWriteGate::is_busy(const std::string& key) const {
    const std::string normalized = normalize_key(key);
    std::lock_guard lock(mutex_);
    return busy_.contains(normalized);
}

std::set<std::string> WCWriteGate::busy_keys() const {
    std::lock_guard lock(mutex_);
    return busy_;
}

int WCWriteGate::max_concurrent_writes() const {
    std::lock_guard lock(mutex_);
    return limit_;
}

int WCWriteGate::active_count() const {
    std::lock_guard lock(mutex_);
    return active_;
}

void WCWriteGate::set_max_concurrent(int value) {
    std::lock_guard lock(mutex_);
    limit_ = std::clamp(value, minimum_concurrent, maximum_concurrent);
    condition_.notify_all();
}

std::string WCWriteGate::acquire_key(const std::string& key, std::stop_token stop) {
    std::string normalized = normalize_key(key);
    // Copy the token before taking any state; a bad_alloc here leaves the gate
    // untouched.
    std::string token = normalized;

    {
        std::unique_lock lock(mutex_);
        // One predicate for both limits: a thread waiting for a busy key must not
        // consume a global slot while it waits.
        const bool acquired = condition_.wait(lock, stop, [&] {
            return active_ < limit_ && !busy_.contains(normalized);
        });
        if (!acquired) {
            throw_svn_error(SVNErrorCode::cancelled,
                            "等待工作副本写操作的锁定已取消");
        }

        ++active_;
        try {
            busy_.insert(std::move(normalized));
        } catch (...) {
            --active_;
            condition_.notify_all();
            throw;
        }
    }

    if (stop.stop_requested()) {
        release_key(token);
        throw_svn_error(SVNErrorCode::cancelled, "等待工作副本写操作的锁定已取消");
    }

    // The in-process gate only covers this app instance. A second OpenSVN
    // window must not run another svn write against the same working copy.
    HANDLE cross = CreateMutexW(nullptr, FALSE, cross_process_name(token).c_str());
    if (!cross) {
        const DWORD error = GetLastError();
        release_key(token);
        throw_svn_error(SVNErrorCode::command_failed,
                        "无法创建跨进程写锁（Windows 错误 " +
                            std::to_string(error) + "）");
    }

    for (;;) {
        const DWORD wait = WaitForSingleObject(cross, 50);
        if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) break;
        if (wait == WAIT_FAILED) {
            const DWORD error = GetLastError();
            CloseHandle(cross);
            release_key(token);
            throw_svn_error(SVNErrorCode::command_failed,
                            "等待跨进程写锁失败（Windows 错误 " +
                                std::to_string(error) + "）");
        }
        if (stop.stop_requested()) {
            CloseHandle(cross);
            release_key(token);
            throw_svn_error(SVNErrorCode::cancelled,
                            "等待工作副本写操作的锁定已取消");
        }
    }

    try {
        std::lock_guard lock(mutex_);
        const bool inserted = cross_process_.emplace(token, cross).second;
        if (!inserted) CloseHandle(cross);
    } catch (...) {
        ReleaseMutex(cross);
        CloseHandle(cross);
        release_key(token);
        throw;
    }
    return token;
}

void WCWriteGate::release_key(const std::string& normalized_key) noexcept {
    std::lock_guard lock(mutex_);
    if (const auto cross = cross_process_.find(normalized_key);
        cross != cross_process_.end()) {
        ReleaseMutex(static_cast<HANDLE>(cross->second));
        CloseHandle(static_cast<HANDLE>(cross->second));
        cross_process_.erase(cross);
    }
    busy_.erase(normalized_key);
    if (active_ > 0) --active_;
    condition_.notify_all();
}

void WCWriteGate::acquire(const std::string& key, std::stop_token stop) {
    (void)acquire_key(key, stop);
}

void WCWriteGate::release(const std::string& key) {
    release_key(normalize_key(key));
}

} // namespace opensvn
