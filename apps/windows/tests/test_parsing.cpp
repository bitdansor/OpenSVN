#include "opensvn/parsing.hpp"

#include "opensvn/errors.hpp"
#include "test_support.hpp"

#include <gtest/gtest.h>

#include <algorithm>

namespace opensvn {
namespace {

TEST(StatusParsing, ChangelistMembersAreNotLost) {
    const auto status = parsing::parse_status(test::fixture("svn-status-changelist.xml"));
    ASSERT_EQ(status.entries.size(), 2u);

    const auto regular = std::find_if(status.entries.begin(), status.entries.end(),
                                      [](const StatusEntry& entry) {
                                          return entry.path == "trunk/sub/b.txt";
                                      });
    ASSERT_NE(regular, status.entries.end());
    EXPECT_TRUE(regular->item.is(WCItemStatus::Kind::modified));
    EXPECT_FALSE(regular->changelist.has_value());

    const auto listed = std::find_if(status.entries.begin(), status.entries.end(),
                                     [](const StatusEntry& entry) {
                                         return entry.path == "trunk/readme.md";
                                     });
    ASSERT_NE(listed, status.entries.end());
    EXPECT_TRUE(listed->item.is(WCItemStatus::Kind::modified));
    EXPECT_EQ(listed->changelist.value_or(""), "ui-review");
    EXPECT_EQ(listed->revision.value_or(0), 1);
}

TEST(StatusParsing, MultipleChangelistsMergeDuplicatesAndKeepConflicts) {
    const std::string xml =
        "<status>"
        "<changelist name=\"one\">"
        "<entry path=\"a\"><wc-status item=\"modified\" revision=\"2\" props=\"modified\"/>"
        "</entry>"
        "<entry path=\"conflict\"><wc-status item=\"conflicted\" revision=\"2\" "
        "tree-conflicted=\"true\"/></entry>"
        "</changelist>"
        "<changelist name=\"two\">"
        "<entry path=\"b\"><wc-status item=\"modified\" revision=\"3\"/></entry>"
        "</changelist>"
        "<target path=\".\">"
        "<entry path=\"a\"><wc-status item=\"normal\" revision=\"4\">"
        "<commit revision=\"4\"><author>fixture</author></commit>"
        "</wc-status></entry>"
        "</target>"
        "</status>";
    const auto status = parsing::parse_status(xml);
    ASSERT_EQ(status.entries.size(), 3u);

    const auto a = std::find_if(status.entries.begin(), status.entries.end(),
                                [](const StatusEntry& entry) { return entry.path == "a"; });
    ASSERT_NE(a, status.entries.end());
    EXPECT_TRUE(a->item.is(WCItemStatus::Kind::modified));
    EXPECT_TRUE(a->properties.is(WCItemStatus::Kind::modified));
    EXPECT_EQ(a->revision.value_or(0), 4);
    EXPECT_EQ(a->changelist.value_or(""), "one");
    ASSERT_TRUE(a->commit.has_value());
    EXPECT_EQ(a->commit->author.value_or(""), "fixture");

    const auto conflict = std::find_if(
        status.entries.begin(), status.entries.end(),
        [](const StatusEntry& entry) { return entry.path == "conflict"; });
    ASSERT_NE(conflict, status.entries.end());
    EXPECT_TRUE(has_flag(conflict->conflicts, ConflictFlags::text));
    EXPECT_TRUE(has_flag(conflict->conflicts, ConflictFlags::tree));
    EXPECT_EQ(conflict->changelist.value_or(""), "one");

    const auto b = std::find_if(status.entries.begin(), status.entries.end(),
                                [](const StatusEntry& entry) { return entry.path == "b"; });
    ASSERT_NE(b, status.entries.end());
    EXPECT_EQ(b->changelist.value_or(""), "two");
}

TEST(StatusParsing, CleanWorkingCopyHasTargetButNoEntries) {
    const StatusSnapshot snapshot = parsing::parse_status(test::fixture("svn-status-clean.xml"));
    ASSERT_TRUE(snapshot.target.has_value());
    EXPECT_EQ(*snapshot.target, "wc-clean");
    EXPECT_TRUE(snapshot.entries.empty());
    EXPECT_FALSE(snapshot.working_copy_revision.has_value());
    EXPECT_FALSE(snapshot.server_revision.has_value());
}

TEST(StatusParsing, ConflictedFixtureKeepsEveryConflictKind) {
    const auto status = parsing::parse_status(test::fixture("svn-status-conflicted.xml"));
    ASSERT_TRUE(status.target.has_value());
    EXPECT_EQ(*status.target, "wc-a");

    const auto locked = std::find_if(status.entries.begin(), status.entries.end(),
                                     [](const StatusEntry& entry) {
                                         return entry.path == "wc-a/docs/locked.txt";
                                     });
    ASSERT_NE(locked, status.entries.end());
    ASSERT_TRUE(locked->conflicts != ConflictFlags::none);
    ASSERT_TRUE(has_flag(locked->conflicts, ConflictFlags::text));
    EXPECT_FALSE(has_flag(locked->conflicts, ConflictFlags::property));

    const auto tree = std::find_if(status.entries.begin(), status.entries.end(),
                                   [](const StatusEntry& entry) {
                                       return entry.path == "wc-a/docs/tree-conflict.txt";
                                   });
    ASSERT_NE(tree, status.entries.end());
    EXPECT_TRUE(has_flag(tree->conflicts, ConflictFlags::tree));
    EXPECT_TRUE(tree->is_copied);
    EXPECT_TRUE(tree->item.is(WCItemStatus::Kind::added));

    const auto util = std::find_if(status.entries.begin(), status.entries.end(),
                                   [](const StatusEntry& entry) {
                                       return entry.path == "wc-a/src/util.swift";
                                   });
    ASSERT_NE(util, status.entries.end());
    EXPECT_TRUE(has_flag(util->conflicts, ConflictFlags::text));
    EXPECT_TRUE(util->properties.is(WCItemStatus::Kind::modified));
    EXPECT_EQ(util->category(), StatusCategory::conflicted);

    const auto chinese = std::find_if(status.entries.begin(), status.entries.end(),
                                      [](const StatusEntry& entry) {
                                          return entry.path == "wc-a/docs/新增文件.txt";
                                      });
    ASSERT_NE(chinese, status.entries.end());
    EXPECT_EQ(chinese->revision.value_or(0), -1);

    EXPECT_EQ(status.conflicted().size(), 3u);
    EXPECT_EQ(status.changed().size(), 6u);
    // The macOS implementation derives this as the minimum reported revision,
    // including -1 for scheduled adds.
    EXPECT_EQ(status.working_copy_revision.value_or(0), -1);
}

TEST(StatusParsing, RepositoryLockIsKeptAwayFromWorkingCopyLock) {
    const auto status = parsing::parse_status(test::fixture("svn-status-locked.xml"));
    ASSERT_EQ(status.entries.size(), 1u);
    const StatusEntry& entry = status.entries.front();
    ASSERT_TRUE(entry.repository_lock.has_value());
    EXPECT_EQ(entry.repository_lock->owner.value_or(""), "fixture");
    EXPECT_EQ(entry.repository_lock->comment.value_or(""), "fixture lock");
    ASSERT_TRUE(entry.repository_lock->created_at.has_value());
    EXPECT_EQ(format_iso8601(*entry.repository_lock->created_at),
              "2026-10-18T04:35:58.061Z");
    EXPECT_FALSE(entry.is_working_copy_locked);

    const LockSnapshot locks = LockSnapshot::from(status);
    EXPECT_TRUE(locks.is_own_lock("wc-b/docs/repo-locked.txt"));
}

TEST(StatusParsing, WorkingCopyLockComesFromTheLockedAttribute) {
    const std::string xml =
        "<status><target path=\".\">"
        "<entry path=\"locked\"><wc-status item=\"normal\" locked=\"true\"/></entry>"
        "<entry path=\"incomplete\"><wc-status item=\"incomplete\" locked=\"false\"/></entry>"
        "</target></status>";
    const auto status = parsing::parse_status(xml);
    ASSERT_EQ(status.entries.size(), 2u);
    EXPECT_EQ(status.entries[0].path, "locked");
    EXPECT_TRUE(status.entries[0].is_working_copy_locked);
    EXPECT_EQ(status.entries[1].path, "incomplete");
    EXPECT_FALSE(status.entries[1].is_working_copy_locked);
    EXPECT_TRUE(status.entries[1].item.is(WCItemStatus::Kind::incomplete));
}

TEST(StatusParsing, RemoteStatusBuildsPreviewWithoutRootNoise) {
    const auto status = parsing::parse_status(test::fixture("svn-status-remote-changes.xml"));
    EXPECT_EQ(status.entries.size(), 4u);
    EXPECT_EQ(status.server_revision.value_or(0), 2);
    EXPECT_EQ(status.working_copy_revision.value_or(0), 1);

    const RemotePreview preview = RemotePreview::make(status);
    ASSERT_EQ(preview.changes.size(), 3u);
    EXPECT_FALSE(preview.root_property_change.has_value());
    EXPECT_EQ(preview.server_revision.value_or(0), 2);
    EXPECT_EQ(preview.added_count(), 1);
    EXPECT_EQ(preview.modified_count(), 1);
    EXPECT_EQ(preview.deleted_count(), 1);

    EXPECT_EQ(preview.changes[0].path, "a.txt");
    EXPECT_EQ(preview.changes[1].path, "b.txt");
    EXPECT_EQ(preview.changes[2].path, "n.txt");
    EXPECT_EQ(preview.changes[0].item.kind(), WCItemStatus::Kind::modified);
    EXPECT_EQ(preview.changes[0].local_item.kind(), WCItemStatus::Kind::modified);
    EXPECT_TRUE(preview.changes[0].conflicts_with_local());
}

TEST(StatusParsing, RemotePreviewFiltersRootAndDeduplicatesDirectories) {
    const std::string xml =
        "<status><target path=\".\">"
        "<entry path=\".\"><wc-status item=\"normal\" props=\"modified\" revision=\"3\"/>"
        "<repos-status item=\"none\" props=\"modified\"/></entry>"
        "<entry path=\"dir\"><wc-status item=\"modified\" props=\"none\" revision=\"3\"/>"
        "<repos-status item=\"modified\" props=\"none\"/></entry>"
        "<entry path=\"dir/file.txt\"><wc-status item=\"normal\" props=\"none\" revision=\"3\"/>"
        "<repos-status item=\"modified\" props=\"none\"/></entry>"
        "<against revision=\"5\"/></target></status>";
    const auto status = parsing::parse_status(xml);
    const RemotePreview preview = RemotePreview::make(status);

    ASSERT_TRUE(preview.root_property_change.has_value());
    EXPECT_EQ(preview.root_property_change->path, ".");
    ASSERT_EQ(preview.changes.size(), 1u);
    EXPECT_EQ(preview.changes[0].path, "dir/file.txt");
}

TEST(StatusParsing, RemoteLocksIncludeOtherUsers) {
    const auto status = parsing::parse_status(test::fixture("svn-status-remote-lock.xml"));
    const LockSnapshot locks = LockSnapshot::from(status);
    EXPECT_EQ(locks.count(), 2u);
    EXPECT_TRUE(locks.is_own_lock("/tmp/wc/docs/both.txt"));
    EXPECT_FALSE(locks.is_own_lock("/tmp/wc/docs/other.txt"));
    EXPECT_EQ(locks.foreign_locks({"/tmp/wc/docs/both.txt", "/tmp/wc/docs/other.txt",
                                   "/tmp/wc/docs/free.txt"})
                  .size(),
              1u);
}

TEST(LogParsing, ReadsAuthorsDatesMessagesAndChangedPaths) {
    const auto entries = parsing::parse_log(test::fixture("svn-log.xml"));
    ASSERT_EQ(entries.size(), 4u);
    EXPECT_EQ(entries[0].revision, 4);
    EXPECT_EQ(entries[0].author.value_or(""), "fixture");
    ASSERT_TRUE(entries[0].date.has_value());
    EXPECT_EQ(format_iso8601(*entries[0].date), "2026-10-18T04:35:56.116Z");
    EXPECT_EQ(entries[0].message, "wc-b：删除 tree-conflict.txt");
    ASSERT_EQ(entries[0].changed_paths.size(), 1u);
    EXPECT_EQ(entries[0].changed_paths[0].action, ChangedPath::Action::deleted);

    const auto& initial = entries.back();
    EXPECT_EQ(initial.revision, 1);
    EXPECT_GE(initial.changed_paths.size(), 20u);
    const bool has_chinese_path =
        std::any_of(initial.changed_paths.begin(), initial.changed_paths.end(),
                    [](const ChangedPath& path) {
                        return path.path == "/trunk/docs/中文 文档 (v1) & notes.txt";
                    });
    EXPECT_TRUE(has_chinese_path);
}

TEST(InfoParsing, WorkingCopyInfo) {
    const InfoReport report = parsing::parse_info(test::fixture("svn-info-wc.xml"));
    const RepositoryInfo* info = report.primary();
    ASSERT_NE(info, nullptr);
    EXPECT_EQ(info->path, "wc-a");
    EXPECT_EQ(info->kind, NodeKind::dir);
    EXPECT_EQ(info->revision.value_or(0), 4);
    EXPECT_EQ(info->repository_root.value_or(""),
              "file:///private/tmp/opensvn-fixtures/repo");
    ASSERT_TRUE(info->working_copy_root.has_value());
    EXPECT_EQ(info->schedule.value_or(""), "normal");
    EXPECT_EQ(info->depth.value_or(""), "infinity");
    EXPECT_EQ(info->last_changed_revision.value_or(0), 4);
    ASSERT_TRUE(info->last_changed_date.has_value());
    EXPECT_EQ(format_iso8601(*info->last_changed_date), "2026-10-18T04:35:56.116Z");
    EXPECT_FALSE(info->host().has_value());
}

TEST(InfoParsing, UrlInfoHasNoWorkingCopyRoot) {
    const InfoReport report = parsing::parse_info(test::fixture("svn-info-url.xml"));
    const RepositoryInfo* info = report.primary();
    ASSERT_NE(info, nullptr);
    EXPECT_EQ(info->kind, NodeKind::file);
    EXPECT_FALSE(info->working_copy_root.has_value());
    EXPECT_EQ(info->last_changed_revision.value_or(0), 1);
}

TEST(InfoParsing, ConflictArtifactsComeFromTheInfoBlock) {
    const auto artifacts =
        parsing::parse_conflict_artifacts(test::fixture("svn-info-conflict.xml"));
    ASSERT_TRUE(artifacts.has_value());
    EXPECT_EQ(artifacts->type, "text");
    EXPECT_EQ(artifacts->operation, "update");
    EXPECT_EQ(artifacts->prev_base_file.value_or(""), "/fixture/wc/f.txt.r1");
    EXPECT_EQ(artifacts->prev_wc_file.value_or(""), "/fixture/wc/f.txt.mine");
    EXPECT_EQ(artifacts->cur_base_file.value_or(""), "/fixture/wc/f.txt.r2");
    EXPECT_EQ(artifacts->source_left_revision.value_or(0), 1);
    EXPECT_EQ(artifacts->source_right_revision.value_or(0), 2);
}

TEST(PropertyParsing, ReadsValuesAndEmptyDocuments) {
    const std::string xml =
        "<properties><target path=\"wc\">"
        "<property name=\"svn:ignore\">build\n*.tmp</property>"
        "<property name=\"custom:owner\">alice</property>"
        "</target></properties>";
    const auto targets = parsing::parse_properties(xml);
    ASSERT_EQ(targets.size(), 1u);
    EXPECT_EQ(targets[0].path, "wc");
    ASSERT_EQ(targets[0].properties.size(), 2u);
    EXPECT_EQ(targets[0].properties[0].name, "svn:ignore");
    const auto ignore_entries = targets[0].properties[0].ignore_entries();
    ASSERT_EQ(ignore_entries.size(), 2u);
    EXPECT_EQ(ignore_entries[0], "build");
    EXPECT_EQ(ignore_entries[1], "*.tmp");
    EXPECT_EQ(targets[0].value_of("custom:owner").value_or(""), "alice");

    EXPECT_TRUE(parsing::parse_properties("<properties/>").empty());
}

TEST(ParsingErrors, MalformedAndUnexpectedRootsThrowSVN9002) {
    try {
        parsing::parse_status("<status><target>");
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::xml_parse_failure);
        EXPECT_EQ(error.error().identifier(), "SVN-9002");
    }
    EXPECT_THROW(parsing::parse_status("<log/>"), SVNException);
    EXPECT_THROW(parsing::parse_log("<status/>"), SVNException);
    EXPECT_THROW(parsing::parse_info("<info/>"), SVNException);
    EXPECT_THROW(parsing::parse_properties("<status/>"), SVNException);
}

} // namespace
} // namespace opensvn
