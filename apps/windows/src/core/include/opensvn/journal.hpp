#pragma once

#include "opensvn/models.hpp"

#include <filesystem>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace opensvn {

/// A durable record of write operations, so a crash or power loss leaves
/// evidence instead of a mystery. Entries are written before the subprocess
/// starts and removed when it returns; a surviving entry is, by construction,
/// an operation with no recorded outcome.
class OperationJournal {
public:
    enum class EntryKind {
        checkout,
        update,
        commit,
        add,
        delete_,
        revert,
        resolve,
        cleanup,
        property,
        lock,
        unlock,
    };

    struct Entry {
        std::string id;
        EntryKind kind = EntryKind::update;
        std::string working_copy;
        std::string summary;
        Timestamp started_at;
        std::string run_identifier;
        std::uint32_t process_identifier = 0;

        std::string title() const;
        std::string recovery_advice() const;
    };

    static constexpr std::size_t maximum_entries = 50;

    static std::filesystem::path default_directory();

    explicit OperationJournal(std::optional<std::filesystem::path> directory = std::nullopt,
                              std::string run_identifier = {});

    /// Records an operation that is about to start; returns the ticket.
    std::string begin(EntryKind kind, const std::filesystem::path& working_copy,
                      const std::string& summary, Timestamp now = std::chrono::system_clock::now());

    /// Removes the entry. Safe twice, safe with nullopt. A failed operation is
    /// not an interrupted one: its outcome is known.
    void finish(const std::optional<std::string>& ticket);

    std::vector<Entry> unfinished(std::size_t limit = 20) const;
    void discard(const std::string& id);
    void discard_all();
    std::vector<Entry> all_entries() const;

    std::optional<std::filesystem::path> quarantine_path() const;
    std::optional<std::string> write_failure() const;

    const std::filesystem::path& file_path() const { return file_path_; }
    const std::string& run_identifier() const { return run_identifier_; }

    static std::string_view kind_token(EntryKind kind);

private:
    struct Loaded {
        std::vector<Entry> entries;
        std::optional<std::filesystem::path> quarantined;
    };

    Loaded load_locked() const;
    void persist_locked(const std::vector<Entry>& entries);
    std::vector<Entry> load_entries_locked() const;
    static std::vector<Entry> trimmed(std::vector<Entry> entries);

    std::filesystem::path file_path_;
    std::string run_identifier_;
    mutable std::mutex mutex_;
    mutable std::optional<std::filesystem::path> quarantined_;
    mutable std::optional<std::string> last_write_failure_;
};

} // namespace opensvn
