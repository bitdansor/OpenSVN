#pragma once

#include "opensvn/models.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace opensvn {

/// Parses the human-readable progress output of `svn update` / `svn commit`.
/// This is the only place non-XML output is read; decisions always come from
/// XML elsewhere.
class SVNOutputParser {
public:
    struct UpdateOutput {
        std::vector<std::string> updated;
        std::vector<std::string> added;
        std::vector<std::string> deleted;
        std::vector<std::string> conflicted;
        std::vector<std::string> merged;
    };

    struct CommitOutput {
        std::optional<std::int64_t> revision;
        std::vector<std::string> sending;
        std::vector<std::string> adding;
        std::vector<std::string> deleting;
        std::vector<std::string> replacing;

        bool committed() const { return revision.has_value(); }
    };

    static UpdateOutput parse_update(std::string_view output);
    static std::optional<std::int64_t> parse_updated_revision(std::string_view output);
    static CommitOutput parse_commit(std::string_view output);
    static bool is_up_to_date(std::string_view output);
};

} // namespace opensvn
