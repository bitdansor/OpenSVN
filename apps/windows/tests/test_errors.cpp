#include "opensvn/error_mapper.hpp"

#include "opensvn/redaction.hpp"
#include "test_support.hpp"

#include <gtest/gtest.h>

namespace opensvn {
namespace {

TEST(ErrorMapping, PermissionFailureBeatsTheLockTokenThatPrecedesIt) {
    const SVNError error = SVNErrorMapper::error(
        1,
        "svn: E155004: Failed to lock working copy 'C:\\wc'.\n"
        "svn: E200031: sqlite: attempt to write a readonly database\n");
    EXPECT_EQ(error.code, SVNErrorCode::permission_denied);
    EXPECT_EQ(error.identifier(), "SVN-0006");
    EXPECT_EQ(error.svn_code.value_or(""), "E200031");
    EXPECT_EQ(error.severity(), ErrorSeverity::needs_user_action);
}

TEST(ErrorMapping, RepositoryFormatBeatsUnableToConnect) {
    const SVNError error = SVNErrorMapper::error(
        1,
        "svn: E170013: Unable to connect to a repository at URL 'file:///repo'\n"
        "svn: E160043: Expected FS format between '1' and '7'; found format '8'\n");
    EXPECT_EQ(error.code, SVNErrorCode::repository_needs_upgrade);
    EXPECT_EQ(error.svn_code.value_or(""), "E160043");
}

TEST(ErrorMapping, LockWarningBeatsTheGenericSummary) {
    const SVNError error = SVNErrorMapper::error(
        1,
        "svn: warning: W160035: Path '/tmp/wc/a.txt' is already locked by user 'bob'.\n"
        "svn: E200009: One or more locks could not be obtained\n");
    EXPECT_EQ(error.code, SVNErrorCode::path_locked);
    EXPECT_EQ(error.svn_code.value_or(""), "W160035");
    EXPECT_EQ(error.identifier(), "SVN-0304");
}

TEST(ErrorMapping, TextFallbackOnlyWhenNoTokenMatched) {
    const SVNError error =
        SVNErrorMapper::error(1, "svn: Unable to connect to a repository at URL 'x'");
    EXPECT_EQ(error.code, SVNErrorCode::network_failure);
    EXPECT_FALSE(error.svn_code.has_value());
    EXPECT_EQ(error.identifier(), "SVN-0201");
}

TEST(ErrorMapping, UnknownFailureKeepsExitCodeAndUsefulText) {
    const SVNError error = SVNErrorMapper::error(42, "svn: something odd happened\n");
    EXPECT_EQ(error.code, SVNErrorCode::command_failed);
    EXPECT_EQ(error.exit_code.value_or(0), 42);
    EXPECT_NE(error.message.find("something odd"), std::string::npos);
    EXPECT_EQ(error.identifier(), "SVN-9999");
}

TEST(ErrorMapping, StripsTheTokenFromTheHumanMessage) {
    const SVNError error = SVNErrorMapper::error(1, "svn: E999999: boom\n");
    EXPECT_EQ(error.code, SVNErrorCode::command_failed);
    EXPECT_EQ(error.message, "boom");
}

TEST(ErrorMapping, SeveritiesFollowTheContract) {
    EXPECT_EQ(severity(SVNErrorCode::network_failure), ErrorSeverity::recoverable);
    EXPECT_EQ(severity(SVNErrorCode::working_copy_locked), ErrorSeverity::recoverable);
    EXPECT_EQ(severity(SVNErrorCode::permission_denied),
              ErrorSeverity::needs_user_action);
    EXPECT_EQ(severity(SVNErrorCode::confirmation_required),
              ErrorSeverity::needs_user_action);
    EXPECT_EQ(severity(SVNErrorCode::timeout), ErrorSeverity::fatal);
    EXPECT_EQ(severity(SVNErrorCode::cancelled), ErrorSeverity::fatal);
}

TEST(Redaction, RemovesURLsPasswordsTokensAndHeaders) {
    EXPECT_EQ(LogRedactor::redact("https://alice:s3cret@example.com/repo"),
              "https://***@example.com/repo");
    EXPECT_EQ(LogRedactor::redact("--password hunter2"), "--password ***");
    EXPECT_EQ(LogRedactor::redact("token=abc123&x=1"), "token=***&x=1");
    EXPECT_EQ(LogRedactor::redact("Authorization: Bearer abc.def"),
              "Authorization: Bearer ***");
    EXPECT_EQ(LogRedactor::redact("prefix secret", {"secret"}), "prefix ***");
    EXPECT_EQ(LogRedactor::sanitized_url("https://alice:s3cret@example.com/repo"),
              "https://example.com/repo");
}

TEST(ErrorObject, DescriptionCarriesIdentifierAndRemediation) {
    const SVNError error{SVNErrorCode::working_copy_locked, "工作副本被锁定",
                         std::nullopt, std::string("E155004"), 1};
    const std::string description = error.description();
    EXPECT_NE(description.find("SVN-0004"), std::string::npos);
    EXPECT_NE(description.find("E155004"), std::string::npos);
    EXPECT_NE(description.find("Cleanup"), std::string::npos);
}

} // namespace
} // namespace opensvn
