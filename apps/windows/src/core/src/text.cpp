#include "opensvn/text.hpp"

#include <windows.h>
#include <bcrypt.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <limits>
#include <random>
#include <stdexcept>
#include <vector>

namespace opensvn::text {

namespace {

bool fits_int(std::size_t value) {
    return value <= static_cast<std::size_t>(std::numeric_limits<int>::max());
}

} // namespace

std::wstring to_wide(std::string_view utf8) {
    if (utf8.empty()) return {};
    if (!fits_int(utf8.size())) {
        throw std::length_error("string is too long for UTF-16 conversion");
    }
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
    if (size <= 0) {
        // Paths produced by svn are valid UTF-8; a broken byte is still better
        // shown as a replacement than dropped.
        const int fallback = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                                 static_cast<int>(utf8.size()), nullptr, 0);
        std::wstring wide(static_cast<std::size_t>(fallback > 0 ? fallback : 0), L'\0');
        if (fallback > 0) {
            MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                                wide.data(), fallback);
        }
        return wide;
    }
    std::wstring wide(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                        static_cast<int>(utf8.size()), wide.data(), size);
    return wide;
}

std::string to_utf8(std::wstring_view wide) {
    if (wide.empty()) return {};
    if (!fits_int(wide.size())) {
        throw std::length_error("string is too long for UTF-8 conversion");
    }
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
                                         static_cast<int>(wide.size()), nullptr, 0, nullptr,
                                         nullptr);
    if (size <= 0) {
        const int fallback = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                                 static_cast<int>(wide.size()), nullptr, 0,
                                                 nullptr, nullptr);
        std::string utf8(static_cast<std::size_t>(fallback > 0 ? fallback : 0), '\0');
        if (fallback > 0) {
            WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                                utf8.data(), fallback, nullptr, nullptr);
        }
        return utf8;
    }
    std::string utf8(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
                        static_cast<int>(wide.size()), utf8.data(), size, nullptr, nullptr);
    return utf8;
}

std::string path_to_utf8(const std::filesystem::path& path) {
    return to_utf8(path.native());
}

std::filesystem::path path_from_utf8(std::string_view utf8) {
    return std::filesystem::path(to_wide(utf8));
}

std::string trim(std::string_view text) {
    std::size_t begin = 0;
    std::size_t end = text.size();
    const auto is_space = [](unsigned char c) {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
    };
    while (begin < end && is_space(static_cast<unsigned char>(text[begin]))) ++begin;
    while (end > begin && is_space(static_cast<unsigned char>(text[end - 1]))) --end;
    return std::string(text.substr(begin, end - begin));
}

std::vector<std::string> split_lines(std::string_view text) {
    std::vector<std::string> lines;
    std::size_t start = 0;
    while (start <= text.size()) {
        const std::size_t newline = text.find('\n', start);
        const std::size_t end = newline == std::string_view::npos ? text.size() : newline;
        std::string line(text.substr(start, end - start));
        if (!line.empty() && line.back() == '\r') line.pop_back();
        lines.push_back(std::move(line));
        if (newline == std::string_view::npos) break;
        start = newline + 1;
        if (start == text.size()) {
            lines.emplace_back();
            break;
        }
    }
    return lines;
}

std::string lower_ascii(std::string_view text) {
    std::string lowered(text);
    std::transform(lowered.begin(), lowered.end(), lowered.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return lowered;
}

bool contains_ascii_case_insensitive(std::string_view haystack, std::string_view needle) {
    if (needle.empty()) return true;
    const std::string lowered_haystack = lower_ascii(haystack);
    return lowered_haystack.find(lower_ascii(needle)) != std::string::npos;
}

namespace {

std::string random_hex(std::size_t bytes) {
    static constexpr char digits[] = "0123456789abcdef";
    std::vector<unsigned char> buffer(bytes);
    bool generated = false;
    if (!buffer.empty()) {
        generated = BCryptGenRandom(nullptr, buffer.data(),
                                    static_cast<ULONG>(buffer.size()),
                                    BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
    }
    if (!generated) {
        // UUIDs and temporary names are not secrets, but they must still be
        // unpredictable enough not to collide across concurrent processes.
        static thread_local std::mt19937_64 engine{std::random_device{}()};
        for (auto& value : buffer) {
            value = static_cast<unsigned char>(engine() & 0xFFu);
        }
    }
    std::string result;
    result.reserve(bytes * 2);
    for (const unsigned char value : buffer) {
        result.push_back(digits[value >> 4]);
        result.push_back(digits[value & 0x0Fu]);
    }
    return result;
}

} // namespace

std::string random_uuid() {
    std::string hex = random_hex(16);
    // Version 4, variant 1.
    hex[12] = '4';
    const char variant = static_cast<char>(std::stoi(hex.substr(16, 1), nullptr, 16));
    static constexpr char variant_digits[] = "89ab";
    hex[16] = variant_digits[variant & 0x3];
    return hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-" + hex.substr(12, 4) + "-" +
           hex.substr(16, 4) + "-" + hex.substr(20, 12);
}

std::string random_suffix() { return random_hex(8); }

} // namespace opensvn::text
