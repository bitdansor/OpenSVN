#pragma once

#include "opensvn/models.hpp"

#include <string_view>
#include <vector>

namespace opensvn::parsing {

/// All parsers are pure: the same bytes in produce the same model out, on any
/// machine. Non-XML output is never parsed here.
StatusSnapshot parse_status(std::string_view xml);
std::vector<LogEntry> parse_log(std::string_view xml);
InfoReport parse_info(std::string_view xml);
std::vector<PropertyTarget> parse_properties(std::string_view xml);
std::optional<ConflictArtifacts> parse_conflict_artifacts(std::string_view xml);

} // namespace opensvn::parsing
