#pragma once

#include "opensvn/credentials.hpp"
#include "opensvn/discovery.hpp"
#include "opensvn/journal.hpp"
#include "opensvn/models.hpp"
#include "opensvn/process.hpp"
#include "opensvn/write_gate.hpp"

#include <chrono>
#include <cstddef>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <stop_token>
#include <string>
#include <vector>

namespace opensvn {

enum class CheckoutDepth { infinity, immediates, files, empty };

std::string_view to_string(CheckoutDepth depth);

struct SVNServiceConfiguration {
    SVNInstallation installation;
    std::shared_ptr<CredentialStoring> credentials;
    std::map<std::string, std::string> environment;
    std::chrono::milliseconds timeout{std::chrono::seconds(300)};
    std::optional<std::filesystem::path> conflict_backup_root;
    std::shared_ptr<OperationJournal> journal;
};

using SVNProgressCallback = std::function<void(std::string_view line)>;

/// The single entry point for all SVN operations.
///
/// Contract highlights: writes are serialised per working copy; destructive
/// operations take a `confirmed` flag that the service itself enforces;
/// credentials are resolved from Windows Credential Manager, sent via stdin,
/// and persisted only after a successful authenticated call.
class SVNService {
public:
    explicit SVNService(SVNServiceConfiguration configuration);

    const SVNInstallation& installation() const { return installation_; }

    // Reads
    StatusSnapshot status(const std::filesystem::path& target, bool include_ignored = false,
                          bool check_repository = false,
                          std::optional<SVNCredential> credential = std::nullopt,
                          std::stop_token stop = {}) const;
    RemotePreview remote_preview(const std::filesystem::path& target,
                                 std::optional<SVNCredential> credential = std::nullopt,
                                 std::stop_token stop = {}) const;
    InfoReport info(const std::string& target,
                    std::optional<SVNCredential> credential = std::nullopt,
                    std::stop_token stop = {}) const;
    LogPage log(const std::string& target, int limit = 50,
                std::optional<std::int64_t> start_revision = std::nullopt,
                std::optional<std::int64_t> end_revision = std::nullopt,
                std::optional<SVNCredential> credential = std::nullopt,
                const SVNProgressCallback& progress = {},
                std::stop_token stop = {}) const;
    DiffResult diff_working_copy(const std::filesystem::path& target,
                                 int context_lines = 3,
                                 std::size_t max_bytes = 2'000'000,
                                 std::stop_token stop = {}) const;
    DiffResult diff_revision(const std::filesystem::path& target, std::int64_t revision,
                             std::optional<SVNCredential> credential = std::nullopt,
                             int context_lines = 3, std::size_t max_bytes = 2'000'000,
                             std::stop_token stop = {}) const;
    std::vector<PropertyTarget> properties(const std::filesystem::path& target,
                                           bool recursive = false,
                                           std::stop_token stop = {}) const;
    std::optional<std::string> property_value(const std::string& name,
                                              const std::filesystem::path& target,
                                              std::stop_token stop = {}) const;
    LockSnapshot locks(const std::filesystem::path& target,
                       std::optional<SVNCredential> credential = std::nullopt,
                       std::stop_token stop = {}) const;
    std::optional<ConflictArtifacts> conflict_artifacts(
        const std::filesystem::path& target, std::stop_token stop = {}) const;

    // Working-copy creation and update
    void checkout(const std::string& url, const std::filesystem::path& destination,
                  std::optional<std::int64_t> revision = std::nullopt,
                  CheckoutDepth depth = CheckoutDepth::infinity,
                  std::optional<SVNCredential> credential = std::nullopt,
                  const SVNProgressCallback& progress = {}, std::stop_token stop = {});
    UpdateSummary update(const std::filesystem::path& target,
                         std::optional<std::int64_t> revision = std::nullopt,
                         std::optional<SVNCredential> credential = std::nullopt,
                         const SVNProgressCallback& progress = {},
                         std::stop_token stop = {});

    // Staging changes
    void add(const std::vector<std::filesystem::path>& paths, bool force = false,
             bool include_ignored = false, std::stop_token stop = {});
    OperationPreview preview_delete(const std::vector<std::filesystem::path>& paths) const;
    void delete_paths(const std::vector<std::filesystem::path>& paths, bool confirmed,
                      bool force = false, std::stop_token stop = {});
    OperationPreview preview_revert(const std::vector<std::filesystem::path>& paths) const;
    void revert(const std::vector<std::filesystem::path>& paths, bool recursive,
                bool confirmed, std::stop_token stop = {});

    // Commit
    CommitSummary commit(const std::vector<std::filesystem::path>& paths,
                         const std::string& message,
                         std::optional<SVNCredential> credential = std::nullopt,
                         const SVNProgressCallback& progress = {},
                         std::stop_token stop = {});

    // Locks
    LockOutcome lock(const std::vector<std::filesystem::path>& paths,
                     std::optional<std::string> comment, bool steal, bool confirmed,
                     std::optional<SVNCredential> credential = std::nullopt,
                     std::stop_token stop = {});
    UnlockOutcome unlock(const std::vector<std::filesystem::path>& paths, bool break_lock,
                         bool confirmed,
                         std::optional<SVNCredential> credential = std::nullopt,
                         std::stop_token stop = {});

    // Recovery and conflicts
    void cleanup(const std::filesystem::path& target, std::stop_token stop = {});
    ResolveOutcome resolve(const std::vector<std::filesystem::path>& paths,
                           ResolveStrategy strategy, bool confirmed, bool backup = true,
                           std::stop_token stop = {});
    std::optional<ConflictBackup> backup_conflict_artifacts(
        const std::vector<std::filesystem::path>& paths, const std::string& reason) const;

    // Properties
    void set_property(const std::string& name, const std::string& value,
                      const std::vector<std::filesystem::path>& targets,
                      std::stop_token stop = {});
    int delete_property(const std::string& name,
                        const std::vector<std::filesystem::path>& targets,
                        std::stop_token stop = {});
    bool add_ignore_pattern(const std::string& pattern,
                            const std::filesystem::path& directory,
                            std::stop_token stop = {});
    IgnoreOutcome ignore(const std::vector<std::filesystem::path>& paths,
                         std::stop_token stop = {});

    // Credentials
    void forget_credential(const CredentialScope& scope);
    std::vector<CredentialScope> credential_scopes();
    void forget_all_credentials();

    void set_max_concurrent_writes(int value) { gate_.set_max_concurrent(value); }

private:
    ProcessResult invoke(const std::vector<std::string>& arguments,
                         const std::vector<std::string>& positionals,
                         const std::optional<std::filesystem::path>& working_directory,
                         std::optional<SVNCredential> credential,
                         const std::optional<std::string>& repository_url,
                         const SVNProgressCallback* progress, std::stop_token stop,
                         std::size_t maximum_captured_bytes = 0) const;
    std::optional<std::string> repository_url_for(const std::string& path,
                                                  std::stop_token stop) const;
    std::optional<std::string> begin_journal(OperationJournal::EntryKind kind,
                                             const std::filesystem::path& working_copy,
                                             const std::string& summary) const;
    void finish_journal(const std::optional<std::string>& ticket) const;
    void invoke_property_write(const std::vector<std::string>& arguments,
                               const std::optional<std::string>& value,
                               const std::vector<std::filesystem::path>& targets,
                               std::stop_token stop);
    void write_property(const std::vector<std::string>& arguments,
                        const std::optional<std::string>& value,
                        const std::vector<std::filesystem::path>& targets,
                        const std::string& summary, std::stop_token stop);
    ConflictBackup backup_conflicts(const std::vector<std::filesystem::path>& paths,
                                    const std::string& reason) const;
    std::vector<ConflictMarkerScan> scan_conflicts(
        const std::vector<std::filesystem::path>& paths) const;
    void prune_conflict_backups(const std::filesystem::path& working_copy_root) const;
    static std::string describe(const std::vector<std::string>& arguments);

    SVNInstallation installation_;
    std::shared_ptr<CredentialStoring> credentials_;
    ProcessRunner runner_;
    WCWriteGate gate_;
    std::chrono::milliseconds timeout_;
    std::filesystem::path conflict_backup_root_;
    std::shared_ptr<OperationJournal> journal_;
};

/// Resolves svn the way the app does and builds a service.
std::shared_ptr<SVNService> make_service(
    const SVNDiscovery& discovery, std::shared_ptr<CredentialStoring> credentials,
    std::shared_ptr<OperationJournal> journal = nullptr,
    std::chrono::milliseconds timeout = std::chrono::seconds(300),
    std::optional<std::filesystem::path> conflict_backup_root = std::nullopt,
    std::stop_token stop = {});

} // namespace opensvn
