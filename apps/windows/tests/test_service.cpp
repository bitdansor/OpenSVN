#include "opensvn/service.hpp"

#include "opensvn/errors.hpp"
#include "opensvn/output_parser.hpp"
#include "opensvn/text.hpp"
#include "test_support.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <thread>

namespace opensvn {
namespace {

std::string xml_escape(std::string value) {
    const auto replace_all = [&](std::string_view from, std::string_view to) {
        for (std::size_t at = value.find(from); at != std::string::npos;
             at = value.find(from, at + to.size())) {
            value.replace(at, from.size(), to);
        }
    };
    replace_all("&", "&amp;");
    replace_all("<", "&lt;");
    replace_all(">", "&gt;");
    replace_all("\"", "&quot;");
    return value;
}

std::string status_xml_for_directory(const std::filesystem::path& directory,
                                     const std::string& item, const std::string& props) {
    const std::string target = xml_escape(text::path_to_utf8(directory));
    const std::string child =
        xml_escape(text::path_to_utf8(directory / "child.txt"));
    return "<status><target path=\"" + target + "\">"
           "<entry path=\"" + target + "\"><wc-status item=\"" + item +
           "\" revision=\"4\" props=\"" + props + "\"/></entry>"
           "<entry path=\"" + child +
           "\"><wc-status item=\"modified\" revision=\"4\" props=\"none\"/></entry>"
           "</target></status>";
}
std::string http_info_fixture() {
    return R"(<info><entry path="C:\wc" revision="1" kind="dir">)"
           R"(<url>http://example.com/repo/trunk</url>)"
           R"(<repository><root>http://example.com/repo</root><uuid>fixture-uuid</uuid></repository>)"
           R"(<wc-info><wcroot-abspath>C:\wc</wcroot-abspath><schedule>normal</schedule>)"
           R"(<depth>infinity</depth></wc-info></entry></info>)";
}

bool log_contains(const std::vector<std::string>& lines, const std::string& value) {
    return std::find(lines.begin(), lines.end(), value) != lines.end();
}

TEST(CredentialScope, IsolatesSchemeHostAndPort) {
    const auto https = CredentialScope::from_repository_url("https://Example.COM/repo");
    const auto plain = CredentialScope::from_repository_url("http://example.com/repo");
    const auto port = CredentialScope::from_repository_url("https://example.com:8443/repo");
    ASSERT_TRUE(https.has_value());
    ASSERT_TRUE(plain.has_value());
    ASSERT_TRUE(port.has_value());
    EXPECT_EQ(https->storage_key(), "https://example.com");
    EXPECT_EQ(plain->storage_key(), "http://example.com");
    EXPECT_EQ(port->storage_key(), "https://example.com:8443");
    EXPECT_NE(https->storage_key(), plain->storage_key());
    EXPECT_NE(https->storage_key(), port->storage_key());
    EXPECT_FALSE(CredentialScope::from_repository_url("file:///tmp/repo").has_value());
    EXPECT_FALSE(
        CredentialScope::from_repository_url("https://example.com:99999/repo").has_value());
}

TEST(Service, ReadsStatusAndBuildsUpdatePreview) {
    auto service = test::make_fake_service(test::fake_files("remote-changes", "wc"));
    const StatusSnapshot snapshot = service->status("C:\\wc", false, true);
    EXPECT_EQ(snapshot.entries.size(), 4u);
    EXPECT_EQ(snapshot.server_revision.value_or(0), 2);

    const RemotePreview preview = service->remote_preview("C:\\wc");
    EXPECT_EQ(preview.changes.size(), 3u);
    EXPECT_EQ(preview.server_revision.value_or(0), 2);
}

TEST(Service, ReadsInfoLogAndDiff) {
    test::TempDir temp;
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_DIFF_FILE"] =
        text::path_to_utf8(test::fixtures_dir() / "svn-diff-text.patch");
    auto service = test::make_fake_service(environment);

    const InfoReport report = service->info("C:\\wc");
    ASSERT_NE(report.primary(), nullptr);
    EXPECT_EQ(report.primary()->path, "wc-a");

    const LogPage page = service->log("C:\\wc");
    EXPECT_EQ(page.entries.size(), 4u);
    EXPECT_FALSE(page.has_more);

    const DiffResult diff = service->diff_working_copy("C:\\wc", 3, 20);
    EXPECT_TRUE(diff.is_truncated);
    EXPECT_GT(diff.byte_count, 20u);
    EXPECT_NE(diff.text.find("差异过大"), std::string::npos);

    const DiffResult full = service->diff_working_copy("C:\\wc");
    EXPECT_FALSE(full.is_truncated);
}

TEST(Service, DiffStopsCapturingAtTheRequestedLimitButReportsTheRealSize) {
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_LARGE_BYTES"] = "200000";
    auto service = test::make_fake_service(environment);

    const DiffResult diff = service->diff_working_copy("C:\\wc", 3, 100);
    EXPECT_TRUE(diff.is_truncated);
    EXPECT_LE(diff.text.size(), 300u);
    EXPECT_GE(diff.byte_count, 200000u);
}

TEST(Service, PreviewFailsInsteadOfInventingASafeRiskWhenStatusFails) {
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_FAIL_ON"] = "status";
    environment["OPENSVN_FAKE_FAIL_STDERR"] = "svn: E170001: Authorization failed\n";
    auto service = test::make_fake_service(environment);

    EXPECT_THROW(service->preview_delete({"C:\\wc"}), SVNException);
    EXPECT_THROW(service->preview_revert({"C:\\wc"}), SVNException);
}

TEST(Service, CommitValidatesInputAndRefusesConflicts) {
    test::TempDir temp;
    auto service = test::make_fake_service(test::fake_files("clean", "wc"));
    EXPECT_THROW(service->commit({}, "message"), SVNException);
    EXPECT_THROW(service->commit({temp.path()}, "   "), SVNException);

    const auto log_path = temp.path() / "argv.log";
    auto conflict_environment = test::fake_files("conflicted", "wc");
    conflict_environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    auto conflict_service = test::make_fake_service(conflict_environment);

    try {
        conflict_service->commit({"C:\\wc"}, "attempt", std::nullopt, {});
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::conflict_remains);
    }
    const auto lines = test::read_lines(log_path);
    EXPECT_FALSE(log_contains(lines, "ARG|commit"));
}

TEST(Service, SuccessfulCommitReportsRevisionAndClearsJournal) {
    test::TempDir temp;
    auto journal = std::make_shared<OperationJournal>(temp.path(), "run");
    auto service = test::make_fake_service(
        test::fake_files("clean", "wc"), nullptr, journal);

    const CommitSummary summary = service->commit({"C:\\wc"}, "fix the bug");
    EXPECT_EQ(summary.revision.value_or(0), 7);
    EXPECT_TRUE(journal->all_entries().empty());
}

TEST(Service, TimedOutCommitKeepsItsRecoveryRecord) {
    test::TempDir temp;
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_COMMIT_SLEEP_MS"] = "1000";
    auto journal = std::make_shared<OperationJournal>(temp.path(), "run");
    auto service = test::make_fake_service(environment, nullptr, journal,
                                           std::chrono::milliseconds(150));

    try {
        service->commit({"C:\\wc"}, "may have reached the server");
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::timeout);
        EXPECT_NE(error.error().message.find("提交结果未知"), std::string::npos);
    }
    OperationJournal next_run(temp.path(), "next-run");
    ASSERT_EQ(next_run.unfinished().size(), 1u);
    EXPECT_EQ(next_run.unfinished().front().kind, OperationJournal::EntryKind::commit);
}

TEST(Service, CredentialTravelsThroughStdinAndIsPersistedAfterSuccess) {
    test::TempDir temp;
    const auto info_path = temp.path() / "http-info.xml";
    test::write_text(info_path, http_info_fixture());
    const auto log_path = temp.path() / "argv.log";

    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_INFO_FILE"] = text::path_to_utf8(info_path);
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);

    auto credentials = std::make_shared<InMemoryCredentialStore>();
    auto service = test::make_fake_service(environment, credentials);
    const SVNCredential credential{"alice", "s3cret"};

    const CommitSummary summary =
        service->commit({"C:\\wc"}, "authenticated commit", credential);
    EXPECT_EQ(summary.revision.value_or(0), 7);

    const auto lines = test::read_lines(log_path);
    EXPECT_TRUE(log_contains(lines, "ARG|--username"));
    EXPECT_TRUE(log_contains(lines, "ARG|alice"));
    EXPECT_TRUE(log_contains(lines, "ARG|--password-from-stdin"));
    EXPECT_TRUE(log_contains(lines, "STDIN|s3cret"));

    const auto stored =
        credentials->credential(CredentialScope{"http://example.com"});
    ASSERT_TRUE(stored.has_value());
    EXPECT_EQ(stored->username, "alice");
}

TEST(Service, RejectedStoredCredentialIsRemovedAndReported) {
    test::TempDir temp;
    const auto info_path = temp.path() / "http-info.xml";
    test::write_text(info_path, http_info_fixture());

    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_INFO_FILE"] = text::path_to_utf8(info_path);
    environment["OPENSVN_FAKE_FAIL_ON"] = "commit";
    environment["OPENSVN_FAKE_FAIL_STDERR"] = "svn: E170001: Authorization failed\n";

    auto credentials = std::make_shared<InMemoryCredentialStore>();
    credentials->save({"alice", "stale"}, CredentialScope{"http://example.com"});
    auto service = test::make_fake_service(environment, credentials);

    try {
        service->commit({"C:\\wc"}, "will fail");
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::authentication_required);
    }
    EXPECT_FALSE(
        credentials->credential(CredentialScope{"http://example.com"}).has_value());
}

TEST(Service, DeleteAndRevertRequireConfirmationAtTheServiceLayer) {
    test::TempDir temp;
    auto service = test::make_fake_service(test::fake_files("conflicted", "wc"));

    const auto delete_preview = service->preview_delete({"C:\\wc"});
    EXPECT_FALSE(delete_preview.discarded_paths.empty());
    EXPECT_EQ(delete_preview.risk, OperationPreview::Risk::high);
    try {
        service->delete_paths({"C:\\wc"}, false);
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::confirmation_required);
    }
    service->delete_paths({"C:\\wc"}, true);

    try {
        service->revert({"C:\\wc"}, true, false);
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::confirmation_required);
        EXPECT_NE(error.error().diagnostic_output.value_or("").find("未纳入版本控制"),
                  std::string::npos);
    }
    service->revert({"C:\\wc"}, true, true);
}

TEST(Service, UpdateParsesProgressAndReadsTheNewRevisionFromInfo) {
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_UPDATE_OUTPUT"] = "U    file.txt\nG    merged.txt";
    auto service = test::make_fake_service(environment);

    const UpdateSummary summary = service->update("C:\\wc");
    EXPECT_EQ(summary.to_revision.value_or(0), 4);
    ASSERT_EQ(summary.updated_paths.size(), 1u);
    EXPECT_EQ(summary.updated_paths[0], "file.txt");
}

TEST(Service, PropertiesCanBeReadAndWritten) {
    test::TempDir temp;
    const auto properties_file = temp.path() / "properties.xml";
    const auto property_log = temp.path() / "properties.log";
    test::write_text(properties_file,
                     "<properties><target path=\"C:\\wc\">"
                     "<property name=\"svn:ignore\">build</property>"
                     "</target></properties>");

    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_PROPERTIES_FILE"] = text::path_to_utf8(properties_file);
    environment["OPENSVN_FAKE_PROPERTY_LOG"] = text::path_to_utf8(property_log);
    const auto snapshot = temp.path() / "property-value.txt";
    environment["OPENSVN_FAKE_PROPERTY_SNAPSHOT"] = text::path_to_utf8(snapshot);
    auto journal = std::make_shared<OperationJournal>(temp.path() / "journal", "run");
    auto service = test::make_fake_service(environment, nullptr, journal);

    const auto targets = service->properties("C:\\wc");
    ASSERT_EQ(targets.size(), 1u);
    EXPECT_EQ(service->property_value("svn:ignore", "C:\\wc").value_or(""), "build");

    service->set_property("custom:owner", "alice", {"C:\\wc"});
    EXPECT_EQ(test::read_text(snapshot), "alice");
    const auto lines = test::read_lines(property_log);
    EXPECT_TRUE(log_contains(lines, "propset"));
    EXPECT_TRUE(log_contains(lines, "custom:owner"));
    EXPECT_TRUE(log_contains(lines, "-F"));
    EXPECT_TRUE(log_contains(lines, "--"));
    const auto file_argument = std::find(lines.begin(), lines.end(), "-F");
    ASSERT_NE(file_argument, lines.end());
    ASSERT_LT(std::distance(lines.begin(), file_argument) + 1, lines.size());
    const std::string temporary_value = *(file_argument + 1);
    EXPECT_FALSE(std::filesystem::exists(text::path_from_utf8(temporary_value)));
    EXPECT_TRUE(journal->all_entries().empty());
}

TEST(Service, IgnoreOutcomeDistinguishesAddedFromAlreadyIgnored) {
    test::TempDir temp;
    const auto properties_file = temp.path() / "properties.xml";
    test::write_text(properties_file, "<properties/>");
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_PROPERTIES_FILE"] = text::path_to_utf8(properties_file);
    auto service = test::make_fake_service(environment);

    std::filesystem::create_directories(temp.path() / ".svn");
    test::write_text(temp.path() / "a.txt", "a");
    test::write_text(temp.path() / "b.txt", "b");

    const IgnoreOutcome outcome = service->ignore({temp.path() / "a.txt", temp.path() / "b.txt"});
    ASSERT_EQ(outcome.added.size(), 2u);
    EXPECT_TRUE(outcome.already.empty());
    EXPECT_TRUE(outcome.changed_anything());
}

TEST(Service, ResolveBacksUpFirstAndReportsResidualMarkers) {
    test::TempDir temp;
    const auto working_copy = temp.path() / "wc";
    std::filesystem::create_directories(working_copy / ".svn");
    const auto file = working_copy / "f.txt";
    test::write_text(file, "original conflict\n");

    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_RESOLVE_WRITE"] = text::path_to_utf8(file);
    environment["OPENSVN_FAKE_RESOLVE_TEXT"] =
        "<<<<<<< .mine\nmine\n=======\ntheirs\n>>>>>>> .r2\n";
    auto service = test::make_fake_service(environment, nullptr, nullptr,
                                           std::chrono::seconds(10),
                                           temp.path() / "backups");

    const ResolveOutcome outcome =
        service->resolve({file}, ResolveStrategy::working, false, true);
    ASSERT_TRUE(outcome.backup.has_value());
    EXPECT_FALSE(outcome.backup->files.empty());
    EXPECT_TRUE(std::filesystem::exists(text::path_from_utf8(outcome.backup->directory)));
    const auto residual = outcome.paths_with_residual_markers();
    ASSERT_EQ(residual.size(), 1u);
    EXPECT_EQ(residual[0], text::path_to_utf8(file));
}

TEST(Service, LockingAndUnlockingUseTheRepositoryMessages) {
    auto service = test::make_fake_service(test::fake_files("clean", "wc"));

    const LockOutcome lock = service->lock({"C:\\wc\\a.txt"}, std::nullopt, false, false);
    ASSERT_EQ(lock.locked_paths.size(), 1u);
    EXPECT_EQ(lock.owner.value_or(""), "tester");

    const UnlockOutcome unlock =
        service->unlock({"C:\\wc\\a.txt"}, false, false);
    ASSERT_EQ(unlock.unlocked_paths.size(), 1u);

    EXPECT_THROW(service->lock({"C:\\wc\\a.txt"}, "steal", true, false), SVNException);
    EXPECT_THROW(service->unlock({"C:\\wc\\a.txt"}, true, false), SVNException);
}

TEST(Service, ConflictArtifactsComeFromTheInfoDocument) {
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_INFO_FILE"] =
        text::path_to_utf8(test::fixtures_dir() / "svn-info-conflict.xml");
    auto service = test::make_fake_service(environment);

    const auto artifacts = service->conflict_artifacts("C:\\wc\\f.txt");
    ASSERT_TRUE(artifacts.has_value());
    EXPECT_EQ(artifacts->type, "text");
    EXPECT_EQ(artifacts->source_right_revision.value_or(0), 2);
}

TEST(Service, CredentialScopesCanBeListedAndForgotten) {
    auto credentials = std::make_shared<InMemoryCredentialStore>();
    credentials->save({"alice", "x"}, CredentialScope{"one.example"});
    credentials->save({"bob", "y"}, CredentialScope{"two.example", "realm"});
    auto service = test::make_fake_service(test::fake_files("clean", "wc"), credentials);

    EXPECT_EQ(service->credential_scopes().size(), 2u);
    service->forget_credential(CredentialScope{"one.example"});
    const auto scopes = service->credential_scopes();
    ASSERT_EQ(scopes.size(), 1u);
    EXPECT_EQ(scopes[0].host, "two.example");
    service->forget_all_credentials();
    EXPECT_TRUE(service->credential_scopes().empty());
}

class FailingCredentialStore : public CredentialStoring {
public:
    std::optional<SVNCredential> credential(const CredentialScope&) override {
        return std::nullopt;
    }
    void save(const SVNCredential&, const CredentialScope&) override {}
    void remove(const CredentialScope&) override {
        throw CredentialStoreError(5, "access denied");
    }
    void remove_all() override { throw CredentialStoreError(5, "access denied"); }
    std::vector<CredentialScope> scopes() override {
        throw CredentialStoreError(5, "access denied");
    }
};

TEST(Service, CredentialStoreFailuresAreNotReportedAsSuccessOrEmpty) {
    auto credentials = std::make_shared<FailingCredentialStore>();
    auto service = test::make_fake_service(test::fake_files("clean", "wc"), credentials);

    EXPECT_THROW(service->credential_scopes(), CredentialStoreError);
    EXPECT_THROW(service->forget_credential(CredentialScope{"https://example.com"}),
                 CredentialStoreError);
    EXPECT_THROW(service->forget_all_credentials(), CredentialStoreError);
}

TEST(Service, DeletePropertyHonoursCancellation) {
    auto service = test::make_fake_service(test::fake_files("clean", "wc"));
    std::stop_source stop;
    stop.request_stop();
    try {
        service->delete_property("svn:ignore", {"C:\\wc"}, stop.get_token());
        FAIL() << "expected cancellation";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::cancelled);
    }
}

TEST(Service, AddRespectsIgnoreRulesUnlessExplicitlyAsked) {
    test::TempDir temp;
    std::filesystem::create_directories(temp.path() / ".svn");
    const auto log_path = temp.path() / "argv.log";
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    auto service = test::make_fake_service(environment);
    const auto file = temp.path() / "a.txt";

    service->add({file});
    auto lines = test::read_lines(log_path);
    EXPECT_FALSE(log_contains(lines, "ARG|--no-ignore"));

    std::error_code error_code;
    std::filesystem::remove(log_path, error_code);
    service->add({file}, false, true);
    lines = test::read_lines(log_path);
    EXPECT_TRUE(log_contains(lines, "ARG|--no-ignore"));
}

TEST(Service, SeparatorProtectsPathsAndKeepsAuthOptionsBeforeIt) {
    test::TempDir temp;
    const auto info_path = temp.path() / "http-info.xml";
    test::write_text(info_path, http_info_fixture());
    const auto log_path = temp.path() / "argv.log";

    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_INFO_FILE"] = text::path_to_utf8(info_path);
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    auto service = test::make_fake_service(environment);

    service->commit({"C:\\wc"}, "message", SVNCredential{"alice", "s3cret"});

    const auto lines = test::read_lines(log_path);
    const auto commit = std::find(lines.begin(), lines.end(), "ARG|commit");
    ASSERT_NE(commit, lines.end());
    const auto separator = std::find(commit, lines.end(), "ARG|--");
    const auto username = std::find(commit, lines.end(), "ARG|--username");
    const auto password = std::find(commit, lines.end(), "ARG|--password-from-stdin");
    const auto path = std::find(commit, lines.end(), "ARG|C:\\wc");
    ASSERT_NE(separator, lines.end());
    ASSERT_NE(username, lines.end());
    ASSERT_NE(password, lines.end());
    ASSERT_NE(path, lines.end());
    EXPECT_LT(username, separator);
    EXPECT_LT(password, separator);
    EXPECT_LT(separator, path);
}

TEST(Service, CommitMessageThatLooksLikeSeparatorStillReachesSvn) {
    test::TempDir temp;
    const auto log_path = temp.path() / "argv.log";
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    auto service = test::make_fake_service(environment);

    service->commit({"C:\\wc"}, "--");

    const auto lines = test::read_lines(log_path);
    const auto commit = std::find(lines.begin(), lines.end(), "ARG|commit");
    ASSERT_NE(commit, lines.end());
    const auto message = std::find(commit, lines.end(), "ARG|--");
    ASSERT_NE(message, lines.end());
    ASSERT_NE(message, commit);
    EXPECT_EQ(*(message - 1), "ARG|-m");
    const auto separator = std::find(message + 1, lines.end(), "ARG|--");
    ASSERT_NE(separator, lines.end());
    const auto path = std::find(separator, lines.end(), "ARG|C:\\wc");
    ASSERT_NE(path, lines.end());
}

TEST(Service, CommandFailureDetailIsRedacted) {
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_EXIT"] = "1";
    environment["OPENSVN_FAKE_STDERR"] =
        "svn: E123456: login failed --password=hunter2 token=abc123";
    auto service = test::make_fake_service(environment);

    try {
        service->status("C:\\wc");
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::command_failed);
        EXPECT_EQ(error.error().message.find("hunter2"), std::string::npos);
        EXPECT_EQ(error.error().message.find("abc123"), std::string::npos);
        const std::string detail = error.error().diagnostic_output.value_or("");
        EXPECT_EQ(detail.find("hunter2"), std::string::npos);
        EXPECT_EQ(detail.find("abc123"), std::string::npos);
    }
}

TEST(Service, WritesRejectEmptyPathsAndPathsFromDifferentWorkingCopies) {
    test::TempDir temp;
    const auto first = temp.path() / "one";
    const auto second = temp.path() / "two";
    std::filesystem::create_directories(first / ".svn");
    std::filesystem::create_directories(second / ".svn");
    auto service = test::make_fake_service(test::fake_files("clean", "wc"));

    try {
        service->add({first / "a.txt", second / "b.txt"});
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::invalid_invocation);
    }

    try {
        service->delete_paths({std::filesystem::path{}}, true);
        FAIL() << "expected SVNException";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::invalid_invocation);
    }

    EXPECT_THROW(service->set_property("--config-option", "x", {"C:\\wc"}),
                 SVNException);
}

TEST(UpdateOutput, ParsesPropertyTreeAndCombinedConflictColumns) {
    const std::string output =
        "Updating '.':\n"
        "U    updated.txt\n"
        "A    added.txt\n"
        "G    merged file.txt\n"
        " C   props.txt\n"
        "UC   text-and-prop.txt\n"
        "   C tree conflict.txt\n"
        " U   prop-only.txt\n"
        "D    removed.txt\n"
        "U    ../../中文 路径.txt\n"
        " C   repeated.txt\n"
        "U    repeated.txt\n"
        "Updated to revision 8.\n";
    const auto parsed = SVNOutputParser::parse_update(output);
    EXPECT_EQ(parsed.added, std::vector<std::string>{"added.txt"});
    EXPECT_EQ(parsed.merged, std::vector<std::string>{"merged file.txt"});
    EXPECT_EQ(parsed.deleted, std::vector<std::string>{"removed.txt"});
    EXPECT_EQ(parsed.updated,
              (std::vector<std::string>{"updated.txt", "prop-only.txt",
                                        "../../中文 路径.txt"}));
    EXPECT_EQ(parsed.conflicted,
              (std::vector<std::string>{"props.txt", "text-and-prop.txt",
                                        "tree conflict.txt", "repeated.txt"}));
}

TEST(Service, CommitLimitsANormalDirectoryToItsExplicitTarget) {
    test::TempDir temp;
    const auto working_copy = temp.path() / "wc";
    std::filesystem::create_directories(working_copy / ".svn");
    const auto status_file = temp.path() / "status.xml";
    test::write_text(status_file, status_xml_for_directory(working_copy, "normal", "modified"));
    const auto log_path = temp.path() / "argv.log";

    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_STATUS_FILE"] = text::path_to_utf8(status_file);
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    auto service = test::make_fake_service(environment);

    service->commit({working_copy}, "property-only directory");

    const auto lines = test::read_lines(log_path);
    const auto commit = std::find(lines.begin(), lines.end(), "ARG|commit");
    ASSERT_NE(commit, lines.end());
    const auto separator = std::find(commit, lines.end(), "ARG|--");
    ASSERT_NE(separator, lines.end());
    EXPECT_NE(std::find(commit, separator, "ARG|--depth"), separator);
    EXPECT_NE(std::find(commit, separator, "ARG|empty"), separator);
    EXPECT_NE(std::find(separator, lines.end(), "ARG|" +
                           text::path_to_utf8(working_copy)),
              lines.end());
}

TEST(Service, CommitRestrictsAnAddedDirectoryToTheExplicitSelection) {
    test::TempDir temp;
    const auto working_copy = temp.path() / "wc";
    std::filesystem::create_directories(working_copy / ".svn");
    const auto status_file = temp.path() / "status.xml";
    test::write_text(status_file, status_xml_for_directory(working_copy, "added", "none"));
    const auto log_path = temp.path() / "argv.log";

    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_STATUS_FILE"] = text::path_to_utf8(status_file);
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    auto service = test::make_fake_service(environment);

    service->commit({working_copy}, "new directory");

    const auto lines = test::read_lines(log_path);
    const auto commit = std::find(lines.begin(), lines.end(), "ARG|commit");
    ASSERT_NE(commit, lines.end());
    const auto separator = std::find(commit, lines.end(), "ARG|--");
    ASSERT_NE(separator, lines.end());
    EXPECT_NE(std::find(commit, separator, "ARG|--depth"), separator);
    EXPECT_NE(std::find(commit, separator, "ARG|empty"), separator);
    // The status snapshot lists child.txt, but it was not selected.
    const auto child = text::path_to_utf8(working_copy / "child.txt");
    EXPECT_EQ(std::find(separator, lines.end(), "ARG|" + child), lines.end());
}

TEST(Service, CommitLeavesRecursiveCopiesToSvn) {
    test::TempDir temp;
    const auto working_copy = temp.path() / "wc";
    const auto copied = working_copy / "copied";
    std::filesystem::create_directories(working_copy / ".svn");
    std::filesystem::create_directories(copied);
    const auto status_file = temp.path() / "status.xml";
    test::write_text(
        status_file,
        "<status><target path=\"" + xml_escape(text::path_to_utf8(working_copy)) + "\">"
        "<entry path=\"" + xml_escape(text::path_to_utf8(copied)) +
            "\"><wc-status item=\"added\" revision=\"-1\" props=\"none\" "
            "copied=\"true\"><commit revision=\"4\"><author>fixture</author></commit>"
            "</wc-status></entry></target></status>");
    const auto log_path = temp.path() / "argv.log";

    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_STATUS_FILE"] = text::path_to_utf8(status_file);
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    auto service = test::make_fake_service(environment);

    service->commit({copied}, "copied directory");

    // svn itself performs copies recursively even when the commit depth is
    // empty; this service relies on that documented behaviour.
    const auto lines = test::read_lines(log_path);
    const auto commit = std::find(lines.begin(), lines.end(), "ARG|commit");
    ASSERT_NE(commit, lines.end());
    const auto separator = std::find(commit, lines.end(), "ARG|--");
    ASSERT_NE(separator, lines.end());
    EXPECT_NE(std::find(commit, separator, "ARG|--depth"), separator);
    EXPECT_NE(std::find(commit, separator, "ARG|empty"), separator);
    EXPECT_NE(std::find(separator, lines.end(), "ARG|" + text::path_to_utf8(copied)),
              lines.end());
}

TEST(Service, CommitRestrictsAMixedDirectorySelectionForEveryTarget) {
    test::TempDir temp;
    const auto working_copy = temp.path() / "wc";
    const auto normal = working_copy / "existing";
    const auto added = working_copy / "added";
    std::filesystem::create_directories(working_copy / ".svn");
    std::filesystem::create_directories(normal);
    std::filesystem::create_directories(added);
    const auto unselected = normal / "unselected.txt";
    test::write_text(unselected, "must not be committed");

    const auto status_file = temp.path() / "status.xml";
    test::write_text(
        status_file,
        "<status><target path=\"" + xml_escape(text::path_to_utf8(working_copy)) + "\">"
        "<entry path=\"" + xml_escape(text::path_to_utf8(normal)) +
            "\"><wc-status item=\"normal\" revision=\"4\" props=\"modified\"/></entry>"
        "<entry path=\"" + xml_escape(text::path_to_utf8(unselected)) +
            "\"><wc-status item=\"modified\" revision=\"4\" props=\"none\"/></entry>"
        "<entry path=\"" + xml_escape(text::path_to_utf8(added)) +
            "\"><wc-status item=\"added\" revision=\"-1\" props=\"none\"/></entry>"
        "</target></status>");
    const auto log_path = temp.path() / "argv.log";

    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_STATUS_FILE"] = text::path_to_utf8(status_file);
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    auto service = test::make_fake_service(environment);

    service->commit({normal, added}, "mixed directory selection");

    const auto lines = test::read_lines(log_path);
    const auto commit = std::find(lines.begin(), lines.end(), "ARG|commit");
    ASSERT_NE(commit, lines.end());
    const auto separator = std::find(commit, lines.end(), "ARG|--");
    ASSERT_NE(separator, lines.end());
    EXPECT_NE(std::find(commit, separator, "ARG|--depth"), separator);
    EXPECT_NE(std::find(commit, separator, "ARG|empty"), separator);
    std::vector<std::string> targets;
    for (auto line = separator + 1; line != lines.end(); ++line) {
        if (!line->empty()) targets.push_back(*line);
    }
    EXPECT_EQ(targets, (std::vector<std::string>{
                           "ARG|" + text::path_to_utf8(normal),
                           "ARG|" + text::path_to_utf8(added)}));
    EXPECT_EQ(std::find(targets.begin(), targets.end(),
                        "ARG|" + text::path_to_utf8(unselected)),
              targets.end());
}

TEST(Service, CommitPreflightCancellationStopsBeforeTheNextStatusAndCommit) {
    test::TempDir temp;
    const auto working_copy = temp.path() / "wc";
    std::filesystem::create_directories(working_copy / ".svn");
    test::write_text(working_copy / "a.txt", "a");
    test::write_text(working_copy / "b.txt", "b");
    const auto log_path = temp.path() / "argv.log";

    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    environment["OPENSVN_FAKE_SLEEP_MS"] = "800";
    auto journal = std::make_shared<OperationJournal>(temp.path() / "journal", "run");
    auto service = test::make_fake_service(environment, nullptr, journal);

    std::stop_source stop;
    std::optional<SVNErrorCode> code;
    std::thread worker([&] {
        try {
            service->commit({working_copy / "a.txt", working_copy / "b.txt"},
                            "cancel during preflight", std::nullopt, {}, stop.get_token());
        } catch (const SVNException& error) {
            code = error.error().code;
        }
    });

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!std::filesystem::exists(log_path) &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    const auto cancel_started = std::chrono::steady_clock::now();
    stop.request_stop();
    worker.join();
    const auto elapsed = std::chrono::steady_clock::now() - cancel_started;

    ASSERT_TRUE(code.has_value());
    EXPECT_EQ(*code, SVNErrorCode::cancelled);
    EXPECT_LT(elapsed, std::chrono::milliseconds(700));
    const std::string contents = test::read_text(log_path);
    std::size_t status_calls = 0;
    for (std::size_t at = contents.find("ARG|status"); at != std::string::npos;
         at = contents.find("ARG|status", at + 1)) {
        ++status_calls;
    }
    EXPECT_EQ(status_calls, 1u);
    EXPECT_EQ(contents.find("ARG|commit"), std::string::npos);
    EXPECT_TRUE(journal->all_entries().empty());
}

TEST(Service, EmptyCommitResultFromPreflightLeavesNoRecoveryRecord) {
    test::TempDir temp;
    const auto working_copy = temp.path() / "wc";
    std::filesystem::create_directories(working_copy / ".svn");
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_SLEEP_MS"] = "1000";
    auto journal = std::make_shared<OperationJournal>(temp.path() / "journal", "run");
    auto service = test::make_fake_service(environment, nullptr, journal);

    std::stop_source stop;
    stop.request_stop();
    EXPECT_THROW(service->commit({working_copy}, "never launched", std::nullopt, {},
                                 stop.get_token()),
                 SVNException);
    EXPECT_TRUE(journal->all_entries().empty());
}

TEST(Service, EscapesLiteralAtSignsInTargetsButNotInCheckoutDestination) {
    test::TempDir temp;
    const auto log_path = temp.path() / "argv.log";
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    auto service = test::make_fake_service(environment);

    const std::filesystem::path at_path = "C:\\wc\\asset@2x.png";
    service->status(at_path);
    auto lines = test::read_lines(log_path);
    EXPECT_TRUE(log_contains(lines, "ARG|C:\\wc\\asset@2x.png@"));

    std::filesystem::remove(log_path);
    service->info("C:\\wc\\news@11");
    lines = test::read_lines(log_path);
    EXPECT_TRUE(log_contains(lines, "ARG|C:\\wc\\news@11@"));

    std::filesystem::remove(log_path);
    service->diff_working_copy("C:\\wc\\name@");
    lines = test::read_lines(log_path);
    EXPECT_TRUE(log_contains(lines, "ARG|C:\\wc\\name@@"));

    std::filesystem::remove(log_path);
    service->update(text::path_from_utf8("C:\\wc\\名字 空格@2x"));
    lines = test::read_lines(log_path);
    EXPECT_TRUE(log_contains(lines, "ARG|C:\\wc\\名字 空格@2x@"));
    // The repository lookup runs `info` on the same target; it must not apply
    // the literal-@ escape a second time.
    EXPECT_FALSE(log_contains(lines, "ARG|C:\\wc\\名字 空格@2x@@"));

    const auto destination = temp.path() / "checkout@2x";
    std::filesystem::create_directories(destination);
    std::filesystem::remove(log_path);
    service->checkout("http://example.com/repo", destination);
    lines = test::read_lines(log_path);
    EXPECT_TRUE(log_contains(lines, "ARG|" + text::path_to_utf8(destination)));
    EXPECT_FALSE(log_contains(lines, "ARG|" + text::path_to_utf8(destination) + "@"));
}

TEST(Service, PropertyValueFileIsNotPegEscaped) {
    test::TempDir temp;
    const auto properties_file = temp.path() / "properties.xml";
    const auto property_log = temp.path() / "properties.log";
    test::write_text(properties_file, "<properties/>");
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_PROPERTIES_FILE"] = text::path_to_utf8(properties_file);
    environment["OPENSVN_FAKE_PROPERTY_LOG"] = text::path_to_utf8(property_log);
    auto service = test::make_fake_service(environment);

    service->set_property("custom:owner", "alice", {"C:\\wc\\asset@2x.png"});
    const auto lines = test::read_lines(property_log);
    EXPECT_TRUE(log_contains(lines, "C:\\wc\\asset@2x.png@"));
    const auto file_argument = std::find(lines.begin(), lines.end(), "-F");
    ASSERT_NE(file_argument, lines.end());
    ASSERT_LT(std::distance(lines.begin(), file_argument) + 1, lines.size());
    const std::string temporary = *(file_argument + 1);
    EXPECT_FALSE(temporary.empty());
    EXPECT_NE(temporary.back(), '@');
}

TEST(Service, UpdatePinsTheConfirmedRevision) {
    test::TempDir temp;
    const auto log_path = temp.path() / "argv.log";
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    auto service = test::make_fake_service(environment);

    service->update("C:\\wc", 8);

    const auto lines = test::read_lines(log_path);
    const auto update = std::find(lines.begin(), lines.end(), "ARG|update");
    ASSERT_NE(update, lines.end());
    const auto revision = std::find(update, lines.end(), "ARG|-r");
    ASSERT_NE(revision, lines.end());
    ASSERT_LT(std::distance(lines.begin(), revision) + 1, lines.size());
    EXPECT_EQ(*(revision + 1), "ARG|8");
}

TEST(Service, UpdateSummaryCarriesAddedMergedAndVerifiedConflicts) {
    test::TempDir temp;
    const auto status_file = temp.path() / "status.xml";
    test::write_text(
        status_file,
        "<status><target path=\"C:\\wc\">"
        "<entry path=\"C:\\wc\\verified-conflict.txt\">"
        "<wc-status item=\"conflicted\" revision=\"5\" props=\"none\"/></entry>"
        "</target></status>");
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_STATUS_FILE"] = text::path_to_utf8(status_file);
    environment["OPENSVN_FAKE_UPDATE_OUTPUT"] =
        "U    updated.txt\n"
        "A    added.txt\n"
        "G    merged.txt\n"
        "UC   parser-conflict.txt";
    auto service = test::make_fake_service(environment);

    const UpdateSummary summary = service->update("C:\\wc");
    EXPECT_EQ(summary.updated_paths, std::vector<std::string>{"updated.txt"});
    EXPECT_EQ(summary.added_paths, std::vector<std::string>{"added.txt"});
    EXPECT_EQ(summary.merged_paths, std::vector<std::string>{"merged.txt"});
    EXPECT_EQ(summary.conflicted_paths,
              std::vector<std::string>{"C:\\wc\\verified-conflict.txt"});
    EXPECT_TRUE(summary.conflicts_verified);
}

TEST(Service, UpdateReportsUnknownConflictStateWhenStatusCannotBeRead) {
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_UPDATE_OUTPUT"] = " C   props.txt\nUC   both.txt";
    environment["OPENSVN_FAKE_FAIL_ON"] = "status";
    environment["OPENSVN_FAKE_FAIL_STDERR"] = "svn: E155004: locked\n";
    auto service = test::make_fake_service(environment);

    const UpdateSummary summary = service->update("C:\\wc");
    EXPECT_FALSE(summary.conflicts_verified);
    EXPECT_EQ(summary.conflicted_paths,
              (std::vector<std::string>{"props.txt", "both.txt"}));
}

TEST(Service, EncodedPropertyCannotBeOverwrittenAsText) {
    test::TempDir temp;
    const auto properties_file = temp.path() / "properties.xml";
    const auto property_log = temp.path() / "properties.log";
    test::write_text(
        properties_file,
        "<properties><target path=\"C:\\wc\">"
        "<property name=\"custom:binary\" encoding=\"base64\">AAE=</property>"
        "</target></properties>");
    auto environment = test::fake_files("clean", "wc");
    environment["OPENSVN_FAKE_PROPERTIES_FILE"] = text::path_to_utf8(properties_file);
    environment["OPENSVN_FAKE_PROPERTY_LOG"] = text::path_to_utf8(property_log);
    auto service = test::make_fake_service(environment);

    try {
        service->set_property("custom:binary", "AAE=", {"C:\\wc"});
        FAIL() << "expected encoded property to be rejected";
    } catch (const SVNException& error) {
        EXPECT_EQ(error.error().code, SVNErrorCode::invalid_invocation);
        EXPECT_NE(error.error().message.find("base64"), std::string::npos);
    }
    EXPECT_FALSE(std::filesystem::exists(property_log));
}

} // namespace
} // namespace opensvn
