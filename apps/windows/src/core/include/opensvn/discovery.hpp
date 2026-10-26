#pragma once

#include <chrono>
#include <filesystem>
#include <map>
#include <optional>
#include <stop_token>
#include <string>
#include <string_view>
#include <vector>

namespace opensvn {

struct SVNVersion {
    int major = 0;
    int minor = 0;
    int patch = 0;

    static std::optional<SVNVersion> parse(std::string_view text);
    std::string to_string() const;

    auto operator<=>(const SVNVersion&) const = default;
};

enum class SVNInstallationSource {
    explicit_path,
    bundled,
    search_path,
    well_known_location,
};

std::string_view to_string(SVNInstallationSource source);

struct SVNInstallation {
    std::filesystem::path executable;
    SVNVersion version;
    SVNInstallationSource source = SVNInstallationSource::search_path;
    std::string raw_version_output;
};

/// Resolves which `svn.exe` to use: explicit setting → bundled runtime → PATH →
/// well-known locations → a hard error. A GUI app must not depend on the shell
/// environment, so falling back silently is not allowed.
class SVNDiscovery {
public:
    struct Candidate {
        std::filesystem::path path;
        SVNInstallationSource source = SVNInstallationSource::search_path;
    };

    std::optional<std::filesystem::path> explicit_executable;
    std::vector<std::filesystem::path> bundled_candidates;
    std::map<std::string, std::string> environment;
    SVNVersion minimum_version{1, 10, 0};
    SVNVersion maximum_exclusive_version{2, 0, 0};
    std::chrono::milliseconds probe_timeout{15000};

    SVNDiscovery();
    explicit SVNDiscovery(std::map<std::string, std::string> environment);

    std::vector<Candidate> candidates() const;
    SVNInstallation resolve(std::stop_token stop = {}) const;
    SVNInstallation probe(const std::filesystem::path& executable,
                          SVNInstallationSource source,
                          std::stop_token stop = {}) const;
};

} // namespace opensvn
