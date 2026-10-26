#include "opensvn/output_parser.hpp"

#include "opensvn/text.hpp"

#include <cctype>
#include <regex>

namespace opensvn {

namespace {

bool starts_with_ascii_case_insensitive(std::string_view text, std::string_view prefix) {
    if (text.size() < prefix.size()) return false;
    for (std::size_t index = 0; index < prefix.size(); ++index) {
        const unsigned char lhs = static_cast<unsigned char>(text[index]);
        const unsigned char rhs = static_cast<unsigned char>(prefix[index]);
        if (std::tolower(lhs) != std::tolower(rhs)) return false;
    }
    return true;
}

} // namespace

SVNOutputParser::UpdateOutput SVNOutputParser::parse_update(std::string_view output) {
    UpdateOutput result;
    for (const auto& line : text::split_lines(output)) {
        if (line.empty()) continue;
        const char first = line.front();
        if (std::string_view("ADUCGER").find(first) == std::string_view::npos) continue;
        // "Updating '.':" also starts with U; real status lines have a padding
        // column after the letter.
        if (line.size() < 2 || (line[1] != ' ' && line[1] != '	')) continue;

        std::size_t position = 1;
        while (position < line.size() && line[position] == ' ') ++position;
        if (position >= line.size() || line[position] == '\'') continue;
        const std::string path = line.substr(position);

        switch (first) {
        case 'A': result.added.push_back(path); break;
        case 'D': result.deleted.push_back(path); break;
        case 'C': result.conflicted.push_back(path); break;
        case 'G': result.merged.push_back(path); break;
        case 'U':
        case 'E':
        case 'R': result.updated.push_back(path); break;
        default: break;
        }
    }
    return result;
}

std::optional<std::int64_t> SVNOutputParser::parse_updated_revision(std::string_view output) {
    static const std::regex expression(R"((updated to|at) revision (\d+))",
                                       std::regex::icase);
    std::smatch match;
    const std::string input(output);
    if (!std::regex_search(input, match, expression)) return std::nullopt;
    try {
        return std::stoll(match[2].str());
    } catch (...) {
        return std::nullopt;
    }
}

SVNOutputParser::CommitOutput SVNOutputParser::parse_commit(std::string_view output) {
    CommitOutput result;
    for (const auto& line : text::split_lines(output)) {
        if (line.empty()) continue;
        if (starts_with_ascii_case_insensitive(line, "committed revision")) {
            static const std::regex digits(R"(\d+)");
            std::smatch match;
            if (std::regex_search(line, match, digits)) {
                try {
                    result.revision = std::stoll(match[0].str());
                } catch (...) {
                }
            }
            continue;
        }
        static const std::pair<std::string_view, std::vector<std::string> CommitOutput::*> kinds[] = {
            {"sending ", &CommitOutput::sending},
            {"adding ", &CommitOutput::adding},
            {"deleting ", &CommitOutput::deleting},
            {"replacing ", &CommitOutput::replacing},
        };
        for (const auto& [prefix, member] : kinds) {
            if (starts_with_ascii_case_insensitive(line, prefix)) {
                (result.*member).push_back(text::trim(line.substr(prefix.size())));
                break;
            }
        }
    }
    return result;
}

bool SVNOutputParser::is_up_to_date(std::string_view output) {
    static const std::regex expression(R"(^(at|updated to) revision \d+\.?$)",
                                       std::regex::icase);
    for (const auto& line : text::split_lines(output)) {
        if (std::regex_match(text::trim(line), expression)) return true;
    }
    return false;
}

} // namespace opensvn
