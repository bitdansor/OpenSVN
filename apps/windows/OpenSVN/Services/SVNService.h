// OpenSVN — SVN service layer (Windows).
//
// The single place that turns a user intent into an `svn` invocation. GUI code
// never builds arguments and never touches a password; it calls these methods.
//
// Contract: specifications/svn-operations.md (semantics, preconditions,
// side effects) and docs/development/decisions/ADR-0006-credentials.md.
//
// Red lines enforced here, not in the UI:
//   R2 — the password travels on stdin, is never an argument, and is dropped when
//        the server rejects it.
//   R3 — delete / revert / resolve require `confirmed = true`; without it the call
//        throws SVNErrorCode::confirmationRequired before running anything.
//   R4 — writes on one working copy are serialized through WorkingCopyGate.
//   R7 — every read goes through --xml and SVNXMLParser.

#pragma once

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <mutex>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Models/SVNModels.h"
#include "Services/CredentialStore.h"
#include "Services/SVNProcessRunner.h"

namespace opensvn {

// Serializes writes per working copy root, so two windows cannot interleave a
// commit and an update on the same tree (R4). Header-only: it is three lines of
// logic and a map, not worth a translation unit.
class WorkingCopyGate {
public:
    class Guard {
    public:
        Guard(WorkingCopyGate* gate, std::string key) : gate_(gate), key_(std::move(key)) {}
        ~Guard() { if (gate_) gate_->Release(key_); }
        Guard(const Guard&) = delete;
        Guard& operator=(const Guard&) = delete;
        Guard(Guard&& other) noexcept : gate_(other.gate_), key_(std::move(other.key_)) { other.gate_ = nullptr; }

    private:
        WorkingCopyGate* gate_ = nullptr;
        std::string key_;
    };

    // Blocks until the working copy is free. `stop` is honoured while waiting.
    Guard Acquire(const std::filesystem::path& working_copy, std::stop_token stop = {});

    bool IsBusy(const std::filesystem::path& working_copy) const;

private:
    void Release(const std::string& key);

    mutable std::mutex mutex_;
    std::condition_variable_any condition_;
    std::vector<std::string> holders_;
};

// Walks up from `path` looking for a `.svn` directory. Returns nullopt when the
// path is not inside a working copy — callers must treat that as "not a working
// copy" (SVN-0003) rather than guessing a parent directory.
std::optional<std::filesystem::path> FindWorkingCopyRoot(const std::filesystem::path& path);

class SVNService {
public:
    SVNService(std::filesystem::path svn_executable,
               std::shared_ptr<CredentialStore> credentials);

    // ---- reads -----------------------------------------------------------
    StatusSnapshot Status(const std::filesystem::path& working_copy,
                          bool include_ignored = false,
                          std::stop_token stop = {},
                          OutputLineHandler on_line = {},
                          ProgressHandler on_progress = {});

    InfoReport Info(const std::string& target,
                    std::stop_token stop = {},
                    ProgressHandler on_progress = {});

    // `end_revision` <= 0 means HEAD. Paging continues from `page.oldest_revision()`.
    LogPage Log(const std::string& target,
                std::size_t limit,
                std::int64_t end_revision = 0,
                std::stop_token stop = {},
                ProgressHandler on_progress = {});

    std::string Diff(const std::filesystem::path& working_copy,
                     const std::optional<std::filesystem::path>& relative_path = std::nullopt,
                     std::stop_token stop = {},
                     ProgressHandler on_progress = {});

    // ---- writes ----------------------------------------------------------
    ProcessOutcome Checkout(const std::string& url,
                            const std::filesystem::path& destination,
                            std::stop_token stop = {},
                            ProgressHandler on_progress = {});

    ProcessOutcome Update(const std::filesystem::path& working_copy,
                          std::stop_token stop = {},
                          ProgressHandler on_progress = {});

    ProcessOutcome Add(const std::vector<std::filesystem::path>& paths,
                       std::stop_token stop = {},
                       ProgressHandler on_progress = {});

    // Destructive: requires an explicit confirmation from the caller (R3).
    ProcessOutcome Delete(const std::vector<std::filesystem::path>& paths,
                          bool force,
                          bool confirmed,
                          std::stop_token stop = {},
                          ProgressHandler on_progress = {});

    ProcessOutcome Commit(const std::vector<std::filesystem::path>& paths,
                          const std::string& message,
                          std::stop_token stop = {},
                          ProgressHandler on_progress = {});

    // Destructive: requires confirmation (R3).
    ProcessOutcome Revert(const std::vector<std::filesystem::path>& paths,
                          bool confirmed,
                          std::stop_token stop = {},
                          ProgressHandler on_progress = {});

    ProcessOutcome Cleanup(const std::filesystem::path& working_copy,
                           std::stop_token stop = {},
                           ProgressHandler on_progress = {});

    // `mine_full` / `theirs_full` / `base` discard one side of the merge and are
    // therefore destructive; only `working` is safe to call without confirmation.
    ProcessOutcome Resolve(const std::filesystem::path& path,
                           ResolveStrategy strategy,
                           bool confirmed,
                           std::stop_token stop = {},
                           ProgressHandler on_progress = {});

    // ---- diagnostics -----------------------------------------------------
    const std::filesystem::path& svn_executable() const { return svn_executable_; }

    // Maps a finished process to an SVNError, or leaves `error` empty on success.
    static std::optional<SVNError> Classify(const ProcessOutcome& outcome);

private:
    struct InvocationResult {
        ProcessOutcome outcome;
        std::optional<SVNError> error;
    };

    // Adds --non-interactive / --no-auth-cache, and the credential flags when a
    // credential is available for `remote_target`.
    std::vector<std::string> BaseArguments(const std::optional<std::string>& remote_target,
                                           std::string* password_on_stdin);

    InvocationResult Invoke(std::vector<std::string> arguments,
                            const std::filesystem::path& working_directory,
                            const std::optional<std::string>& remote_target,
                            std::stop_token stop,
                            OutputLineHandler on_line,
                            ProgressHandler on_progress);

    // Drops a stored credential after the server rejected it, so the next attempt
    // prompts instead of retrying a known-bad password forever.
    void ForgetCredential(const std::optional<std::string>& remote_target);

    // Writes run inside the working copy root, under that root's gate (R4).
    // Throws SVN-0003 when the paths are not inside a working copy.
    std::filesystem::path WorkingCopyRootFor(const std::vector<std::filesystem::path>& paths) const;

    std::filesystem::path svn_executable_;
    std::shared_ptr<CredentialStore> credentials_;
    std::chrono::milliseconds default_timeout_{std::chrono::minutes(10)};
    WorkingCopyGate gate_;
};

}  // namespace opensvn
