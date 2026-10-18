// OpenSVN — service layer (Windows). NOT yet compiled on Windows; see
// apps/windows/README.md. Structure mirrors
// apps/macos/Sources/OpenSVNCore/Services/SVNService.swift so the two can be
// reviewed side by side.

#include "Services/SVNService.h"

#include <algorithm>
#include <cctype>
#include <stdexcept>

#include "Services/SVNXMLParser.h"

namespace opensvn {
namespace {

std::string WcKey(const std::filesystem::path& path) {
    std::error_code error;
    auto absolute = std::filesystem::weakly_canonical(path, error);
    if (error) {
        absolute = std::filesystem::absolute(path, error);
    }
    std::string key = absolute.generic_string();
    // Windows paths are case-insensitive; without normalising case, two spellings
    // of the same working copy would take two different locks.
    std::transform(key.begin(), key.end(), key.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return key;
}

// svn expects UTF-8 in argv. `path.string()` on Windows converts through the
// active code page and mangles non-ASCII names, so go through u8string.
std::string ToArgument(const std::filesystem::path& path) {
    const std::u8string utf8 = path.u8string();
    return std::string(reinterpret_cast<const char*>(utf8.data()), utf8.size());
}

bool Contains(std::string_view haystack, std::string_view needle) {
    return haystack.find(needle) != std::string_view::npos;
}

}  // namespace

// ---------------------------------------------------------------------------
// WorkingCopyGate
// ---------------------------------------------------------------------------
WorkingCopyGate::Guard WorkingCopyGate::Acquire(const std::filesystem::path& working_copy,
                                               std::stop_token stop) {
    const std::string key = WcKey(working_copy);
    std::unique_lock<std::mutex> lock(mutex_);
    // std::condition_variable_any supports the stop_token overload, which is why
    // this is not a plain condition_variable.
    condition_.wait(lock, stop, [&] {
        return std::find(holders_.begin(), holders_.end(), key) == holders_.end();
    });
    if (stop.stop_requested()) {
        SVNError error;
        error.code = SVNErrorCode::cancelled;
        error.message = "操作已取消";
        throw error;
    }
    holders_.push_back(key);
    return Guard(this, key);
}

bool WorkingCopyGate::IsBusy(const std::filesystem::path& working_copy) const {
    const std::string key = WcKey(working_copy);
    std::lock_guard<std::mutex> lock(mutex_);
    return std::find(holders_.begin(), holders_.end(), key) != holders_.end();
}

void WorkingCopyGate::Release(const std::string& key) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        holders_.erase(std::remove(holders_.begin(), holders_.end(), key), holders_.end());
    }
    condition_.notify_all();
}

std::optional<std::filesystem::path> FindWorkingCopyRoot(const std::filesystem::path& path) {
    std::error_code error;
    auto current = std::filesystem::absolute(path, error);
    if (error) {
        return std::nullopt;
    }
    if (std::filesystem::is_regular_file(current, error)) {
        current = current.parent_path();
    }
    while (!current.empty()) {
        if (std::filesystem::is_directory(current / L".svn", error)) {
            return current;
        }
        const auto parent = current.parent_path();
        if (parent == current) {
            break;
        }
        current = parent;
    }
    return std::nullopt;
}

// ---------------------------------------------------------------------------
// SVNService
// ---------------------------------------------------------------------------
SVNService::SVNService(std::filesystem::path svn_executable,
                       std::shared_ptr<CredentialStore> credentials)
    : svn_executable_(std::move(svn_executable)), credentials_(std::move(credentials)) {
    if (!credentials_) {
        throw std::invalid_argument("SVNService requires a CredentialStore");
    }
}

std::optional<SVNError> SVNService::Classify(const ProcessOutcome& outcome) {
    if (outcome.cancelled) {
        SVNError error;
        error.code = SVNErrorCode::cancelled;
        error.message = "操作已取消";
        return error;
    }
    if (outcome.timed_out) {
        SVNError error;
        error.code = SVNErrorCode::timeout;
        error.message = "操作超时";
        return error;
    }
    if (outcome.exit_code == 0) {
        return std::nullopt;
    }

    // Token table first, free-text second — same order as the macOS mapper, so
    // the same failure classifies identically on both platforms.
    struct Rule {
        std::string_view token;
        SVNErrorCode code;
    };
    static constexpr Rule kRules[] = {
        {"E155004", SVNErrorCode::workingCopyLocked},
        {"E155037", SVNErrorCode::notAWorkingCopy},
        {"E155007", SVNErrorCode::notAWorkingCopy},
        {"E200030", SVNErrorCode::workingCopyNeedsUpgrade},
        {"E170001", SVNErrorCode::authorizationFailed},
        {"E215004", SVNErrorCode::authenticationRequired},
        {"E170013", SVNErrorCode::networkFailure},
        {"E670002", SVNErrorCode::networkFailure},
        {"E160013", SVNErrorCode::pathNotFound},
        {"E155011", SVNErrorCode::outOfDate},
        {"E155015", SVNErrorCode::conflictRemains},
        {"E195020", SVNErrorCode::hostKeyVerificationFailed},
    };

    SVNError error;
    error.exit_code = static_cast<int>(outcome.exit_code);
    error.diagnostic_output = outcome.standard_error;
    error.message = "svn 执行失败";

    for (const auto& rule : kRules) {
        if (Contains(outcome.standard_error, rule.token)) {
            error.code = rule.code;
            error.svn_code = std::string(rule.token);
            break;
        }
    }

    if (error.svn_code.empty()) {
        if (Contains(outcome.standard_error, "Authentication failed") ||
            Contains(outcome.standard_error, "authorization failed")) {
            error.code = SVNErrorCode::authorizationFailed;
        } else if (Contains(outcome.standard_error, "is out of date")) {
            error.code = SVNErrorCode::outOfDate;
        } else if (Contains(outcome.standard_error, "remains in conflict")) {
            error.code = SVNErrorCode::conflictRemains;
        } else if (Contains(outcome.standard_error, "Unable to connect")) {
            error.code = SVNErrorCode::networkFailure;
        } else if (Contains(outcome.standard_error, "Working copy") &&
                   Contains(outcome.standard_error, "locked")) {
            error.code = SVNErrorCode::workingCopyLocked;
        } else {
            error.code = SVNErrorCode::commandFailed;
        }
    }
    return error;
}

std::vector<std::string> SVNService::BaseArguments(const std::optional<std::string>& remote_target,
                                                   std::string* password_on_stdin) {
    // --non-interactive: svn must never block waiting for a terminal prompt.
    // --no-auth-cache:    svn's own cache would be a second, uncontrolled store.
    std::vector<std::string> arguments = {"--non-interactive", "--no-auth-cache"};

    if (!remote_target) {
        return arguments;
    }
    const CredentialScope scope = CredentialScope::FromUrl(*remote_target);
    const auto credential = credentials_->Load(scope);
    if (!credential) {
        return arguments;
    }
    arguments.push_back("--username");
    arguments.push_back(credential->username);
    // Password goes on stdin. Never as an argument, never in the environment.
    arguments.push_back("--password-from-stdin");
    if (password_on_stdin) {
        *password_on_stdin = credential->password + "\n";
    }
    return arguments;
}

void SVNService::ForgetCredential(const std::optional<std::string>& remote_target) {
    // The storage key is the scope (host + realm), not the user name: forgetting
    // "the credential for this host" is what the user asked for.
    if (!remote_target) {
        return;
    }
    credentials_->Remove(CredentialScope::FromUrl(*remote_target));
}

std::filesystem::path SVNService::WorkingCopyRootFor(
    const std::vector<std::filesystem::path>& paths) const {
    if (paths.empty()) {
        SVNError error;
        error.code = SVNErrorCode::invalidInvocation;
        error.message = "未指定要操作的文件";
        throw error;
    }
    for (const auto& path : paths) {
        if (const auto root = FindWorkingCopyRoot(path)) {
            return *root;
        }
    }
    SVNError error;
    error.code = SVNErrorCode::notAWorkingCopy;
    error.message = "所选文件不在任何 SVN 工作副本内";
    throw error;
}

SVNService::InvocationResult SVNService::Invoke(std::vector<std::string> arguments,
                                               const std::filesystem::path& working_directory,
                                               const std::optional<std::string>& remote_target,
                                               std::stop_token stop,
                                               OutputLineHandler on_line,
                                               ProgressHandler on_progress) {
    std::string password;
    std::vector<std::string> with_auth = BaseArguments(remote_target, &password);
    with_auth.insert(with_auth.end(), arguments.begin(), arguments.end());

    SVNProcessRunner runner(svn_executable_);
    ProcessRequest request;
    request.executable = svn_executable_;
    request.working_directory = working_directory;
    request.arguments = std::move(with_auth);
    request.standard_input = password;  // empty when no credential is stored
    request.timeout = default_timeout_;

    InvocationResult result;
    result.outcome = runner.Run(request, stop, std::move(on_line), std::move(on_progress));
    result.error = Classify(result.outcome);

    // A credential the server rejected must not be reused: prompt, then retry.
    if (result.error &&
        (result.error->code == SVNErrorCode::authorizationFailed ||
         result.error->code == SVNErrorCode::authenticationRequired)) {
        ForgetCredential(remote_target);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------
StatusSnapshot SVNService::Status(const std::filesystem::path& working_copy,
                                  bool include_ignored,
                                  std::stop_token stop,
                                  OutputLineHandler on_line,
                                  ProgressHandler on_progress) {
    std::vector<std::string> arguments = {"status", "--xml"};
    if (include_ignored) {
        arguments.push_back("--no-ignore");
    }
    auto result = Invoke(std::move(arguments), working_copy, std::nullopt, stop,
                         std::move(on_line), std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return SVNXMLParser::ParseStatus(result.outcome.standard_output);
}

InfoReport SVNService::Info(const std::string& target, std::stop_token stop,
                            ProgressHandler on_progress) {
    auto result = Invoke({"info", "--xml", target}, std::filesystem::current_path(),
                         target.find("://") != std::string::npos ? std::optional<std::string>(target)
                                                                 : std::nullopt,
                         stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return SVNXMLParser::ParseInfo(result.outcome.standard_output);
}

LogPage SVNService::Log(const std::string& target, std::size_t limit, std::int64_t end_revision,
                        std::stop_token stop, ProgressHandler on_progress) {
    std::vector<std::string> arguments = {"log", "--xml", "-v", "-l", std::to_string(limit)};
    if (end_revision > 0) {
        arguments.push_back("-r");
        arguments.push_back(std::to_string(end_revision) + ":1");
    }
    auto result = Invoke(std::move(arguments), std::filesystem::current_path(),
                         target.find("://") != std::string::npos ? std::optional<std::string>(target)
                                                                 : std::nullopt,
                         stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return SVNXMLParser::ParseLog(result.outcome.standard_output, limit);
}

std::string SVNService::Diff(const std::filesystem::path& working_copy,
                             const std::optional<std::filesystem::path>& relative_path,
                             std::stop_token stop, ProgressHandler on_progress) {
    std::vector<std::string> arguments = {"diff"};
    if (relative_path) {
        arguments.push_back(ToArgument(*relative_path));
    }
    auto result = Invoke(std::move(arguments), working_copy, std::nullopt, stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return result.outcome.standard_output;
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------
ProcessOutcome SVNService::Checkout(const std::string& url, const std::filesystem::path& destination,
                                   std::stop_token stop, ProgressHandler on_progress) {
    // The destination's parent must exist; svn creates the leaf directory.
    if (!std::filesystem::exists(destination.parent_path())) {
        SVNError error;
        error.code = SVNErrorCode::pathNotFound;
        error.message = "目标目录的上级目录不存在：" + destination.parent_path().string();
        throw error;
    }
    auto result = Invoke({"checkout", url, ToArgument(destination)}, destination.parent_path(),
                         url, stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return result.outcome;
}

ProcessOutcome SVNService::Update(const std::filesystem::path& working_copy, std::stop_token stop,
                                  ProgressHandler on_progress) {
    auto gate = gate_.Acquire(working_copy, stop);
    auto result = Invoke({"update"}, working_copy, std::nullopt, stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return result.outcome;
}

ProcessOutcome SVNService::Add(const std::vector<std::filesystem::path>& paths, std::stop_token stop,
                               ProgressHandler on_progress) {
    const auto root = WorkingCopyRootFor(paths);
    auto gate = gate_.Acquire(root, stop);
    std::vector<std::string> arguments = {"add"};
    for (const auto& path : paths) {
        arguments.push_back(ToArgument(path));
    }
    auto result = Invoke(std::move(arguments), root, std::nullopt, stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return result.outcome;
}

ProcessOutcome SVNService::Delete(const std::vector<std::filesystem::path>& paths, bool force,
                                 bool confirmed, std::stop_token stop, ProgressHandler on_progress) {
    if (!confirmed) {
        SVNError error;
        error.code = SVNErrorCode::confirmationRequired;
        error.message = "删除会从工作副本中移除文件，必须确认后执行";
        throw error;
    }
    const auto root = WorkingCopyRootFor(paths);
    auto gate = gate_.Acquire(root, stop);
    std::vector<std::string> arguments = {"delete"};
    if (force) {
        arguments.push_back("--force");
    }
    for (const auto& path : paths) {
        arguments.push_back(ToArgument(path));
    }
    auto result = Invoke(std::move(arguments), root, std::nullopt, stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return result.outcome;
}

ProcessOutcome SVNService::Commit(const std::vector<std::filesystem::path>& paths,
                                 const std::string& message, std::stop_token stop,
                                 ProgressHandler on_progress) {
    if (message.empty()) {
        SVNError error;
        error.code = SVNErrorCode::invalidInvocation;
        error.message = "提交说明不能为空";
        throw error;
    }
    const auto root = WorkingCopyRootFor(paths);
    auto gate = gate_.Acquire(root, stop);
    std::vector<std::string> arguments = {"commit", "-m", message};
    for (const auto& path : paths) {
        arguments.push_back(ToArgument(path));
    }
    auto result = Invoke(std::move(arguments), root, std::nullopt, stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return result.outcome;
}

ProcessOutcome SVNService::Revert(const std::vector<std::filesystem::path>& paths, bool confirmed,
                                 std::stop_token stop, ProgressHandler on_progress) {
    if (!confirmed) {
        SVNError error;
        error.code = SVNErrorCode::confirmationRequired;
        error.message = "还原会丢弃未提交的本地修改，必须确认后执行";
        throw error;
    }
    const auto root = WorkingCopyRootFor(paths);
    auto gate = gate_.Acquire(root, stop);
    std::vector<std::string> arguments = {"revert"};
    for (const auto& path : paths) {
        arguments.push_back(ToArgument(path));
    }
    auto result = Invoke(std::move(arguments), root, std::nullopt, stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return result.outcome;
}

ProcessOutcome SVNService::Cleanup(const std::filesystem::path& working_copy, std::stop_token stop,
                                   ProgressHandler on_progress) {
    auto gate = gate_.Acquire(working_copy, stop);
    auto result = Invoke({"cleanup"}, working_copy, std::nullopt, stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return result.outcome;
}

ProcessOutcome SVNService::Resolve(const std::filesystem::path& path, ResolveStrategy strategy,
                                   bool confirmed, std::stop_token stop, ProgressHandler on_progress) {
    if (IsDestructive(strategy) && !confirmed) {
        SVNError error;
        error.code = SVNErrorCode::confirmationRequired;
        error.message = std::string("--accept=") + std::string(ToToken(strategy)) +
                        " 会丢弃一侧的改动，必须确认后执行";
        throw error;
    }
    const auto root = WorkingCopyRootFor({path});
    auto gate = gate_.Acquire(root, stop);
    std::vector<std::string> arguments = {"resolve", "--accept", std::string(ToToken(strategy)),
                                          ToArgument(path)};
    auto result = Invoke(std::move(arguments), root, std::nullopt, stop, {}, std::move(on_progress));
    if (result.error) {
        throw *result.error;
    }
    return result.outcome;
}

}  // namespace opensvn
