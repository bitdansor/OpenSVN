#include "opensvn/discovery.hpp"

#include "opensvn/error_mapper.hpp"
#include "opensvn/errors.hpp"
#include "opensvn/process.hpp"
#include "opensvn/text.hpp"

#include <algorithm>
#include <regex>
#include <set>

namespace opensvn {

namespace {

std::string lookup_environment(const std::map<std::string, std::string>& environment,
                               std::string_view key) {
    const std::string wanted = text::lower_ascii(key);
    for (const auto& [name, value] : environment) {
        if (text::lower_ascii(name) == wanted) return value;
    }
    return {};
}

std::filesystem::path svn_executable(const std::filesystem::path& directory) {
#ifdef _WIN32
    return directory / "svn.exe";
#else
    return directory / "svn";
#endif
}

} // namespace

std::optional<SVNVersion> SVNVersion::parse(std::string_view text) {
    static const std::regex expression(R"((\d+)\.(\d+)\.(\d+))");
    std::smatch match;
    const std::string input(text);
    if (!std::regex_search(input, match, expression)) return std::nullopt;
    try {
        return SVNVersion{std::stoi(match[1].str()), std::stoi(match[2].str()),
                          std::stoi(match[3].str())};
    } catch (...) {
        return std::nullopt;
    }
}

std::string SVNVersion::to_string() const {
    return std::to_string(major) + "." + std::to_string(minor) + "." +
           std::to_string(patch);
}

std::string_view to_string(SVNInstallationSource source) {
    switch (source) {
    case SVNInstallationSource::explicit_path: return "explicit";
    case SVNInstallationSource::bundled: return "bundled";
    case SVNInstallationSource::search_path: return "searchPath";
    case SVNInstallationSource::well_known_location: return "wellKnownLocation";
    }
    return "searchPath";
}

SVNDiscovery::SVNDiscovery() : environment(ProcessRunner::current_environment()) {
    const std::filesystem::path executable_directory =
        ProcessRunner::current_executable_path().parent_path();
    bundled_candidates = {
        svn_executable(executable_directory / "svn" / "bin"),
        svn_executable(executable_directory / "svn"),
        svn_executable(executable_directory.parent_path() / "Resources" / "svn" / "bin"),
    };
}

SVNDiscovery::SVNDiscovery(std::map<std::string, std::string> env)
    : environment(std::move(env)) {
    const std::filesystem::path executable_directory =
        ProcessRunner::current_executable_path().parent_path();
    bundled_candidates = {
        svn_executable(executable_directory / "svn" / "bin"),
        svn_executable(executable_directory / "svn"),
        svn_executable(executable_directory.parent_path() / "Resources" / "svn" / "bin"),
    };
}

std::vector<SVNDiscovery::Candidate> SVNDiscovery::candidates() const {
    if (explicit_executable && !explicit_executable->empty()) {
        return {{*explicit_executable, SVNInstallationSource::explicit_path}};
    }

    std::vector<Candidate> result;
    std::set<std::string> seen;
    const auto append = [&](const std::filesystem::path& path, SVNInstallationSource source) {
        if (path.empty()) return;
        std::string key = text::lower_ascii(text::path_to_utf8(path));
        std::replace(key.begin(), key.end(), '\\', '/');
        if (!seen.insert(key).second) return;
        result.push_back({path, source});
    };

    for (const auto& candidate : bundled_candidates) {
        append(candidate, SVNInstallationSource::bundled);
    }

    const std::string search_path = lookup_environment(environment, "PATH");
    std::size_t start = 0;
    while (start <= search_path.size()) {
        const std::size_t separator = search_path.find(';', start);
        const std::size_t end =
            separator == std::string::npos ? search_path.size() : separator;
        const std::string directory = text::trim(std::string_view(search_path).substr(start, end - start));
        if (!directory.empty()) {
            append(svn_executable(text::path_from_utf8(directory)),
                   SVNInstallationSource::search_path);
        }
        if (separator == std::string::npos) break;
        start = separator + 1;
    }

    const auto program_files = lookup_environment(environment, "ProgramFiles");
    const auto program_files_x86 = lookup_environment(environment, "ProgramFiles(x86)");
    const auto local_app_data = lookup_environment(environment, "LOCALAPPDATA");
    std::vector<std::filesystem::path> roots;
    for (const auto* value : {&program_files, &program_files_x86}) {
        if (!value->empty()) roots.push_back(text::path_from_utf8(*value));
    }
    for (const auto& root : roots) {
        append(svn_executable(root / "SlikSvn" / "bin"),
               SVNInstallationSource::well_known_location);
        append(svn_executable(root / "TortoiseSVN" / "bin"),
               SVNInstallationSource::well_known_location);
        append(svn_executable(root / "VisualSVN Server" / "bin"),
               SVNInstallationSource::well_known_location);
        append(svn_executable(root / "Subversion" / "bin"),
               SVNInstallationSource::well_known_location);
    }
    if (!local_app_data.empty()) {
        append(svn_executable(text::path_from_utf8(local_app_data) / "Programs" /
                              "TortoiseSVN" / "bin"),
               SVNInstallationSource::well_known_location);
    }
    return result;
}

SVNInstallation SVNDiscovery::resolve(std::stop_token stop) const {
    const auto candidates_list = candidates();
    std::vector<std::string> searched;
    std::optional<SVNError> best_failure;

    for (const auto& candidate : candidates_list) {
        if (stop.stop_requested()) {
            throw_svn_error(SVNErrorCode::cancelled, "操作已取消");
        }
        std::error_code error_code;
        if (!std::filesystem::is_regular_file(candidate.path, error_code)) {
            searched.push_back(text::path_to_utf8(candidate.path));
            continue;
        }
        try {
            return probe(candidate.path, candidate.source, stop);
        } catch (const SVNException& error) {
            if (error.error().code == SVNErrorCode::cancelled) throw;
            searched.push_back(text::path_to_utf8(candidate.path));
            if (candidate.source == SVNInstallationSource::explicit_path) throw;
            if (!best_failure) best_failure = error.error();
        }
    }

    if (best_failure && best_failure->code == SVNErrorCode::unsupported_version) {
        throw SVNException(*best_failure);
    }
    std::string diagnostic = "未检查任何候选路径";
    if (!searched.empty()) {
        diagnostic = "已检查：\n";
        for (const auto& path : searched) diagnostic += path + "\n";
    }
    throw_svn_error(SVNErrorCode::svn_not_found, "未找到可用的 svn 可执行文件", diagnostic);
}

SVNInstallation SVNDiscovery::probe(const std::filesystem::path& executable,
                                    SVNInstallationSource source,
                                    std::stop_token stop) const {
    ProcessRunner runner(executable, environment, probe_timeout);
    const ProcessInvocation invocation{{"--version", "--quiet"}, std::nullopt, std::nullopt, {},
                                       probe_timeout};
    const ProcessResult result = runner.run(invocation, stop);
    if (result.was_cancelled) {
        throw_svn_error(SVNErrorCode::cancelled, "操作已取消");
    }
    if (result.timed_out) {
        throw_svn_error(SVNErrorCode::timeout,
                        "探测 svn 超时（" +
                            std::to_string(probe_timeout.count() / 1000) + " 秒）");
    }
    if (!result.success()) {
        if (const auto error = SVNErrorMapper::error_from(result)) throw SVNException(*error);
        throw_svn_error(SVNErrorCode::svn_not_found,
                        "svn 探测失败：" + text::path_to_utf8(executable));
    }
    const auto version = SVNVersion::parse(result.standard_output);
    if (!version) {
        throw_svn_error(SVNErrorCode::unsupported_version,
                        "无法识别 svn 版本：" +
                            text::trim(result.standard_output),
                        result.standard_error);
    }
    if (*version < minimum_version || !(*version < maximum_exclusive_version)) {
        throw_svn_error(SVNErrorCode::unsupported_version,
                        "svn " + version->to_string() + " 不在支持区间（>= " +
                            minimum_version.to_string() + ", < " +
                            maximum_exclusive_version.to_string() + "）",
                        result.standard_output);
    }
    return SVNInstallation{executable, *version, source, result.standard_output};
}

} // namespace opensvn
