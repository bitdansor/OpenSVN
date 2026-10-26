// Test double for svn.exe. It lets the process runner and service layer be
// exercised without a real Subversion installation: argv is logged verbatim,
// stdin is captured, and XML fixtures can be served from environment variables.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <fcntl.h>
#include <io.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace {

std::string to_utf8(std::wstring_view wide) {
    if (wide.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                                         nullptr, 0, nullptr, nullptr);
    std::string result(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), result.data(),
                        size, nullptr, nullptr);
    return result;
}

std::wstring to_wide(std::string_view utf8) {
    if (utf8.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
    std::wstring result(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), result.data(),
                        size);
    return result;
}

std::wstring environment(const wchar_t* name) {
    std::wstring buffer(32768, L'\0');
    const DWORD length =
        GetEnvironmentVariableW(name, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0 || length >= buffer.size()) return {};
    buffer.resize(length);
    return buffer;
}

int environment_int(const wchar_t* name, int fallback) {
    const std::wstring value = environment(name);
    if (value.empty()) return fallback;
    try {
        return std::stoi(value);
    } catch (...) {
        return fallback;
    }
}

std::string read_text_file(const std::wstring& path) {
    std::ifstream input(std::filesystem::path(path), std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(input)),
                       std::istreambuf_iterator<char>());
}

void append_log(std::wstring_view line) {
    const std::wstring log_path = environment(L"OPENSVN_FAKE_ARGV_LOG");
    if (log_path.empty()) return;
    std::ofstream log(std::filesystem::path(log_path),
                      std::ios::binary | std::ios::app);
    if (log) log << to_utf8(line) << "\n";
}

void append_argv(const std::vector<std::wstring>& arguments) {
    for (const auto& argument : arguments) {
        append_log(L"ARG|" + argument);
    }
}

bool has_argument(const std::vector<std::wstring>& arguments, const std::wstring& value) {
    for (const auto& argument : arguments) {
        if (argument == value) return true;
    }
    return false;
}

// Returns the first operand: everything after "--" when present, otherwise the
// argument that follows the subcommand.
std::wstring positional_operand(const std::vector<std::wstring>& arguments,
                                const std::wstring& command) {
    for (std::size_t index = 0; index + 1 < arguments.size(); ++index) {
        if (arguments[index] == L"--") return arguments[index + 1];
    }
    for (std::size_t index = 0; index + 1 < arguments.size(); ++index) {
        if (arguments[index] == command) return arguments[index + 1];
    }
    return {};
}

void write_stdout(std::string_view data) {
    std::cout.write(data.data(), static_cast<std::streamsize>(data.size()));
    std::cout.flush();
}

} // namespace

int wmain(int argc, wchar_t** argv) {
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);

    std::vector<std::wstring> arguments;
    for (int index = 1; index < argc; ++index) arguments.emplace_back(argv[index]);

    append_argv(arguments);

    if (has_argument(arguments, L"--password-from-stdin")) {
        std::string input((std::istreambuf_iterator<char>(std::cin)),
                          std::istreambuf_iterator<char>());
        while (!input.empty() && (input.back() == '\n' || input.back() == '\r')) {
            input.pop_back();
        }
        append_log(L"STDIN|" + to_wide(input));
    }

    if (!has_argument(arguments, L"--version")) {
        if (const int sleep_ms = environment_int(L"OPENSVN_FAKE_SLEEP_MS", 0); sleep_ms > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
        }
    } else {
        if (const int probe_sleep_ms = environment_int(L"OPENSVN_FAKE_PROBE_SLEEP_MS", 0);
            probe_sleep_ms > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(probe_sleep_ms));
        }
    }

    if (const std::wstring stderr_text = environment(L"OPENSVN_FAKE_STDERR");
        !stderr_text.empty()) {
        std::cerr << to_utf8(stderr_text);
    }

    if (has_argument(arguments, L"--version")) {
        std::wstring version = environment(L"OPENSVN_FAKE_VERSION");
        if (version.empty()) version = L"1.14.5";
        write_stdout(to_utf8(version) + "\n");
    } else if (has_argument(arguments, L"status")) {
        write_stdout(read_text_file(environment(L"OPENSVN_FAKE_STATUS_FILE")));
    } else if (has_argument(arguments, L"info")) {
        write_stdout(read_text_file(environment(L"OPENSVN_FAKE_INFO_FILE")));
    } else if (has_argument(arguments, L"log")) {
        write_stdout(read_text_file(environment(L"OPENSVN_FAKE_LOG_FILE")));
    } else if (has_argument(arguments, L"proplist")) {
        write_stdout(read_text_file(environment(L"OPENSVN_FAKE_PROPERTIES_FILE")));
    } else if (has_argument(arguments, L"diff")) {
        write_stdout(read_text_file(environment(L"OPENSVN_FAKE_DIFF_FILE")));
    } else if (has_argument(arguments, L"update")) {
        write_stdout("Updating '.':\n");
        if (const std::wstring extra = environment(L"OPENSVN_FAKE_UPDATE_OUTPUT");
            !extra.empty()) {
            write_stdout(to_utf8(extra) + "\n");
        }
    } else if (has_argument(arguments, L"commit")) {
        if (const int sleep_ms = environment_int(L"OPENSVN_FAKE_COMMIT_SLEEP_MS", 0);
            sleep_ms > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
        }
        std::wstring revision = environment(L"OPENSVN_FAKE_REVISION");
        if (revision.empty()) revision = L"7";
        write_stdout("Committed revision " + to_utf8(revision) + ".\n");
    } else if (has_argument(arguments, L"lock")) {
        const std::wstring path = positional_operand(arguments, L"lock");
        write_stdout("'" + to_utf8(path) + "' locked by user 'tester'.\n");
    } else if (has_argument(arguments, L"unlock")) {
        const std::wstring path = positional_operand(arguments, L"unlock");
        write_stdout("'" + to_utf8(path) + "' unlocked.\n");
    } else if (has_argument(arguments, L"resolve")) {
        if (const std::wstring write_path = environment(L"OPENSVN_FAKE_RESOLVE_WRITE");
            !write_path.empty()) {
            std::ofstream output(std::filesystem::path(write_path), std::ios::binary);
            output << to_utf8(environment(L"OPENSVN_FAKE_RESOLVE_TEXT"));
        }
    } else if (has_argument(arguments, L"propset") ||
               has_argument(arguments, L"propdel")) {
        if (const std::wstring log_path = environment(L"OPENSVN_FAKE_PROPERTY_LOG");
            !log_path.empty()) {
            std::ofstream log(std::filesystem::path(log_path),
                              std::ios::binary | std::ios::app);
            for (const auto& argument : arguments) log << to_utf8(argument) << "\n";
        }
        if (const std::wstring snapshot = environment(L"OPENSVN_FAKE_PROPERTY_SNAPSHOT");
            !snapshot.empty()) {
            for (std::size_t index = 0; index + 1 < arguments.size(); ++index) {
                if (arguments[index] == L"-F") {
                    const std::string value = read_text_file(arguments[index + 1]);
                    std::ofstream output(std::filesystem::path(snapshot),
                                         std::ios::binary | std::ios::trunc);
                    if (output) output << value;
                    break;
                }
            }
        }
    }

    if (const int large = environment_int(L"OPENSVN_FAKE_LARGE_BYTES", 0); large > 0) {
        std::string chunk(8192, 'x');
        int remaining = large;
        while (remaining > 0) {
            const int size = std::min(remaining, static_cast<int>(chunk.size()));
            write_stdout(std::string_view(chunk).substr(0, size));
            remaining -= size;
        }
    }

    int exit_code = environment_int(L"OPENSVN_FAKE_EXIT", 0);
    const std::wstring fail_on = environment(L"OPENSVN_FAKE_FAIL_ON");
    if (!fail_on.empty() && has_argument(arguments, fail_on)) {
        std::cerr << to_utf8(environment(L"OPENSVN_FAKE_FAIL_STDERR"));
        exit_code = 1;
    }
    return exit_code;
}
