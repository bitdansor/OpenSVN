#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace opensvn {

/// Scrubs credentials from anything that leaves the process boundary.
class LogRedactor {
public:
    static std::string redact(std::string_view text);
    static std::string redact(std::string_view text, const std::vector<std::string>& secrets);
    static std::string sanitized_url(std::string_view url);
};

} // namespace opensvn
