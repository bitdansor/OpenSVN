#include "opensvn/journal.hpp"

#include "opensvn/text.hpp"
#include "test_support.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <thread>

namespace opensvn {
namespace {

TEST(OperationJournal, BeginAndFinishAreDurableAcrossRuns) {
    test::TempDir temp;
    OperationJournal first(temp.path(), "run-1");
    const std::string ticket =
        first.begin(OperationJournal::EntryKind::update, temp.path(), "更新工作副本");
    ASSERT_TRUE(std::filesystem::exists(first.file_path()));
    ASSERT_EQ(first.all_entries().size(), 1u);

    OperationJournal second(temp.path(), "run-2");
    const auto unfinished = second.unfinished();
    ASSERT_EQ(unfinished.size(), 1u);
    EXPECT_EQ(unfinished[0].summary, "更新工作副本");
    EXPECT_EQ(unfinished[0].working_copy, text::path_to_utf8(temp.path()));

    first.finish(ticket);
    EXPECT_TRUE(second.unfinished().empty());
}

TEST(OperationJournal, FailureStillFinishesTheRecord) {
    test::TempDir temp;
    OperationJournal journal(temp.path(), "run");
    const std::string ticket =
        journal.begin(OperationJournal::EntryKind::commit, temp.path(), "提交");
    journal.finish(ticket);
    EXPECT_TRUE(journal.all_entries().empty());
    EXPECT_TRUE(journal.unfinished().empty());
}

TEST(OperationJournal, CorruptFileIsQuarantinedNotDeleted) {
    test::TempDir temp;
    const auto file = temp.path() / "journal.json";
    test::write_text(file, "this is not json");

    OperationJournal journal(temp.path(), "run");
    EXPECT_TRUE(journal.all_entries().empty());
    ASSERT_TRUE(journal.quarantine_path().has_value());
    EXPECT_TRUE(std::filesystem::exists(*journal.quarantine_path()));
    EXPECT_FALSE(std::filesystem::exists(file));
}

TEST(OperationJournal, NewerSchemaIsQuarantined) {
    test::TempDir temp;
    test::write_text(temp.path() / "journal.json", R"({"version":99,"entries":[]})");
    OperationJournal journal(temp.path(), "run");
    EXPECT_TRUE(journal.all_entries().empty());
    EXPECT_TRUE(journal.quarantine_path().has_value());
}

TEST(OperationJournal, TrimsToFiftyNewestEntries) {
    test::TempDir temp;
    OperationJournal journal(temp.path(), "run");
    const auto base = std::chrono::system_clock::now() - std::chrono::hours(2);
    for (int index = 0; index < 55; ++index) {
        journal.begin(OperationJournal::EntryKind::update, temp.path(),
                      "op-" + std::to_string(index),
                      base + std::chrono::seconds(index));
    }
    const auto entries = journal.all_entries();
    ASSERT_EQ(entries.size(), OperationJournal::maximum_entries);
    EXPECT_NE(std::find_if(entries.begin(), entries.end(), [](const auto& entry) {
                  return entry.summary == "op-54";
              }),
              entries.end());
    EXPECT_EQ(std::find_if(entries.begin(), entries.end(), [](const auto& entry) {
                  return entry.summary == "op-0";
              }),
              entries.end());
}

TEST(OperationJournal, ConcurrentInstancesDoNotLoseEntries) {
    test::TempDir temp;
    OperationJournal first(temp.path(), "run-1");
    OperationJournal second(temp.path(), "run-2");

    std::thread one([&] {
        for (int index = 0; index < 10; ++index) {
            first.begin(OperationJournal::EntryKind::update, temp.path(),
                        "first-" + std::to_string(index));
        }
    });
    std::thread two([&] {
        for (int index = 0; index < 10; ++index) {
            second.begin(OperationJournal::EntryKind::commit, temp.path(),
                         "second-" + std::to_string(index));
        }
    });
    one.join();
    two.join();

    EXPECT_EQ(first.all_entries().size(), 20u);
    EXPECT_EQ(second.all_entries().size(), 20u);
    EXPECT_TRUE(std::filesystem::exists(
        first.file_path().parent_path() / "journal.json.lock"));
}

TEST(OperationJournal, RecoveryAdviceNeverSuggestsBlindCommitRetry) {
    OperationJournal::Entry entry;
    entry.kind = OperationJournal::EntryKind::commit;
    EXPECT_NE(entry.recovery_advice().find("不要直接重复提交"), std::string::npos);
    EXPECT_EQ(entry.title(), "提交");
}

} // namespace
} // namespace opensvn
