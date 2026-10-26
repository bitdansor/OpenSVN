#include "opensvn/json_contract.hpp"

#include "opensvn/parsing.hpp"
#include "test_support.hpp"

#include <gtest/gtest.h>

namespace opensvn {
namespace {

TEST(JsonContract, StatusUsesSortedObjectsAndExplicitNulls) {
    const auto snapshot = parsing::parse_status(test::fixture("svn-status-conflicted.xml"));
    const Json json = status_to_json(snapshot);

    EXPECT_EQ(json["target"], "wc-a");
    ASSERT_EQ(json["entries"].size(), 15u);
    EXPECT_EQ(json["workingCopyRevision"], -1);
    EXPECT_TRUE(json["serverRevision"].is_null());

    const Json& locked = json["entries"][1];
    EXPECT_EQ(locked["path"], "wc-a/docs/locked.txt");
    ASSERT_EQ(locked["conflicts"].size(), 1u);
    EXPECT_EQ(locked["conflicts"][0], "text");
    EXPECT_TRUE(locked["repositoryLock"].is_null());
    EXPECT_TRUE(locked["changelist"].is_null());
    EXPECT_TRUE(locked["remoteItem"].is_null());
    EXPECT_EQ(locked["revision"], 4);
    EXPECT_EQ(locked["commit"]["author"], "fixture");
    EXPECT_EQ(locked["commit"]["date"], "2026-10-18T04:35:54.118Z");

    const std::string dumped = json.dump();
    EXPECT_LT(dumped.find("\"category\""), dumped.find("\"changelist\""));
    EXPECT_LT(dumped.find("\"changelist\""), dumped.find("\"commit\""));
}

TEST(JsonContract, LogEntryActionsAndOptionalCopies) {
    const Json json = log_to_json(parsing::parse_log(test::fixture("svn-log.xml")));
    ASSERT_EQ(json.size(), 4u);
    EXPECT_EQ(json[0]["revision"], 4);
    EXPECT_EQ(json[0]["date"], "2026-10-18T04:35:56.116Z");
    ASSERT_EQ(json[0]["changedPaths"].size(), 1u);
    EXPECT_EQ(json[0]["changedPaths"][0]["action"], "D");
    EXPECT_TRUE(json[0]["changedPaths"][0]["copyFromPath"].is_null());
    EXPECT_TRUE(json[0]["changedPaths"][0]["copyFromRevision"].is_null());
}

TEST(JsonContract, InfoContainsRepositoryAndWorkingCopyFields) {
    const Json json = info_to_json(parsing::parse_info(test::fixture("svn-info-wc.xml")));
    ASSERT_EQ(json["entries"].size(), 1u);
    const Json& entry = json["entries"][0];
    EXPECT_EQ(entry["kind"], "dir");
    EXPECT_EQ(entry["revision"], 4);
    EXPECT_EQ(entry["workingCopyRoot"],
              "/private/tmp/opensvn-fixtures/wc-a");
    EXPECT_EQ(entry["lastChangedDate"], "2026-10-18T04:35:56.116Z");
    EXPECT_TRUE(entry["repositoryLock"].is_null());
}

TEST(JsonContract, ChangelistMembersCarryTheContainerName) {
    const Json json =
        status_to_json(parsing::parse_status(test::fixture("svn-status-changelist.xml")));
    ASSERT_EQ(json["entries"].size(), 2u);
    bool found_listed = false;
    for (const auto& entry : json["entries"]) {
        if (entry["path"] == "trunk/readme.md") {
            found_listed = true;
            EXPECT_EQ(entry["changelist"], "ui-review");
            EXPECT_EQ(entry["item"], "modified");
        }
    }
    EXPECT_TRUE(found_listed);
}

TEST(JsonContract, PropertiesKeepNamesAndMultilineValues) {
    const std::string xml =
        "<properties><target path=\"wc\">"
        "<property name=\"svn:ignore\">build\n*.tmp</property>"
        "<property name=\"empty\"></property>"
        "<property name=\"custom:binary\" encoding=\"base64\">AAE=</property>"
        "</target></properties>";
    const Json json = properties_to_json(parsing::parse_properties(xml));
    ASSERT_EQ(json.size(), 1u);
    EXPECT_EQ(json[0]["path"], "wc");
    ASSERT_EQ(json[0]["properties"].size(), 3u);
    EXPECT_EQ(json[0]["properties"][0]["name"], "svn:ignore");
    EXPECT_EQ(json[0]["properties"][0]["value"], "build\n*.tmp");
    EXPECT_TRUE(json[0]["properties"][0]["encoding"].is_null());
    EXPECT_EQ(json[0]["properties"][1]["value"], "");
    EXPECT_TRUE(json[0]["properties"][1]["encoding"].is_null());
    EXPECT_EQ(json[0]["properties"][2]["value"], "AAE=");
    EXPECT_EQ(json[0]["properties"][2]["encoding"], "base64");
}

TEST(JsonContract, RemotePreviewExposesConflictRiskAsBoolean) {
    const auto snapshot = parsing::parse_status(test::fixture("svn-status-remote-changes.xml"));
    const Json json = remote_preview_to_json(RemotePreview::make(snapshot));
    ASSERT_EQ(json["changes"].size(), 3u);
    EXPECT_TRUE(json["rootPropertyChange"].is_null());
    EXPECT_EQ(json["serverRevision"], 2);
    EXPECT_EQ(json["changes"][0]["path"], "a.txt");
    EXPECT_EQ(json["changes"][0]["conflictsWithLocal"], true);
}

} // namespace
} // namespace opensvn
