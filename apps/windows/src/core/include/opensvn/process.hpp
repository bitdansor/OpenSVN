#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <optional>
#include <stop_token>
#include <string>
#include <string_view>
#include <vector>

namespace opensvn {

/// A fully-resolved process invocation. Arguments are always an array; nothing
/// here can be interpreted by a shell.
struct ProcessInvocation {
    std::vector<std::string> arguments;
    std::optional<std::filesystem::path> working_directory;
    /// Written to the child's stdin, then stdin is closed. Used for
    /// `--password-from-stdin` so the secret never reaches argv.
    std::optional<std::string> standard_input;
    /// Extra environment entries merged over the runner's whitelisted base.
    std::map<std::string, std::string> environment;
    std::optional<std::chrono::milliseconds> timeout;
    /// 0 means unlimited. Excess output is still drained (so the child cannot
    /// block on a full pipe) but is not retained.
    std::size_t maximum_captured_bytes = 0;
};

struct ProcessResult {
    std::int32_t exit_code = -1;
    std::string standard_output;
    std::size_t standard_output_bytes = 0;
    std::string standard_error;
    std::chrono::milliseconds duration{0};
    bool was_cancelled = false;
    bool timed_out = false;
    bool output_truncated = false;
    std::string command_line;

    bool success() const { return exit_code == 0 && !was_cancelled && !timed_out; }
};

using OutputLineCallback = std::function<void(std::string_view)>;

/// Runs a child process with the guarantees the spec calls non-negotiable:
/// argument-array launch (never a shell string), both pipes drained
/// concurrently, Job Object cancellation (svn's own children die with it),
/// enforced timeout, and an environment allow-list.
class ProcessRunner {
public:
    ProcessRunner(
        std::filesystem::path executable,
        std::map<std::string, std::string> environment = current_environment(),
        std::optional<std::chrono::milliseconds> default_timeout = std::chrono::seconds(300));

    /// Non-zero exit codes are returned, not thrown: the service classifies
    /// them. Launch failures throw `SVNException(svn_not_found)`.
    ProcessResult run(const ProcessInvocation& invocation,
                      std::stop_token stop = {}, const OutputLineCallback& on_output_line = {}) const;

    const std::filesystem::path& executable() const { return executable_; }

    std::map<std::string, std::string> resolved_environment(
        const std::map<std::string, std::string>& extra) const;

    static std::string quote_argument(std::string_view argument);
    static std::string build_command_line(std::string_view executable,
                                         const std::vector<std::string>& arguments);
    static std::map<std::string, std::string> current_environment();
    static std::filesystem::path current_executable_path();

private:
    std::filesystem::path executable_;
    std::map<std::string, std::string> base_environment_;
    std::optional<std::chrono::milliseconds> default_timeout_;
};

} // namespace opensvn
