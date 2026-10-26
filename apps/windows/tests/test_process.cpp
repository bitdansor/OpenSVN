#include "opensvn/process.hpp"

#include "opensvn/errors.hpp"
#include "test_support.hpp"

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <stop_token>
#include <thread>

namespace opensvn {
namespace {

ProcessRunner fake_runner(std::chrono::milliseconds timeout = std::chrono::seconds(20)) {
    return ProcessRunner(test::fake_svn_path(), ProcessRunner::current_environment(), timeout);
}

ProcessInvocation invocation_with_log(const std::filesystem::path& log,
                                      std::vector<std::string> arguments) {
    ProcessInvocation invocation;
    invocation.arguments = std::move(arguments);
    invocation.environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log);
    return invocation;
}

TEST(CommandLine, QuotesArgumentsWithoutAShell) {
    EXPECT_EQ(ProcessRunner::quote_argument(""), "\"\"");
    EXPECT_EQ(ProcessRunner::quote_argument("plain"), "plain");
    EXPECT_EQ(ProcessRunner::quote_argument("with space"), "\"with space\"");
    EXPECT_EQ(ProcessRunner::quote_argument("a\"b"), "\"a\\\"b\"");
    // A backslash alone is not special; only quotes and whitespace force quoting.
    EXPECT_EQ(ProcessRunner::quote_argument("trailing\\"), "trailing\\");
}

TEST(ProcessRunner, ProbesVersion) {
    const ProcessResult result = fake_runner().run(ProcessInvocation{{"--version", "--quiet"}});
    ASSERT_TRUE(result.success());
    EXPECT_EQ(result.exit_code, 0);
    EXPECT_EQ(result.standard_output, "1.14.5\n");
}

TEST(ProcessRunner, PassesArgumentsVerbatimIncludingSpacesQuotesAndUnicode) {
    test::TempDir temp;
    const auto log = temp.path() / "argv.log";
    const std::vector<std::string> arguments = {
        "status", "--xml", "C:\\工作 副本\\a b.txt", "quote\"inside", "back\\slash\\"};
    const ProcessResult result =
        fake_runner().run(invocation_with_log(log, arguments));
    ASSERT_TRUE(result.success());

    const auto lines = test::read_lines(log);
    ASSERT_GE(lines.size(), arguments.size());
    for (std::size_t index = 0; index < arguments.size(); ++index) {
        EXPECT_EQ(lines[index], "ARG|" + arguments[index]);
    }
}

TEST(ProcessRunner, SendsStandardInputAndClosesStdin) {
    test::TempDir temp;
    const auto log = temp.path() / "argv.log";
    ProcessInvocation invocation =
        invocation_with_log(log, {"commit", "--password-from-stdin"});
    invocation.standard_input = "s3cret\n";
    const ProcessResult result = fake_runner().run(invocation);
    ASSERT_TRUE(result.success());

    const auto lines = test::read_lines(log);
    const bool has_stdin = std::any_of(lines.begin(), lines.end(), [](const std::string& line) {
        return line == "STDIN|s3cret";
    });
    EXPECT_TRUE(has_stdin);
}

TEST(ProcessRunner, ReturnsNonZeroExitAndCapturesStderr) {
    ProcessInvocation invocation{{"status"}};
    invocation.environment["OPENSVN_FAKE_EXIT"] = "3";
    invocation.environment["OPENSVN_FAKE_STDERR"] = "boom\n";
    const ProcessResult result = fake_runner().run(invocation);
    EXPECT_EQ(result.exit_code, 3);
    EXPECT_EQ(result.standard_error, "boom\n");
    EXPECT_FALSE(result.success());
}

TEST(ProcessRunner, TimesOutAndKillsTheJob) {
    ProcessInvocation invocation{{"status"}};
    invocation.environment["OPENSVN_FAKE_SLEEP_MS"] = "3000";
    const auto started = std::chrono::steady_clock::now();
    const ProcessResult result =
        fake_runner(std::chrono::milliseconds(150)).run(invocation);
    const auto elapsed = std::chrono::steady_clock::now() - started;
    EXPECT_TRUE(result.timed_out);
    EXPECT_FALSE(result.was_cancelled);
    EXPECT_LT(elapsed, std::chrono::seconds(2));
}

TEST(ProcessRunner, CancellationStopsTheProcess) {
    std::stop_source source;
    ProcessInvocation invocation{{"status"}};
    invocation.environment["OPENSVN_FAKE_SLEEP_MS"] = "3000";

    ProcessResult result;
    std::thread worker([&] {
        result = fake_runner().run(invocation, source.get_token());
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    source.request_stop();
    worker.join();

    EXPECT_TRUE(result.was_cancelled);
    EXPECT_FALSE(result.timed_out);
}

TEST(ProcessRunner, DrainsLargeOutputWithoutDeadlock) {
    ProcessInvocation invocation{{"status"}};
    invocation.environment["OPENSVN_FAKE_LARGE_BYTES"] = "200000";
    const ProcessResult result = fake_runner().run(invocation);
    ASSERT_TRUE(result.success());
    EXPECT_EQ(result.standard_output.size(), 200000u);
}

TEST(ProcessRunner, ReportsMissingExecutable) {
    ProcessRunner runner(std::filesystem::temp_directory_path() / "opensvn-no-such-svn.exe",
                         ProcessRunner::current_environment(),
                         std::chrono::seconds(1));
    try {
        runner.run(ProcessInvocation{{"--version"}});
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::svn_not_found);
    }
}

TEST(ProcessRunner, ReportsMissingWorkingDirectory) {
    ProcessInvocation invocation{{"status"}};
    invocation.working_directory =
        std::filesystem::temp_directory_path() / "opensvn-no-such-directory";
    try {
        fake_runner().run(invocation);
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::path_not_found);
    }
}

TEST(ProcessRunner, StopsBeforeSpawningWhenCancelled) {
    std::stop_source source;
    source.request_stop();
    const ProcessResult result =
        fake_runner().run(ProcessInvocation{{"--version"}}, source.get_token());
    EXPECT_TRUE(result.was_cancelled);
}

} // namespace
} // namespace opensvn
