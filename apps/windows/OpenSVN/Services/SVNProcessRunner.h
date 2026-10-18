// OpenSVN — subprocess execution (Windows implementation).
//
// Contract: specifications/svn-operations.md §"进程调用" and the red lines in
// CONTRIBUTING.md: R1 (argument array, never a shell string), R6 (async,
// cancellable, progress), R7 (machine-readable output).
//
// This header deliberately includes no Windows headers so that it can be
// included from portable code and syntax-checked on macOS. The implementation
// (SVNProcessRunner.cpp) is Windows-only.

#pragma once

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <stop_token>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "Models/SVNModels.h"

namespace opensvn {

struct ProcessRequest {
    // Absolute path to svn.exe. Resolved by SVNDiscovery, never a bare name:
    // resolving through PATH here would reintroduce the hijack risk R1 warns about.
    std::filesystem::path executable;

    // Arguments only — the program name is added by the runner. Each element is
    // passed through as one argv entry; nothing is ever concatenated into a
    // string that a shell would parse.
    std::vector<std::string> arguments;

    std::filesystem::path working_directory;

    // Extra environment variables on top of PinnedEnvironment(). Values are
    // UTF-8. Credentials must never be added here (R2).
    std::vector<std::pair<std::string, std::string>> extra_environment;

    // Written to the child's stdin, then the pipe is closed. Used for
    // `--password-from-stdin`; the password lives only in this buffer.
    std::string standard_input;

    // Zero means "no timeout". Anything longer than this is treated as a hang.
    std::chrono::milliseconds timeout{0};
};

struct ProcessOutcome {
    std::uint32_t exit_code = 0;
    std::string standard_output;
    std::string standard_error;
    bool timed_out = false;
    bool cancelled = false;
};

// Called for every complete line, in arrival order. `is_stderr` distinguishes
// the streams; ordering between them is not guaranteed and must not be relied on.
using OutputLineHandler = std::function<void(std::string_view line, bool is_stderr)>;

// Long-running operations report progress here. Returning false from the
// handler cancels the operation, the same way a cancel button does.
using ProgressHandler = std::function<bool(const TaskProgress& progress)>;

class SVNProcessRunner {
public:
    // `executable` must be an absolute path; the constructor throws
    // std::invalid_argument otherwise (programming error, not a user error).
    explicit SVNProcessRunner(std::filesystem::path executable);

    // Runs the child to completion. Never throws for child failures; inspect
    // `exit_code` and `standard_error`. Throws only for unrecoverable setup
    // problems (cannot create pipes / job object).
    ProcessOutcome Run(const ProcessRequest& request,
                       std::stop_token stop = {},
                       OutputLineHandler on_line = {},
                       ProgressHandler on_progress = {});

    const std::filesystem::path& executable() const { return executable_; }

    // The environment every child gets. Locale must stay UTF-8: under a legacy
    // code page svn rejects non-ASCII paths with E000022 (see compatibility.md).
    static std::vector<std::pair<std::string, std::string>> PinnedEnvironment();

    // Quotes one argv element using the CommandLineToArgvW rules, so that the
    // program sees exactly the bytes we passed. Exposed for unit testing —
    // quoting bugs are how "argument array" turns back into a shell string.
    static std::wstring QuoteArgument(const std::wstring& argument);

    // Full command line for CreateProcessW. Note this is a *string only because
    // the Win32 API requires one*; it is built from an array and never
    // interpreted by cmd.exe.
    static std::wstring BuildCommandLine(const std::wstring& program,
                                         const std::vector<std::wstring>& arguments);

private:
    std::filesystem::path executable_;
};

// UTF-8 <-> UTF-16 helpers. Windows APIs are wide-char; svn emits UTF-8 in the
// pinned locale, so every boundary has to convert explicitly.
std::string ToUtf8(std::wstring_view wide);
std::wstring ToWide(std::string_view utf8);

}  // namespace opensvn
