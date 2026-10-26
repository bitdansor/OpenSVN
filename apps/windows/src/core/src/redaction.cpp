#include "opensvn/redaction.hpp"

#include <regex>

namespace opensvn {

namespace {

struct Pattern {
    std::regex expression;
    const char* replacement;
};

const std::vector<Pattern>& patterns() {
    static const std::vector<Pattern> value = {
        {std::regex(R"(\b([a-z][a-z0-9+.\-]*://)([^/\s:@]+)(:[^/\s@]*)?@)",
                    std::regex::icase | std::regex::ECMAScript),
         "$1***@"},
        {std::regex(R"((--password[=\s]+)("[^"]*"|'[^']*'|\S+))",
                    std::regex::icase | std::regex::ECMAScript),
         "$1***"},
        {std::regex(R"(\b(password|passwd|passphrase|token|secret|api[_-]?key)=([^\s&;,"']+))",
                    std::regex::icase | std::regex::ECMAScript),
         "$1=***"},
        {std::regex(R"((authorization:\s*(basic|bearer|digest)\s+)\S+)",
                    std::regex::icase | std::regex::ECMAScript),
         "$1***"},
    };
    return value;
}

} // namespace

std::string LogRedactor::redact(std::string_view text) {
    if (text.empty()) return {};
    std::string result(text);
    for (const auto& pattern : patterns()) {
        result = std::regex_replace(result, pattern.expression, pattern.replacement);
    }
    return result;
}

std::string LogRedactor::redact(std::string_view text, const std::vector<std::string>& secrets) {
    std::string result = redact(text);
    for (const auto& secret : secrets) {
        if (secret.empty()) continue;
        std::size_t position = 0;
        while ((position = result.find(secret, position)) != std::string::npos) {
            result.replace(position, secret.size(), "***");
            position += 3;
        }
    }
    return result;
}

std::string LogRedactor::sanitized_url(std::string_view url) {
    static const std::regex userinfo(R"(^([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/@\s]*@)");
    return std::regex_replace(std::string(url), userinfo, "$1");
}

} // namespace opensvn
