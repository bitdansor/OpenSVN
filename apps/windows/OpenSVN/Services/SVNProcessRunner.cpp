// OpenSVN — Windows subprocess execution.
//
// Mirrors apps/macos/Sources/OpenSVNCore/Process/SVNProcessRunner.swift:
//   * argument array → command line is *built* by quoting, never assembled from
//     user-supplied fragments and never handed to cmd.exe (R1);
//   * both pipes are drained on their own threads, so a chatty child cannot
//     deadlock on a full 64 KB pipe;
//   * cancellation and timeout kill the whole process tree through a Job
//     Object, because `svn` may spawn children of its own;
//   * stdin is written on a thread and closed immediately, so a child that reads
//     stdin (--password-from-stdin) cannot block the parent.
//
// Status: written against the Win32 API, NOT yet compiled or run on Windows.
// Treat the first Windows build as part of the work, not as a formality — see
// apps/windows/README.md.

#include "SVNProcessRunner.h"

#include <windows.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace opensvn {
namespace {

// ---------------------------------------------------------------------------
// Small RAII wrapper. Every failure path below must close its handles, and the
// manual bookkeeping is exactly the kind of thing that leaks under exceptions.
// ---------------------------------------------------------------------------
class UniqueHandle {
public:
    UniqueHandle() = default;
    explicit UniqueHandle(HANDLE handle) : handle_(handle) {}
    ~UniqueHandle() { Reset(); }

    UniqueHandle(const UniqueHandle&) = delete;
    UniqueHandle& operator=(const UniqueHandle&) = delete;
    UniqueHandle(UniqueHandle&& other) noexcept : handle_(other.handle_) { other.handle_ = nullptr; }
    UniqueHandle& operator=(UniqueHandle&& other) noexcept {
        if (this != &other) {
            Reset();
            handle_ = other.handle_;
            other.handle_ = nullptr;
        }
        return *this;
    }

    HANDLE get() const { return handle_; }
    explicit operator bool() const { return handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE; }
    HANDLE Release() { HANDLE h = handle_; handle_ = nullptr; return h; }
    void Reset(HANDLE handle = nullptr) {
        if (handle_ && handle_ != INVALID_HANDLE_VALUE) {
            CloseHandle(handle_);
        }
        handle_ = handle;
    }

private:
    HANDLE handle_ = nullptr;
};

std::string LastErrorMessage(DWORD code) {
    return "Win32 error " + std::to_string(code);
}

struct PipeEnds {
    UniqueHandle parent;  // kept by us, must not be inherited
    UniqueHandle child;   // inherited by the child
};

// `child_writes == true` for stdout/stderr (child writes, we read),
// `false` for stdin (child reads, we write).
PipeEnds MakePipe(bool child_writes) {
    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.bInheritHandle = TRUE;

    HANDLE read_end = nullptr;
    HANDLE write_end = nullptr;
    if (!CreatePipe(&read_end, &write_end, &attributes, 0)) {
        throw std::runtime_error("CreatePipe failed: " + LastErrorMessage(GetLastError()));
    }
    UniqueHandle reader(read_end);
    UniqueHandle writer(write_end);

    if (child_writes) {
        // We keep the read end: it must not leak into the child, otherwise the
        // pipe never reports EOF and the drain thread hangs forever.
        if (!SetHandleInformation(reader.get(), HANDLE_FLAG_INHERIT, 0)) {
            throw std::runtime_error("SetHandleInformation failed: " + LastErrorMessage(GetLastError()));
        }
        return PipeEnds{std::move(reader), std::move(writer)};
    }

    if (!SetHandleInformation(writer.get(), HANDLE_FLAG_INHERIT, 0)) {
        throw std::runtime_error("SetHandleInformation failed: " + LastErrorMessage(GetLastError()));
    }
    return PipeEnds{std::move(writer), std::move(reader)};
}

// Windows wants a UTF-16 block of `KEY=VALUE\0...\0\0`.
std::wstring BuildEnvironmentBlock(const std::vector<std::pair<std::string, std::string>>& variables) {
    std::wstring block;
    for (const auto& [key, value] : variables) {
        block += ToWide(key);
        block += L'=';
        block += ToWide(value);
        block += L'\0';
    }
    block += L'\0';
    return block;
}

// One reader thread per stream: accumulate everything, and hand complete lines
// to the caller. `on_line` is shared between the two threads, so calls are
// serialised — callers must not have to think about threading.
void DrainPipe(HANDLE pipe,
               std::string* sink,
               bool is_stderr,
               OutputLineHandler* on_line,
               std::mutex* line_mutex,
               std::atomic<long long>* byte_counter) {
    std::array<char, 64 * 1024> buffer{};
    std::string pending;
    DWORD bytes_read = 0;

    while (ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()), &bytes_read, nullptr) &&
           bytes_read > 0) {
        sink->append(buffer.data(), bytes_read);
        byte_counter->fetch_add(bytes_read, std::memory_order_relaxed);

        if (on_line && *on_line) {
            pending.append(buffer.data(), bytes_read);
            std::size_t newline = 0;
            while ((newline = pending.find('\n')) != std::string::npos) {
                std::string line = pending.substr(0, newline);
                pending.erase(0, newline + 1);
                if (!line.empty() && line.back() == '\r') {
                    line.pop_back();
                }
                std::lock_guard<std::mutex> guard(*line_mutex);
                (*on_line)(line, is_stderr);
            }
        }
    }
    // ERROR_BROKEN_PIPE is the normal EOF signal here; anything else is not
    // worth throwing from a background thread — the exit code will show it.

    if (on_line && *on_line && !pending.empty()) {
        std::lock_guard<std::mutex> guard(*line_mutex);
        (*on_line)(pending, is_stderr);
    }
}

void WriteAllAndClose(HANDLE pipe, const std::string& payload) {
    std::size_t offset = 0;
    while (offset < payload.size()) {
        DWORD written = 0;
        const DWORD chunk = static_cast<DWORD>(std::min<std::size_t>(payload.size() - offset, 32 * 1024));
        if (!WriteFile(pipe, payload.data() + offset, chunk, &written, nullptr)) {
            // A child that exits before reading stdin closes the pipe; on
            // Windows that surfaces as ERROR_NO_DATA / ERROR_BROKEN_PIPE. It is
            // not an error worth failing the whole operation over.
            break;
        }
        offset += written;
    }
    CloseHandle(pipe);
}

}  // namespace

// ---------------------------------------------------------------------------
// Conversion helpers
// ---------------------------------------------------------------------------
std::string ToUtf8(std::wstring_view wide) {
    if (wide.empty()) {
        return {};
    }
    const int needed = WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                                           nullptr, 0, nullptr, nullptr);
    if (needed <= 0) {
        return {};
    }
    std::string result(static_cast<std::size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        result.data(), needed, nullptr, nullptr);
    return result;
}

std::wstring ToWide(std::string_view utf8) {
    if (utf8.empty()) {
        return {};
    }
    const int needed = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    if (needed <= 0) {
        return {};
    }
    std::wstring result(static_cast<std::size_t>(needed), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), result.data(), needed);
    return result;
}

// ---------------------------------------------------------------------------
// Command line construction (R1)
// ---------------------------------------------------------------------------
std::wstring SVNProcessRunner::QuoteArgument(const std::wstring& argument) {
    if (argument.find(L'\0') != std::wstring::npos) {
        throw std::invalid_argument("argument contains an embedded NUL");
    }

    const bool needs_quotes = argument.empty() ||
                              argument.find_first_of(L" \t\n\v\"") != std::wstring::npos;
    if (!needs_quotes) {
        return argument;
    }

    // Documented under "Parsing C++ command-line arguments": quote, then double
    // the backslashes that precede a quote or the closing quote.
    std::wstring quoted;
    quoted.reserve(argument.size() + 2);
    quoted.push_back(L'"');

    std::size_t backslashes = 0;
    for (const wchar_t character : argument) {
        if (character == L'\\') {
            ++backslashes;
            continue;
        }
        if (character == L'"') {
            quoted.append(backslashes * 2 + 1, L'\\');
            quoted.push_back(L'"');
            backslashes = 0;
            continue;
        }
        quoted.append(backslashes, L'\\');
        backslashes = 0;
        quoted.push_back(character);
    }
    quoted.append(backslashes * 2, L'\\');
    quoted.push_back(L'"');
    return quoted;
}

std::wstring SVNProcessRunner::BuildCommandLine(const std::wstring& program,
                                                const std::vector<std::wstring>& arguments) {
    std::wstring line = QuoteArgument(program);
    for (const auto& argument : arguments) {
        line.push_back(L' ');
        line += QuoteArgument(argument);
    }
    return line;
}

std::vector<std::pair<std::string, std::string>> SVNProcessRunner::PinnedEnvironment() {
    // Keep in sync with SVNProcessRunner.pinnedEnvironment on macOS and with
    // specifications/compatibility.md. A legacy code page breaks non-ASCII paths.
    return {
        {"LC_ALL", "en_US.UTF-8"},
        {"LANG", "en_US.UTF-8"},
        {"LC_CTYPE", "en_US.UTF-8"},
    };
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------
SVNProcessRunner::SVNProcessRunner(std::filesystem::path executable) : executable_(std::move(executable)) {
    if (!executable_.is_absolute()) {
        // Resolving through PATH would let a stray svn.exe win; discovery is
        // responsible for finding an absolute path (R1).
        throw std::invalid_argument("SVNProcessRunner requires an absolute executable path");
    }
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------
ProcessOutcome SVNProcessRunner::Run(const ProcessRequest& request,
                                     std::stop_token stop,
                                     OutputLineHandler on_line,
                                     ProgressHandler on_progress) {
    if (!std::filesystem::exists(request.working_directory)) {
        throw std::invalid_argument("working directory does not exist: " +
                                    request.working_directory.string());
    }
    if (!std::filesystem::exists(executable_)) {
        throw std::invalid_argument("executable does not exist: " + executable_.string());
    }

    PipeEnds stdout_pipe = MakePipe(/*child_writes=*/true);
    PipeEnds stderr_pipe = MakePipe(/*child_writes=*/true);
    PipeEnds stdin_pipe = MakePipe(/*child_writes=*/false);

    // Job object first: if the app dies, the job closes and takes the children
    // with it, which is the only reliable way to avoid orphaned svn processes.
    UniqueHandle job(CreateJobObjectW(nullptr, nullptr));
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job.get(), JobObjectExtendedLimitInformation, &limits, sizeof(limits));
    }

    std::vector<std::pair<std::string, std::string>> environment = PinnedEnvironment();
    for (const auto& extra : request.extra_environment) {
        environment.push_back(extra);
    }
    std::wstring environment_block = BuildEnvironmentBlock(environment);

    std::vector<std::wstring> wide_arguments;
    wide_arguments.reserve(request.arguments.size());
    for (const auto& argument : request.arguments) {
        wide_arguments.push_back(ToWide(argument));
    }
    std::wstring command_line = BuildCommandLine(executable_.wstring(), wide_arguments);

    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = stdin_pipe.child.get();
    startup.StartupInfo.hStdOutput = stdout_pipe.child.get();
    startup.StartupInfo.hStdError = stderr_pipe.child.get();

    // Restrict inheritance to exactly these three handles. Without the list,
    // bInheritHandles=TRUE leaks every inheritable handle the app owns.
    HANDLE inherited[] = {stdin_pipe.child.get(), stdout_pipe.child.get(), stderr_pipe.child.get()};
    SIZE_T attribute_size = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_size);
    std::vector<std::byte> attribute_storage(attribute_size);
    auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attribute_storage.data());
    if (!InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size)) {
        throw std::runtime_error("InitializeProcThreadAttributeList failed: " +
                                 LastErrorMessage(GetLastError()));
    }
    UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited,
                              sizeof(inherited), nullptr, nullptr);
    startup.lpAttributeList = attributes;

    PROCESS_INFORMATION process{};
    const std::wstring working_directory = request.working_directory.wstring();
    const DWORD flags = CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT;

    const BOOL created = CreateProcessW(
        /*applicationName=*/executable_.c_str(),
        command_line.data(),  // CreateProcessW may modify this buffer
        nullptr, nullptr,
        /*inheritHandles=*/TRUE,
        flags,
        environment_block.data(),
        working_directory.c_str(),
        &startup.StartupInfo,
        &process);

    DeleteProcThreadAttributeList(attributes);

    if (!created) {
        throw std::runtime_error("CreateProcessW failed for " + executable_.string() + ": " +
                                 LastErrorMessage(GetLastError()));
    }

    UniqueHandle process_handle(process.hProcess);
    UniqueHandle thread_handle(process.hThread);
    if (job) {
        AssignProcessToJobObject(job.get(), process_handle.get());
    }

    // Close our copies of the child's ends, otherwise the pipes never reach EOF.
    stdin_pipe.child.Reset();
    stdout_pipe.child.Reset();
    stderr_pipe.child.Reset();

    std::string standard_output;
    std::string standard_error;
    std::atomic<long long> bytes_written_out{0};
    std::atomic<long long> bytes_written_err{0};
    std::mutex line_mutex;

    std::thread stdout_reader(DrainPipe, stdout_pipe.parent.get(), &standard_output, false, &on_line,
                              &line_mutex, &bytes_written_out);
    std::thread stderr_reader(DrainPipe, stderr_pipe.parent.get(), &standard_error, true, &on_line,
                              &line_mutex, &bytes_written_err);

    std::thread stdin_writer;
    if (!request.standard_input.empty()) {
        HANDLE write_end = stdin_pipe.parent.Release();
        const std::string payload = request.standard_input;
        stdin_writer = std::thread(WriteAllAndClose, write_end, std::cref(payload));
    } else {
        stdin_pipe.parent.Reset();  // immediate EOF
    }

    ProcessOutcome outcome;
    const auto started = std::chrono::steady_clock::now();
    const bool has_deadline = request.timeout.count() > 0;

    for (;;) {
        if (stop.stop_requested()) {
            outcome.cancelled = true;
            break;
        }
        if (has_deadline && std::chrono::steady_clock::now() - started >= request.timeout) {
            outcome.timed_out = true;
            break;
        }

        const DWORD wait = WaitForSingleObject(process_handle.get(), 50);
        if (wait == WAIT_OBJECT_0) {
            break;
        }
        if (wait == WAIT_FAILED) {
            outcome.exit_code = static_cast<std::uint32_t>(-1);
            break;
        }

        if (on_progress) {
            TaskProgress progress;
            progress.operation = "svn";
            progress.detail = std::string(executable_.filename().string());
            progress.bytes_done = bytes_written_out.load(std::memory_order_relaxed) +
                                  bytes_written_err.load(std::memory_order_relaxed);
            if (!on_progress(progress)) {
                outcome.cancelled = true;
                break;
            }
        }
    }

    if (outcome.cancelled || outcome.timed_out) {
        // Kill the tree, not just the direct child: svn may have spawned
        // helpers, and leaving them behind leaves the working copy locked.
        if (job) {
            TerminateJobObject(job.get(), 1);
        } else {
            TerminateProcess(process_handle.get(), 1);
        }
        WaitForSingleObject(process_handle.get(), 5000);
    }

    if (stdin_writer.joinable()) {
        stdin_writer.join();
    }
    stdout_reader.join();
    stderr_reader.join();

    if (!outcome.cancelled && !outcome.timed_out) {
        DWORD exit_code = 0;
        if (GetExitCodeProcess(process_handle.get(), &exit_code)) {
            outcome.exit_code = static_cast<std::uint32_t>(exit_code);
        }
    }

    outcome.standard_output = std::move(standard_output);
    outcome.standard_error = std::move(standard_error);
    return outcome;
}

}  // namespace opensvn
