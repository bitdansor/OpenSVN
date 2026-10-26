#include "opensvn/models.hpp"

#include "opensvn/errors.hpp"
#include "test_support.hpp"

#include <gtest/gtest.h>

namespace opensvn {
namespace {

TEST(SVNDate, ParsesMicrosecondsAndFormatsMilliseconds) {
    const auto parsed = parse_svn_date("2026-10-18T04:35:56.116733Z");
    ASSERT_TRUE(parsed.has_value());
    EXPECT_EQ(format_iso8601(*parsed), "2026-10-18T04:35:56.116Z");
}

TEST(SVNDate, ParsesWithoutFractionAndWithOffset) {
    ASSERT_TRUE(parse_svn_date("2026-10-18T04:35:56Z").has_value());
    const auto offset = parse_svn_date("2026-10-18T12:35:56+08:00");
    ASSERT_TRUE(offset.has_value());
    EXPECT_EQ(format_iso8601(*offset), "2026-10-18T04:35:56.000Z");
}

TEST(SVNDate, RejectsGarbage) {
    EXPECT_FALSE(parse_svn_date("").has_value());
    EXPECT_FALSE(parse_svn_date("2026-13-18T04:35:56Z").has_value());
    EXPECT_FALSE(parse_svn_date("not a date").has_value());
}

TEST(WCItemStatus, PreservesUnknownTokens) {
    const WCItemStatus status("future-state");
    EXPECT_EQ(status.kind(), WCItemStatus::Kind::unknown);
    EXPECT_EQ(status.raw(), "future-state");
    EXPECT_FALSE(status.is_committable_change());
    EXPECT_FALSE(status.is_blocking());
}

TEST(WCItemStatus, ClassifiesCommittableAndBlocking) {
    EXPECT_TRUE(WCItemStatus("modified").is_committable_change());
    EXPECT_TRUE(WCItemStatus("added").is_committable_change());
    EXPECT_TRUE(WCItemStatus("deleted").is_committable_change());
    EXPECT_FALSE(WCItemStatus("conflicted").is_committable_change());
    EXPECT_TRUE(WCItemStatus("conflicted").is_blocking());
    EXPECT_TRUE(WCItemStatus("missing").is_blocking());
}

TEST(ConflictFlags, StableCodeOrder) {
    const ConflictFlags flags =
        ConflictFlags::tree | ConflictFlags::text | ConflictFlags::property;
    const auto codes = conflict_codes(flags);
    ASSERT_EQ(codes.size(), 3u);
    EXPECT_EQ(codes[0], "text");
    EXPECT_EQ(codes[1], "property");
    EXPECT_EQ(codes[2], "tree");
    EXPECT_TRUE(conflict_codes(ConflictFlags::none).empty());
}

TEST(StatusEntry, CategoryPrioritisesConflictsAndGroupsMissingAsDeleted) {
    StatusEntry entry;
    entry.item = WCItemStatus("missing");
    EXPECT_EQ(entry.category(), StatusCategory::deleted);

    entry.item = WCItemStatus("normal");
    entry.properties = WCItemStatus("modified");
    EXPECT_EQ(entry.category(), StatusCategory::modified);

    entry.conflicts = ConflictFlags::tree;
    EXPECT_EQ(entry.category(), StatusCategory::conflicted);
}

TEST(IgnoreList, EscapesGlobMetacharacters) {
    EXPECT_EQ(IgnoreList::pattern("report*.txt"), "report[*].txt");
    EXPECT_EQ(IgnoreList::pattern("a?[1]"), "a[?][[]1[]]");
    EXPECT_EQ(IgnoreList::pattern("plain.txt"), "plain.txt");
}

TEST(IgnoreList, AddingSkipsExistingPatterns) {
    const auto added = IgnoreList::adding("build", std::nullopt);
    ASSERT_TRUE(added.has_value());
    EXPECT_EQ(*added, "build");

    EXPECT_FALSE(IgnoreList::adding("build", std::string("build\n")).has_value());
    EXPECT_FALSE(IgnoreList::adding("a*.txt", std::string("a[*].txt\n")).has_value());

    const auto multiline = IgnoreList::adding("b", std::string("a\n"));
    ASSERT_TRUE(multiline.has_value());
    EXPECT_EQ(*multiline, "a\nb");
}

TEST(PropertyName, ValidatesNamespaceAndReservedPrefixes) {
    EXPECT_NO_THROW(SVNPropertyName::validate("svn:ignore"));
    EXPECT_NO_THROW(SVNPropertyName::validate("custom:owner"));
    EXPECT_THROW(SVNPropertyName::validate("owner"), SVNException);
    EXPECT_THROW(SVNPropertyName::validate("bad name"), SVNException);
    EXPECT_THROW(SVNPropertyName::validate("svn:entry:committed-rev"), SVNException);
    EXPECT_THROW(SVNPropertyName::validate(" custom:owner"), SVNException);
    EXPECT_THROW(SVNPropertyName::validate(""), SVNException);
}

TEST(LockOutputParser, ReadsLockedUnlockedAndOwner) {
    const std::string locked =
        "'/tmp/wc/a.txt' locked by user 'alice'.\n"
        "'/tmp/wc/b.txt' locked by user 'bob'.\n";
    const auto paths = LockOutputParser::locked_paths(locked);
    ASSERT_EQ(paths.size(), 2u);
    EXPECT_EQ(paths[0], "/tmp/wc/a.txt");
    EXPECT_EQ(paths[1], "/tmp/wc/b.txt");
    EXPECT_EQ(LockOutputParser::owner(locked).value_or(""), "bob");
    EXPECT_TRUE(LockOutputParser::unlocked_paths("'a' locked by user 'x'.\n").empty());
    EXPECT_EQ(LockOutputParser::unlocked_paths("'/tmp/wc/a.txt' unlocked.\n")[0],
              "/tmp/wc/a.txt");
}

TEST(LockSnapshot, DistinguishesOwnFromForeignLocks) {
    StatusEntry own;
    own.path = "C:\\wc\\a.txt";
    own.repository_lock = RepositoryLock{std::string("t1"), std::string("me"), std::nullopt,
                                         std::nullopt};

    StatusEntry foreign;
    foreign.path = "C:\\wc\\b.txt";
    foreign.remote_lock = RepositoryLock{std::string("t2"), std::string("alice"),
                                         std::nullopt, std::nullopt};

    StatusSnapshot snapshot;
    snapshot.entries = {own, foreign};
    const LockSnapshot locks = LockSnapshot::from(snapshot);

    EXPECT_EQ(locks.count(), 2u);
    EXPECT_TRUE(locks.is_own_lock("C:\\wc\\a.txt"));
    EXPECT_FALSE(locks.is_own_lock("C:\\wc\\b.txt"));
    const auto foreign_paths = locks.foreign_locks({"C:\\wc\\a.txt", "C:\\wc\\b.txt"});
    ASSERT_EQ(foreign_paths.size(), 1u);
    EXPECT_EQ(foreign_paths[0], "C:\\wc\\b.txt");
    EXPECT_TRUE(locks.lock_for("a.txt").has_value());
}

TEST(RemoteChange, ConflictRiskIsHeuristic) {
    RemoteChange change;
    change.item = WCItemStatus("modified");
    change.local_item = WCItemStatus("modified");
    EXPECT_TRUE(change.conflicts_with_local());

    change.local_item = WCItemStatus("normal");
    change.local_properties = WCItemStatus("none");
    EXPECT_FALSE(change.conflicts_with_local());

    change.item = WCItemStatus("added");
    change.local_item = WCItemStatus("unversioned");
    EXPECT_TRUE(change.conflicts_with_local());
}

TEST(ResolveStrategy, HumanReadableConsequences) {
    EXPECT_FALSE(is_destructive(ResolveStrategy::working));
    EXPECT_TRUE(is_destructive(ResolveStrategy::mine_full));
    EXPECT_EQ(std::string(to_string(ResolveStrategy::theirs_full)), "theirs-full");
    EXPECT_NE(resolve_title(ResolveStrategy::base).find("基线"), std::string_view::npos);
    EXPECT_NE(resolve_consequence(ResolveStrategy::mine_full).find("不可撤销"),
              std::string_view::npos);
}

} // namespace
} // namespace opensvn
