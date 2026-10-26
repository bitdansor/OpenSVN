#pragma once

#include "opensvn/models.hpp"

#include <nlohmann/json.hpp>

#include <vector>

namespace opensvn {

/// Canonical JSON shapes used by the probe and by contract tests. Objects are
/// sorted by key (nlohmann::json uses std::map), arrays keep parse order, dates
/// are UTC ISO-8601 with milliseconds, and absent values are explicit nulls.
using Json = nlohmann::json;

Json lock_to_json(const RepositoryLock& lock);
Json status_to_json(const StatusSnapshot& snapshot);
Json log_to_json(const std::vector<LogEntry>& entries);
Json info_to_json(const InfoReport& report);
Json properties_to_json(const std::vector<PropertyTarget>& targets);
Json remote_preview_to_json(const RemotePreview& preview);

} // namespace opensvn
