#pragma once

#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <optional>
#include <set>
#include <stop_token>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>

namespace opensvn {

/// Locates the working-copy root by walking up to the nearest `.svn` directory.
/// Filesystem-only, so it costs no subprocess.
class WorkingCopyLocator {
public:
    static std::optional<std::filesystem::path> root(const std::filesystem::path& path);
    static bool is_working_copy(const std::filesystem::path& path);
    static std::filesystem::path serialization_key(const std::filesystem::path& path);
    /// Case-folded identity, suitable for comparing two paths for "same
    /// working copy" on a case-insensitive file system.
    static std::string comparison_key(const std::filesystem::path& path);
};

/// Serialises write operations per working copy (red line R4), both inside
/// this process and against other OpenSVN instances, and caps total
/// concurrency. Reads are not serialised.
class WCWriteGate {
public:
    static constexpr int default_max_concurrent = 4;
    static constexpr int minimum_concurrent = 1;
    static constexpr int maximum_concurrent = 32;

    explicit WCWriteGate(int max_concurrent = default_max_concurrent);

    bool is_busy(const std::string& key) const;
    std::set<std::string> busy_keys() const;
    int max_concurrent_writes() const;
    int active_count() const;
    void set_max_concurrent(int value);

    void acquire(const std::string& key, std::stop_token stop = {});
    void release(const std::string& key);

    template <typename Function>
    auto with_lock(std::string key, Function&& function) -> decltype(function()) {
        return with_lock(std::move(key), std::stop_token{}, std::forward<Function>(function));
    }

    template <typename Function>
    auto with_lock(std::string key, std::stop_token stop,
                   Function&& function) -> decltype(function()) {
        // acquire_key returns the canonical key; moving it into the guard cannot
        // throw after the slot has been taken.
        LockGuard guard{*this, acquire_key(key, stop)};
        return function();
    }

private:
    class LockGuard {
    public:
        LockGuard(WCWriteGate& gate, std::string key)
            : gate_(gate), key_(std::move(key)) {}
        ~LockGuard() { gate_.release_key(key_); }
        LockGuard(const LockGuard&) = delete;
        LockGuard& operator=(const LockGuard&) = delete;

    private:
        WCWriteGate& gate_;
        std::string key_;
    };

    std::string acquire_key(const std::string& key, std::stop_token stop);
    void release_key(const std::string& normalized_key) noexcept;

    mutable std::mutex mutex_;
    std::condition_variable_any condition_;
    std::set<std::string> busy_;
    /// Named kernel mutexes (void* = HANDLE) serialise writers in other
    /// OpenSVN processes that target the same working copy.
    std::unordered_map<std::string, void*> cross_process_;
    int active_ = 0;
    int limit_ = default_max_concurrent;
};

} // namespace opensvn
