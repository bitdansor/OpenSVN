// Model and parser contract tests (GoogleTest).
//
// These are the tests that must agree with apps/macos/Tests/OpenSVNCoreTests:
// same fixture in, same fields out. Run them with `ctest` or directly from the
// test project; they need no desktop session and no network.
//
// NOT yet compiled on Windows — see ../README.md.

#include <gtest/gtest.h>

#include "Models/SVNModels.h"

using namespace opensvn;

namespace {

TEST(WCItemStatus, KnownTokensMapToEnum) {
    EXPECT_EQ(WCItemStatus::Parse("modified").kind, WCItemStatus::Kind::modified);
    EXPECT_EQ(WCItemStatus::Parse("conflicted").kind, WCItemStatus::Kind::conflicted);
    EXPECT_EQ(WCItemStatus::Parse("incomplete").kind, WCItemStatus::Kind::incomplete);
    EXPECT_EQ(WCItemStatus::Parse("normal").kind, WCItemStatus::Kind::normal);
}

TEST(WCItemStatus, UnknownTokenIsPreservedNotNormalised) {
    // A status token we do not know must reach the UI verbatim; mapping it to
    // "normal" would silently hide a real state (data-models.md §2).
    const auto status = WCItemStatus::Parse("some-future-token");
    EXPECT_EQ(status.kind, WCItemStatus::Kind::unknown);
    EXPECT_EQ(status.raw, "some-future-token");
    EXPECT_EQ(status.ToString(), "some-future-token");
}

TEST(WCItemStatus, RoundTripsEveryKnownToken) {
    for (const char* token : {"added", "conflicted", "deleted", "external", "ignored", "incomplete",
                              "invalid", "merged", "missing", "modified", "none", "normal",
                              "obstructed", "replaced", "unversioned"}) {
        EXPECT_EQ(WCItemStatus::Parse(token).ToString(), token);
    }
}

TEST(ConflictFlags, CombineWithoutLosingInformation) {
    ConflictFlags flags;
    flags.Set(kConflictText);
    flags.Set(kConflictTree);

    EXPECT_TRUE(flags.Has(kConflictText));
    EXPECT_TRUE(flags.Has(kConflictTree));
    EXPECT_FALSE(flags.Has(kConflictProperty));

    // Stable order matters: both platforms serialise the same array.
    EXPECT_EQ(flags.ToList(), (std::vector<std::string>{"text", "tree"}));
}

TEST(ConflictFlags, EmptyIsEmpty) {
    const ConflictFlags flags;
    EXPECT_TRUE(flags.IsEmpty());
    EXPECT_FALSE(flags.HasAny());
    EXPECT_TRUE(flags.ToList().empty());
}

TEST(StatusCategory, ConflictWinsOverItem) {
    StatusEntry entry;
    entry.text_status = WCItemStatus::Parse("modified");
    entry.conflicts.Set(kConflictText);
    EXPECT_EQ(CategoryOf(entry), StatusCategory::conflicted);
}

TEST(StatusCategory, MissingFoldsIntoDeletedGroup) {
    StatusEntry entry;
    entry.text_status = WCItemStatus::Parse("missing");
    EXPECT_EQ(CategoryOf(entry), StatusCategory::deleted);
}

TEST(StatusCategory, RepositoryLockIsNotAConflict) {
    // The two kinds of "lock" must not bleed into the conflict category.
    StatusEntry entry;
    entry.text_status = WCItemStatus::Parse("normal");
    entry.repository_lock = RepositoryLock{"token", "alice", "review", "2026-10-18T04:35:56.116Z"};
    EXPECT_FALSE(entry.HasConflicts());
    EXPECT_EQ(CategoryOf(entry), StatusCategory::normal);
}

TEST(SVNError, ErrorIdentifiersMatchTheMacOSTable) {
    SVNError locked;
    locked.code = SVNErrorCode::workingCopyLocked;
    EXPECT_EQ(locked.identifier(), "SVN-0004");
    EXPECT_FALSE(locked.remediation().empty());

    SVNError auth;
    auth.code = SVNErrorCode::authenticationRequired;
    EXPECT_EQ(auth.identifier(), "SVN-0101");
    EXPECT_EQ(auth.severity(), ErrorSeverity::needsUserAction);

    SVNError timeout;
    timeout.code = SVNErrorCode::timeout;
    EXPECT_EQ(timeout.identifier(), "SVN-0401");
    EXPECT_EQ(timeout.severity(), ErrorSeverity::fatal);
}

TEST(SVNError, DisplayNeverLeaksIntoTheMessage) {
    SVNError error;
    error.code = SVNErrorCode::commandFailed;
    error.message = "svn 执行失败";
    error.svn_code = "E155004";
    error.exit_code = 1;

    const std::string text = error.Display();
    EXPECT_NE(text.find("[SVN-9999]"), std::string::npos);
    EXPECT_NE(text.find("E155004"), std::string::npos);
}

TEST(ResolveStrategy, OnlyWorkingIsSafe) {
    EXPECT_FALSE(IsDestructive(ResolveStrategy::working));
    EXPECT_TRUE(IsDestructive(ResolveStrategy::mine_full));
    EXPECT_TRUE(IsDestructive(ResolveStrategy::theirs_full));
    EXPECT_TRUE(IsDestructive(ResolveStrategy::base));
    EXPECT_EQ(ToToken(ResolveStrategy::theirs_full), "theirs-full");
}

TEST(LogPage, HasMoreWhenThePageIsFull) {
    LogPage page;
    page.limit = 2;
    page.entries.resize(2);
    page.entries[0].revision = 10;
    page.entries[1].revision = 9;

    EXPECT_TRUE(page.has_more());
    ASSERT_TRUE(page.oldest_revision().has_value());
    EXPECT_EQ(*page.oldest_revision(), 9);
}

TEST(LogPage, EmptyPageHasNoMoreAndNoOldest) {
    LogPage page;
    page.limit = 50;
    EXPECT_FALSE(page.has_more());
    EXPECT_FALSE(page.oldest_revision().has_value());
}

}  // namespace
