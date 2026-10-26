#include "opensvn/output_parser.hpp"

#include "opensvn/text.hpp"

#include <cctype>
#include <regex>
#include <unordered_map>
#include <vector>

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
    struct Flags {
        bool added = false;
        bool deleted = false;
        bool updated = false;
        bool merged = false;
        bool conflicted = false;
    };

    UpdateOutput result;
    std::unordered_map<std::string, std::size_t> positions;
    std::vector<std::pair<std::string, Flags>> entries;

    const auto is_column = [](char value, std::string_view allowed) {
        return value == ' ' || allowed.find(value) != std::string_view::npos;
    };

    for (const auto& line : text::split_lines(output)) {
        // svn's update notification is four status columns, one separator and
        // the path: "UC   file", " C   file", "   C file".
        if (line.size() < 6 || line[4] != ' ') continue;
        const char content = line[0];
        const char props = line[1];
        const char tree = line[3];
        if (!is_column(content, "ADUCGER") || !is_column(props, "CUG") ||
            !is_column(tree, "C")) {
            continue;
        }
        if (content == ' ' && props == ' ' && tree == ' ') continue;

        const std::string path = line.substr(5);
        if (path.empty()) continue;

        const auto found = positions.find(path);
        std::size_t index = 0;
        if (found == positions.end()) {
            index = entries.size();
            positions.emplace(path, index);
            entries.emplace_back(path, Flags{});
        } else {
            index = found->second;
        }
        Flags& flags = entries[index].second;

        switch (content) {
        case 'A': flags.added = true; break;
        case 'D': flags.deleted = true; break;
        case 'G': flags.merged = true; break;
        case 'C': flags.conflicted = true; break;
        case 'U':
        case 'E':
        case 'R': flags.updated = true; break;
        default: break;
        }
        if (props == 'U' || props == 'G') flags.updated = true;
        if (props == 'C' || tree == 'C') flags.conflicted = true;
    }

    for (const auto& [path, flags] : entries) {
        if (flags.conflicted) {
            result.conflicted.push_back(path);
        } else if (flags.merged) {
            result.merged.push_back(path);
        } else if (flags.added) {
            result.added.push_back(path);
        } else if (flags.deleted) {
            result.deleted.push_back(path);
        } else if (flags.updated) {
            result.updated.push_back(path);
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
