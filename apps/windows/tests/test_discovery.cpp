#include "opensvn/discovery.hpp"

#include "opensvn/errors.hpp"
#include "opensvn/process.hpp"
#include "test_support.hpp"

#include <gtest/gtest.h>

#include <chrono>
#include <thread>

namespace opensvn {
namespace {

std::map<std::string, std::string> environment_with(
    std::map<std::string, std::string> extra = {}) {
    std::map<std::string, std::string> environment = ProcessRunner::current_environment();
    for (auto& [key, value] : extra) environment[key] = value;
    return environment;
}

TEST(Discovery, ParsesSimpleAndVerboseVersions) {
    const auto simple = SVNVersion::parse("1.14.5");
    ASSERT_TRUE(simple.has_value());
    EXPECT_EQ(simple->to_string(), "1.14.5");

    const auto verbose = SVNVersion::parse("svn, version 1.14.5 (r1886195)");
    ASSERT_TRUE(verbose.has_value());
    EXPECT_EQ(verbose->minor, 14);
    EXPECT_FALSE(SVNVersion::parse("no version here").has_value());
    const SVNVersion old_version{1, 9, 0};
    const SVNVersion minimum{1, 10, 0};
    EXPECT_LT(old_version, minimum);
}

TEST(Discovery, ExplicitPathWinsAndValidatesTheVersion) {
    SVNDiscovery discovery(environment_with());
    discovery.explicit_executable = test::fake_svn_path();
    discovery.bundled_candidates.clear();
    const SVNInstallation installation = discovery.resolve();
    EXPECT_EQ(installation.source, SVNInstallationSource::explicit_path);
    EXPECT_EQ(installation.version.to_string(), "1.14.5");
}

TEST(Discovery, RejectsVersionsOutsideTheSupportedRange) {
    SVNDiscovery too_new(environment_with({{"OPENSVN_FAKE_VERSION", "2.0.0"}}));
    too_new.explicit_executable = test::fake_svn_path();
    try {
        too_new.resolve();
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::unsupported_version);
        EXPECT_EQ(error.error().identifier(), "SVN-0002");
    }

    SVNDiscovery too_old(environment_with({{"OPENSVN_FAKE_VERSION", "1.9.0"}}));
    too_old.explicit_executable = test::fake_svn_path();
    EXPECT_THROW(too_old.resolve(), SVNException);
}

TEST(Discovery, FindsSvnOnTheSearchPath) {
    test::TempDir temp;
    const auto svn = temp.path() / "svn.exe";
    std::filesystem::copy_file(test::fake_svn_path(), svn);

    SVNDiscovery discovery(environment_with({{"PATH", text::path_to_utf8(temp.path())}}));
    discovery.bundled_candidates.clear();
    const SVNInstallation installation = discovery.resolve();
    EXPECT_EQ(installation.source, SVNInstallationSource::search_path);
    EXPECT_EQ(std::filesystem::weakly_canonical(installation.executable),
              std::filesystem::weakly_canonical(svn));
}

TEST(Discovery, PrefersABundledRuntime) {
    test::TempDir temp;
    const auto bundled = temp.path() / "svn" / "bin" / "svn.exe";
    std::filesystem::create_directories(bundled.parent_path());
    std::filesystem::copy_file(test::fake_svn_path(), bundled);

    SVNDiscovery discovery(environment_with({{"PATH", ""}}));
    discovery.bundled_candidates = {bundled};
    const SVNInstallation installation = discovery.resolve();
    EXPECT_EQ(installation.source, SVNInstallationSource::bundled);
}

TEST(Discovery, MissingExplicitPathIsAnError) {
    SVNDiscovery discovery(environment_with());
    discovery.explicit_executable = std::filesystem::temp_directory_path() /
                                    "opensvn-missing-svn.exe";
    discovery.bundled_candidates.clear();
    try {
        discovery.resolve();
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::svn_not_found);
    }
}

TEST(Discovery, CandidateListIsDeduplicated) {
    SVNDiscovery discovery(environment_with({{"PATH", "C:\\tools;C:\\tools"}}));
    discovery.bundled_candidates.clear();
    const auto candidates = discovery.candidates();
    int count = 0;
    for (const auto& candidate : candidates) {
        if (text::lower_ascii(text::path_to_utf8(candidate.path)) == "c:/tools/svn.exe") {
            ++count;
        }
    }
    EXPECT_LE(count, 1);
}

TEST(Discovery, ARequestedStopAbortsTheSearch) {
    SVNDiscovery discovery(environment_with());
    discovery.explicit_executable = test::fake_svn_path();
    std::stop_source stop;
    stop.request_stop();
    try {
        discovery.resolve(stop.get_token());
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::cancelled);
    }
}

TEST(Discovery, CancellationDuringProbeIsReportedAsCancelled) {
    SVNDiscovery discovery(
        environment_with({{"OPENSVN_FAKE_PROBE_SLEEP_MS", "3000"}}));
    discovery.explicit_executable = test::fake_svn_path();
    std::stop_source stop;
    std::thread canceller([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        stop.request_stop();
    });
    try {
        discovery.resolve(stop.get_token());
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::cancelled);
    }
    canceller.join();
}

} // namespace
} // namespace opensvn
