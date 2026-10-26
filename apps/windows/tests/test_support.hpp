#pragma once

#include "opensvn/credentials.hpp"
#include "opensvn/journal.hpp"
#include "opensvn/process.hpp"
#include "opensvn/service.hpp"
#include "opensvn/text.hpp"

#include <gtest/gtest.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace opensvn::test {

inline std::filesystem::path fixtures_dir() {
    return std::filesystem::path(OPENSVN_FIXTURES_DIR);
}

inline std::filesystem::path fake_svn_path() {
    return std::filesystem::path(OPENSVN_FAKE_SVN_PATH);
}

inline std::string read_text(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot read " + text::path_to_utf8(path));
    return std::string((std::istreambuf_iterator<char>(input)),
                       std::istreambuf_iterator<char>());
}

inline std::string fixture(const std::string& name) {
    return read_text(fixtures_dir() / name);
}

inline void write_text(const std::filesystem::path& path, const std::string& content) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output) throw std::runtime_error("cannot write " + text::path_to_utf8(path));
    output.write(content.data(), static_cast<std::streamsize>(content.size()));
}

class TempDir {
public:
    TempDir() {
        path_ = std::filesystem::temp_directory_path() /
                ("opensvn-test-" + text::random_suffix());
        std::filesystem::create_directories(path_);
    }
    ~TempDir() {
        std::error_code error_code;
        std::filesystem::remove_all(path_, error_code);
    }
    TempDir(const TempDir&) = delete;
    TempDir& operator=(const TempDir&) = delete;

    const std::filesystem::path& path() const { return path_; }

private:
    std::filesystem::path path_;
};

inline std::shared_ptr<SVNService> make_fake_service(
    std::map<std::string, std::string> extra_environment = {},
    std::shared_ptr<CredentialStoring> credentials = nullptr,
    std::shared_ptr<OperationJournal> journal = nullptr,
    std::chrono::milliseconds timeout = std::chrono::seconds(10),
    std::optional<std::filesystem::path> backup_root = std::nullopt) {
    std::map<std::string, std::string> environment = ProcessRunner::current_environment();
    for (auto& [key, value] : extra_environment) environment[key] = value;

    SVNServiceConfiguration configuration;
    configuration.installation =
        SVNInstallation{fake_svn_path(), SVNVersion{1, 14, 5},
                        SVNInstallationSource::explicit_path, "1.14.5"};
    configuration.credentials =
        credentials ? std::move(credentials) : std::make_shared<InMemoryCredentialStore>();
    configuration.environment = std::move(environment);
    configuration.timeout = timeout;
    configuration.conflict_backup_root = std::move(backup_root);
    configuration.journal = std::move(journal);
    return std::make_shared<SVNService>(std::move(configuration));
}

inline std::map<std::string, std::string> fake_files(const std::string& status = "clean",
                                                     const std::string& info = "wl") {
    return {
        {"OPENSVN_FAKE_STATUS_FILE", text::path_to_utf8(fixtures_dir() /
                                                        ("svn-status-" + status + ".xml"))},
        {"OPENSVN_FAKE_INFO_FILE", text::path_to_utf8(fixtures_dir() /
                                                      (info == "wc" ? "svn-info-wc.xml"
                                                                    : "svn-info-url.xml"))},
        {"OPENSVN_FAKE_LOG_FILE", text::path_to_utf8(fixtures_dir() / "svn-log.xml")},
    };
}

inline std::vector<std::string> read_lines(const std::filesystem::path& path) {
    std::vector<std::string> lines;
    for (const auto& line : text::split_lines(read_text(path))) lines.push_back(line);
    return lines;
}

} // namespace opensvn::test
