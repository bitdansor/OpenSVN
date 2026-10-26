#pragma once

#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace opensvn::text {

std::wstring to_wide(std::string_view utf8);
std::string to_utf8(std::wstring_view wide);

/// UTF-8 view of a filesystem path. On Windows `path::string()` goes through
/// the ANSI code page and destroys non-ASCII text; this does not.
std::string path_to_utf8(const std::filesystem::path& path);
std::filesystem::path path_from_utf8(std::string_view utf8);

std::string trim(std::string_view text);
std::vector<std::string> split_lines(std::string_view text);
std::string lower_ascii(std::string_view text);
bool contains_ascii_case_insensitive(std::string_view haystack, std::string_view needle);

std::string random_uuid();
std::string random_suffix();

} // namespace opensvn::text
