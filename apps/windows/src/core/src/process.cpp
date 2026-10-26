#include "opensvn/process.hpp"

#include "opensvn/errors.hpp"
#include "opensvn/redaction.hpp"
#include "opensvn/text.hpp"

#include <windows.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cstddef>
#include <cstdio>
#include <cwchar>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>

namespace opensvn {

namespace {

std::string windows_error_message(DWORD code) {
    wchar_t* buffer = nullptr;
    const DWORD length = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
    std::string message;
    if (length > 0 && buffer) {
        message = text::to_utf8(std::wstring_view(buffer, length));
        while (!message.empty() && (message.back() == '\n' || message.back() == '\r')) {
            message.pop_back();
        }
    }
    if (buffer) LocalFree(buffer);
    if (message.empty()) message = "Windows error " + std::to_string(code);
    return message;
}

struct PipeEnds {
    HANDLE read = nullptr;
    HANDLE write = nullptr;
};

bool create_inheritable_pipe(PipeEnds& ends) {
    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.bInheritHandle = TRUE;
    return CreatePipe(&ends.read, &ends.write, &attributes, 0) != FALSE;
}

void close_handle(HANDLE& handle) {
    if (handle && handle != INVALID_HANDLE_VALUE) {
        CloseHandle(handle);
        handle = nullptr;
    }
}

std::string describe_error_code(DWORD code) {
    const std::string message = windows_error_message(code);
    return " (Windows error " + std::to_string(code) + ": " + message + ")";
}

// Owns one Win32 handle. Everything that can fail after CreateProcessW is
// wrapped in RAII so an exception cannot strand a suspended child process.
struct Handle {
    HANDLE value = nullptr;

    Handle() = default;
    explicit Handle(HANDLE handle) noexcept : value(handle) {}
    ~Handle() { reset(); }

    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;

    Handle(Handle&& other) noexcept : value(other.release()) {}
    Handle& operator=(Handle&& other) noexcept {
        if (this != &other) reset(other.release());
        return *this;
    }

    HANDLE get() const noexcept { return value; }
    HANDLE release() noexcept {
        HANDLE handle = value;
        value = nullptr;
        return handle;
    }
    void reset(HANDLE handle = nullptr) noexcept {
        if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value);
        value = handle;
    }
};

// Joins every thread, including during stack unwinding. ProcessGuard is
// declared after this type, so the process is terminated before we join.
class ThreadGroup {
public:
    ThreadGroup() = default;
    ThreadGroup(const ThreadGroup&) = delete;
    ThreadGroup& operator=(const ThreadGroup&) = delete;
    ~ThreadGroup() { join_all(); }

    template <typename Function>
    void start(Function&& function) {
        threads_.emplace_back(std::forward<Function>(function));
    }

    void join_all() noexcept {
        for (auto& thread : threads_) {
            if (!thread.joinable()) continue;
            try {
                thread.join();
            } catch (...) {
                // A joinable std::thread must not reach its destructor.
                thread.detach();
            }
        }
        threads_.clear();
    }

private:
    std::vector<std::thread> threads_;
};

struct ProcessGuard {
    HANDLE process = nullptr;
    HANDLE thread = nullptr;
    HANDLE job = nullptr;
    bool job_assigned = false;
    bool running = false;

    ProcessGuard() = default;
    ProcessGuard(HANDLE process_handle, HANDLE thread_handle, HANDLE job_handle,
                 bool assigned, bool is_running)
        : process(process_handle),
          thread(thread_handle),
          job(job_handle),
          job_assigned(assigned),
          running(is_running) {}

    ProcessGuard(const ProcessGuard&) = delete;
    ProcessGuard& operator=(const ProcessGuard&) = delete;

    ~ProcessGuard() {
        if (running) {
            if (job_assigned && job) {
                TerminateJobObject(job, 1);
            } else if (process) {
                TerminateProcess(process, 1);
            }
            if (process) WaitForSingleObject(process, 5000);
        }
        if (job) CloseHandle(job);
        if (thread) CloseHandle(thread);
        if (process) CloseHandle(process);
    }
};

/// Reads a pipe without ever blocking indefinitely. `available` is the only
/// amount we ask for, so a descendant that inherited the write end cannot pin
/// this thread inside ReadFile after the job has been terminated.
void drain_pipe(HANDLE pipe, std::string& collected, std::size_t& total_bytes,
                const OutputLineCallback* on_line, std::size_t maximum_captured_bytes,
                bool& truncated, const std::atomic<bool>& stop_draining) {
    std::array<char, 8192> buffer{};
    std::string pending_line;

    for (;;) {
        DWORD available = 0;
        if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) break;

        if (available == 0) {
            if (stop_draining.load(std::memory_order_relaxed)) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
            continue;
        }

        const DWORD chunk =
            std::min<DWORD>(available, static_cast<DWORD>(buffer.size()));
        DWORD bytes_read = 0;
        if (!ReadFile(pipe, buffer.data(), chunk, &bytes_read, nullptr) || bytes_read == 0) {
            break;
        }
        total_bytes += bytes_read;

        if (maximum_captured_bytes == 0) {
            collected.append(buffer.data(), bytes_read);
        } else if (collected.size() < maximum_captured_bytes) {
            const std::size_t remaining =
                std::min<std::size_t>(maximum_captured_bytes - collected.size(), bytes_read);
            collected.append(buffer.data(), remaining);
            if (remaining < bytes_read) truncated = true;
        } else {
            truncated = true;
        }

        if (on_line == nullptr) continue;
        pending_line.append(buffer.data(), bytes_read);
        std::size_t start = 0;
        for (;;) {
            const std::size_t newline = pending_line.find('\n', start);
            if (newline == std::string::npos) break;
            std::string line = pending_line.substr(start, newline - start);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            try {
                (*on_line)(line);
            } catch (...) {
                // A progress consumer must not kill the pump.
            }
            start = newline + 1;
        }
        pending_line.erase(0, start);
    }
    if (on_line != nullptr && !pending_line.empty()) {
        try {
            (*on_line)(pending_line);
        } catch (...) {
        }
    }
}

} // namespace

ProcessRunner::ProcessRunner(std::filesystem::path executable,
                             std::map<std::string, std::string> environment,
                             std::optional<std::chrono::milliseconds> default_timeout)
    : executable_(std::move(executable)),
      default_timeout_(default_timeout) {
    static const std::array<const char*, 26> passthrough = {
        "PATH",          "PATHEXT",       "SystemRoot",    "TEMP",
        "TMP",           "USERPROFILE",   "APPDATA",       "LOCALAPPDATA",
        "HOMEDRIVE",     "HOMEPATH",      "COMSPEC",       "SSH_AUTH_SOCK",
        "SSL_CERT_FILE", "SSL_CERT_DIR",  "http_proxy",    "https_proxy",
        "no_proxy",      "HTTP_PROXY",    "HTTPS_PROXY",   "NO_PROXY",
        "USERNAME",      "USERDOMAIN",    "PROCESSOR_ARCHITECTURE",
        "WINDIR",        "PROGRAMFILES",  "PROGRAMDATA",
    };
    for (const char* key : passthrough) {
        const std::string wanted = text::lower_ascii(key);
        for (const auto& [name, value] : environment) {
            if (text::lower_ascii(name) == wanted && !value.empty()) {
                base_environment_[name] = value;
                break;
            }
        }
    }
    // Application-owned variables (tests, future deployment switches) are
    // deliberately passed through; they cannot carry user credentials.
    for (const auto& [name, value] : environment) {
        if (!value.empty() && text::lower_ascii(name).rfind("opensvn_", 0) == 0) {
            base_environment_[name] = value;
        }
    }
}

std::map<std::string, std::string> ProcessRunner::resolved_environment(
    const std::map<std::string, std::string>& extra) const {
    std::map<std::string, std::string> environment = base_environment_;
    // Locale is pinned so diagnostics and number formatting are stable, but it
    // must stay UTF-8: LC_ALL=C makes svn reject non-ASCII paths with E000022.
    environment["LC_ALL"] = "en_US.UTF-8";
    environment["LANG"] = "en_US.UTF-8";
    environment["LC_CTYPE"] = "en_US.UTF-8";
    for (const auto& [key, value] : extra) environment[key] = value;
    return environment;
}

std::string ProcessRunner::quote_argument(std::string_view argument) {
    if (argument.empty()) return "\"\"";
    const bool needs_quotes =
        argument.find_first_of(" \t\n\v\"") != std::string_view::npos;
    if (!needs_quotes) return std::string(argument);

    std::string result;
    result.reserve(argument.size() + 2);
    result.push_back('"');
    std::size_t backslashes = 0;
    for (const char c : argument) {
        if (c == '\\') {
            ++backslashes;
            continue;
        }
        if (c == '"') {
            result.append(backslashes * 2 + 1, '\\');
            result.push_back('"');
            backslashes = 0;
            continue;
        }
        result.append(backslashes, '\\');
        backslashes = 0;
        result.push_back(c);
    }
    result.append(backslashes * 2, '\\');
    result.push_back('"');
    return result;
}

std::string ProcessRunner::build_command_line(
    std::string_view executable, const std::vector<std::string>& arguments) {
    std::string command_line = quote_argument(executable);
    for (const auto& argument : arguments) {
        command_line.push_back(' ');
        command_line += quote_argument(argument);
    }
    return command_line;
}

std::map<std::string, std::string> ProcessRunner::current_environment() {
    std::map<std::string, std::string> result;
    LPWCH block = GetEnvironmentStringsW();
    if (!block) return result;
    for (const wchar_t* cursor = block; *cursor != L'\0'; cursor += std::wcslen(cursor) + 1) {
        const std::wstring entry(cursor);
        if (entry.empty() || entry.front() == L'=') continue;
        const std::size_t separator = entry.find(L'=');
        if (separator == std::wstring::npos) continue;
        result[text::to_utf8(entry.substr(0, separator))] =
            text::to_utf8(entry.substr(separator + 1));
    }
    FreeEnvironmentStringsW(block);
    return result;
}

std::filesystem::path ProcessRunner::current_executable_path() {
    std::wstring buffer(1024, L'\0');
    for (;;) {
        const DWORD length =
            GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (length == 0) return {};
        if (length < buffer.size()) {
            buffer.resize(length);
            return std::filesystem::path(buffer);
        }
        buffer.resize(buffer.size() * 2);
    }
}

ProcessResult ProcessRunner::run(const ProcessInvocation& invocation, std::stop_token stop,
                                 const OutputLineCallback& on_output_line) const {
    const auto started = std::chrono::steady_clock::now();
    ProcessResult result;

    std::error_code error_code;
    if (!std::filesystem::exists(executable_, error_code) ||
        !std::filesystem::is_regular_file(executable_, error_code)) {
        throw_svn_error(SVNErrorCode::svn_not_found,
                        "找不到可执行的 svn：" + text::path_to_utf8(executable_));
    }
    if (invocation.working_directory &&
        !std::filesystem::is_directory(*invocation.working_directory, error_code)) {
        throw_svn_error(SVNErrorCode::path_not_found,
                        "工作目录不存在：" + text::path_to_utf8(*invocation.working_directory));
    }
    if (stop.stop_requested()) {
        result.was_cancelled = true;
        return result;
    }

    // CreateProcessW sees the command line as a NUL-terminated string. An
    // embedded NUL would silently drop arguments, so reject it at the boundary.
    for (const auto& argument : invocation.arguments) {
        if (argument.find('\0') != std::string::npos) {
            throw_svn_error(SVNErrorCode::invalid_invocation, "参数包含非法 NUL 字符");
        }
    }
    if (executable_.native().find(L'\0') != std::wstring::npos ||
        (invocation.working_directory &&
         invocation.working_directory->native().find(L'\0') != std::wstring::npos)) {
        throw_svn_error(SVNErrorCode::invalid_invocation, "路径包含非法 NUL 字符");
    }

    const std::string command_line =
        build_command_line(text::path_to_utf8(executable_), invocation.arguments);
    const std::wstring wide_command_line = text::to_wide(command_line);
    std::vector<wchar_t> command_buffer(wide_command_line.begin(), wide_command_line.end());
    command_buffer.push_back(L'\0');

    std::optional<std::wstring> wide_working_directory;
    if (invocation.working_directory) {
        wide_working_directory = invocation.working_directory->native();
    }

    const auto environment = resolved_environment(invocation.environment);
    std::vector<std::wstring> environment_entries;
    environment_entries.reserve(environment.size());
    for (const auto& [key, value] : environment) {
        environment_entries.push_back(text::to_wide(key) + L"=" + text::to_wide(value));
    }
    std::sort(environment_entries.begin(), environment_entries.end(),
              [](const std::wstring& lhs, const std::wstring& rhs) {
                  return _wcsicmp(lhs.c_str(), rhs.c_str()) < 0;
              });
    std::vector<wchar_t> environment_block;
    for (const auto& entry : environment_entries) {
        environment_block.insert(environment_block.end(), entry.begin(), entry.end());
        environment_block.push_back(L'\0');
    }
    environment_block.push_back(L'\0');

    PipeEnds stdin_pipe;
    PipeEnds stdout_pipe;
    PipeEnds stderr_pipe;
    if (!create_inheritable_pipe(stdin_pipe) || !create_inheritable_pipe(stdout_pipe) ||
        !create_inheritable_pipe(stderr_pipe)) {
        const DWORD code = GetLastError();
        close_handle(stdin_pipe.read);
        close_handle(stdin_pipe.write);
        close_handle(stdout_pipe.read);
        close_handle(stdout_pipe.write);
        close_handle(stderr_pipe.read);
        close_handle(stderr_pipe.write);
        throw_svn_error(SVNErrorCode::command_failed,
                        "无法创建管道" + describe_error_code(code));
    }

    Handle stdin_read(stdin_pipe.read);
    Handle stdin_write(stdin_pipe.write);
    Handle stdout_read(stdout_pipe.read);
    Handle stdout_write(stdout_pipe.write);
    Handle stderr_read(stderr_pipe.read);
    Handle stderr_write(stderr_pipe.write);

    auto set_inherit = [](HANDLE handle, DWORD inherit) {
        if (!SetHandleInformation(handle, HANDLE_FLAG_INHERIT, inherit)) {
            throw_svn_error(SVNErrorCode::command_failed,
                            "无法配置管道句柄继承" + describe_error_code(GetLastError()));
        }
    };
    set_inherit(stdin_read.get(), HANDLE_FLAG_INHERIT);
    set_inherit(stdin_write.get(), 0);
    set_inherit(stdout_read.get(), 0);
    set_inherit(stdout_write.get(), HANDLE_FLAG_INHERIT);
    set_inherit(stderr_read.get(), 0);
    set_inherit(stderr_write.get(), HANDLE_FLAG_INHERIT);

    SIZE_T attribute_size = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_size);
    if (attribute_size == 0) {
        throw_svn_error(SVNErrorCode::command_failed,
                        "无法计算句柄继承属性大小" + describe_error_code(GetLastError()));
    }

    std::vector<std::byte> attribute_storage(attribute_size);
    auto* attributes =
        reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attribute_storage.data());
    if (!InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size)) {
        throw_svn_error(SVNErrorCode::command_failed,
                        "无法初始化句柄继承属性" + describe_error_code(GetLastError()));
    }

    struct AttributeListGuard {
        LPPROC_THREAD_ATTRIBUTE_LIST list;
        ~AttributeListGuard() {
            if (list) DeleteProcThreadAttributeList(list);
        }
    } attribute_guard{attributes};

    std::array<HANDLE, 3> inherited_handles = {
        stdin_read.get(), stdout_write.get(), stderr_write.get()};
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   inherited_handles.data(),
                                   sizeof(HANDLE) * inherited_handles.size(), nullptr,
                                   nullptr)) {
        throw_svn_error(SVNErrorCode::command_failed,
                        "无法限制子进程继承的句柄" + describe_error_code(GetLastError()));
    }

    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = stdin_read.get();
    startup.StartupInfo.hStdOutput = stdout_write.get();
    startup.StartupInfo.hStdError = stderr_write.get();
    startup.lpAttributeList = attributes;

    PROCESS_INFORMATION process_info{};
    const DWORD creation_flags = CREATE_SUSPENDED | CREATE_NO_WINDOW |
                                 CREATE_UNICODE_ENVIRONMENT |
                                 EXTENDED_STARTUPINFO_PRESENT;
    const BOOL created = CreateProcessW(
        executable_.native().c_str(), command_buffer.data(), nullptr, nullptr, TRUE,
        creation_flags, environment_block.data(),
        wide_working_directory ? wide_working_directory->c_str() : nullptr,
        &startup.StartupInfo, &process_info);

    if (!created) {
        const DWORD code = GetLastError();
        if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND) {
            throw_svn_error(SVNErrorCode::svn_not_found,
                            "无法启动 svn：" + text::path_to_utf8(executable_) +
                                describe_error_code(code));
        }
        throw_svn_error(SVNErrorCode::command_failed,
                        "无法启动 svn：" + text::path_to_utf8(executable_) +
                            describe_error_code(code));
    }

    // The parent no longer needs these three ends.
    stdin_read.reset();
    stdout_write.reset();
    stderr_write.reset();

    // Declaration order matters: ProcessGuard runs first and terminates the
    // job, then ThreadGroup joins, then the pipe owners close.
    ThreadGroup threads;
    ProcessGuard guard{process_info.hProcess, process_info.hThread, nullptr, false, true};

    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    if (!job) {
        throw_svn_error(SVNErrorCode::command_failed,
                        "无法创建 Job Object" + describe_error_code(GetLastError()));
    }
    guard.job = job;

    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                 sizeof(limits)) ||
        !AssignProcessToJobObject(job, process_info.hProcess)) {
        throw_svn_error(SVNErrorCode::command_failed,
                        "无法把 svn 加入 Job Object" + describe_error_code(GetLastError()));
    }
    guard.job_assigned = true;

    std::atomic<bool> stop_draining{false};
    // If anything below throws after the drain threads start, this sets the
    // flag before ProcessGuard terminates the process and ThreadGroup joins.
    struct DrainStopGuard {
        std::atomic<bool>& flag;
        ~DrainStopGuard() { flag.store(true, std::memory_order_relaxed); }
    } drain_stop_guard{stop_draining};
    std::string stdout_data;
    std::string stderr_data;
    std::size_t stdout_bytes = 0;
    std::size_t stderr_bytes = 0;
    bool stdout_truncated = false;
    bool stderr_truncated = false;

    try {
        threads.start([&] {
            drain_pipe(stdout_read.get(), stdout_data, stdout_bytes, &on_output_line,
                       invocation.maximum_captured_bytes, stdout_truncated, stop_draining);
        });
        threads.start([&] {
            drain_pipe(stderr_read.get(), stderr_data, stderr_bytes, nullptr,
                       invocation.maximum_captured_bytes, stderr_truncated, stop_draining);
        });
        threads.start([handle = std::move(stdin_write),
                       input = invocation.standard_input]() mutable {
            if (input && !input->empty()) {
                std::size_t offset = 0;
                while (offset < input->size()) {
                    DWORD written = 0;
                    const DWORD chunk = static_cast<DWORD>(
                        std::min<std::size_t>(input->size() - offset, 1 << 20));
                    if (!WriteFile(handle.get(), input->data() + offset, chunk, &written,
                                   nullptr) ||
                        written == 0) {
                        break;
                    }
                    offset += written;
                }
                SecureZeroMemory(input->data(), input->size());
            }
            handle.reset();
        });
    } catch (...) {
        stop_draining.store(true, std::memory_order_relaxed);
        // ProcessGuard and ThreadGroup clean up the suspended process and any
        // already-started threads.
        throw;
    }

    if (ResumeThread(process_info.hThread) == static_cast<DWORD>(-1)) {
        throw_svn_error(SVNErrorCode::command_failed,
                        "无法恢复 svn 进程" + describe_error_code(GetLastError()));
    }

    const auto timeout = invocation.timeout.value_or(
        default_timeout_.value_or(std::chrono::milliseconds{0}));
    bool process_exited = false;
    for (;;) {
        const DWORD wait = WaitForSingleObject(process_info.hProcess, 50);
        if (wait == WAIT_OBJECT_0) {
            process_exited = true;
            break;
        }
        if (wait == WAIT_FAILED) {
            throw_svn_error(SVNErrorCode::command_failed,
                            "等待 svn 进程失败" + describe_error_code(GetLastError()));
        }
        if (stop.stop_requested()) {
            result.was_cancelled = true;
            break;
        }
        if (timeout.count() > 0) {
            const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - started);
            if (elapsed >= timeout) {
                result.timed_out = true;
                break;
            }
        }
    }

    if (!process_exited) {
        if (guard.job_assigned && guard.job) {
            TerminateJobObject(guard.job, 1);
        } else {
            TerminateProcess(process_info.hProcess, 1);
        }
        if (WaitForSingleObject(process_info.hProcess, 5000) != WAIT_OBJECT_0) {
            throw_svn_error(SVNErrorCode::command_failed,
                            "无法终止 svn 进程" + describe_error_code(GetLastError()));
        }
    }

    DWORD exit_code = 0;
    if (!GetExitCodeProcess(process_info.hProcess, &exit_code)) {
        throw_svn_error(SVNErrorCode::command_failed,
                        "无法读取 svn 退出码" + describe_error_code(GetLastError()));
    }
    guard.running = false;

    // Close the job first: any descendant still holding a pipe write end dies,
    // which is what lets the drain threads reach EOF even on cancellation.
    if (guard.job) {
        CloseHandle(guard.job);
        guard.job = nullptr;
        guard.job_assigned = false;
    }
    stop_draining.store(true, std::memory_order_relaxed);
    threads.join_all();

    result.exit_code = static_cast<std::int32_t>(exit_code);
    result.standard_output = std::move(stdout_data);
    result.standard_output_bytes = stdout_bytes;
    result.standard_error = std::move(stderr_data);
    result.output_truncated = stdout_truncated || stderr_truncated;
    result.duration = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started);
    result.command_line = LogRedactor::redact(command_line);
    return result;
}

} // namespace opensvn
