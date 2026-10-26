#include "opensvn/capi.h"

#include "test_support.hpp"

#include <nlohmann/json.hpp>

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace opensvn::test {
namespace {

using Json = nlohmann::json;

struct Response {
    std::optional<Json> value;
    std::optional<Json> error;
};

Response invoke(opensvn_service* service, const std::string& operation, const Json& parameters,
                std::uint64_t request_id = 0, opensvn_progress_callback progress = nullptr,
                void* user_data = nullptr) {
    char* error_text = nullptr;
    char* result_text = opensvn_invoke(service, request_id, operation.c_str(),
                                       parameters.dump().c_str(), progress, user_data,
                                       &error_text);
    Response response;
    if (result_text) {
        response.value = Json::parse(result_text);
        opensvn_free_string(result_text);
    }
    if (error_text) {
        response.error = Json::parse(error_text);
        opensvn_free_string(error_text);
    }
    return response;
}

class CapiTest : public ::testing::Test {
protected:
    void SetUp() override {
        directory_ = std::make_unique<TempDir>();
        base_config_ = Json{
            {"svnPath", text::path_to_utf8(fake_svn_path())},
            {"inMemoryCredentials", true},
            {"journalDirectory", text::path_to_utf8(directory_->path() / "state")},
            {"conflictBackupRoot", text::path_to_utf8(directory_->path() / "backups")},
            {"environment",
             Json{
                 {"OPENSVN_FAKE_STATUS_FILE",
                  text::path_to_utf8(fixtures_dir() / "svn-status-conflicted.xml")},
                 {"OPENSVN_FAKE_INFO_FILE",
                  text::path_to_utf8(fixtures_dir() / "svn-info-wc.xml")},
                 {"OPENSVN_FAKE_LOG_FILE",
                  text::path_to_utf8(fixtures_dir() / "svn-log.xml")},
                 {"OPENSVN_FAKE_DIFF_FILE",
                  text::path_to_utf8(fixtures_dir() / "svn-diff-text.patch")},
             }},
        };
        char* error_text = nullptr;
        const int created =
            opensvn_create_service(base_config_.dump().c_str(), &service_, &error_text);
        if (!created) {
            creation_error_ = error_text ? error_text : "unknown error";
            opensvn_free_string(error_text);
        }
        ASSERT_EQ(created, 1) << creation_error_;
    }

    void TearDown() override {
        if (service_) opensvn_destroy_service(service_);
    }

    opensvn_service* service_ = nullptr;
    Json base_config_;
    std::unique_ptr<TempDir> directory_;
    std::string creation_error_;
};

TEST_F(CapiTest, ReportsInstallation) {
    const auto response = invoke(service_, "installation", Json::object());
    ASSERT_TRUE(response.value) << response.error->dump();
    EXPECT_EQ((*response.value)["version"], "1.14.5");
    EXPECT_EQ((*response.value)["source"], "explicit");
}

TEST_F(CapiTest, ReturnsStatusJson) {
    const auto response =
        invoke(service_, "status", Json{{"path", text::path_to_utf8(directory_->path())}});
    ASSERT_TRUE(response.value) << response.error->dump();
    const auto& entries = (*response.value)["entries"];
    ASSERT_TRUE(entries.is_array());
    EXPECT_FALSE(entries.empty());
    bool found_conflict = false;
    for (const auto& entry : entries) {
        if (entry["path"] == "wc-a/src/util.swift") {
            found_conflict = entry["item"] == "conflicted";
        }
    }
    EXPECT_TRUE(found_conflict);
}

TEST_F(CapiTest, ServesInfoLogAndDiff) {
    const auto info = invoke(service_, "info", Json{{"target", "wc-a"}});
    ASSERT_TRUE(info.value) << info.error->dump();
    ASSERT_EQ((*info.value)["entries"].size(), 1u);
    EXPECT_NE((*info.value)["entries"][0]["url"].get<std::string>().find("trunk"),
              std::string::npos);

    const auto log = invoke(service_, "log", Json{{"target", "wc-a"}, {"limit", 10}});
    ASSERT_TRUE(log.value) << log.error->dump();
    EXPECT_FALSE((*log.value)["entries"].empty());

    const auto diff = invoke(service_, "diff_working_copy",
                             Json{{"path", text::path_to_utf8(directory_->path())}});
    ASSERT_TRUE(diff.value) << diff.error->dump();
    EXPECT_NE((*diff.value)["text"].get<std::string>().find("local change A"),
              std::string::npos);
}

TEST_F(CapiTest, DestructiveOperationsNeedConfirmation) {
    const auto response = invoke(
        service_, "delete",
        Json{{"paths", Json::array({text::path_to_utf8(directory_->path() / "docs" / "a.txt")})},
             {"confirmed", false}});
    ASSERT_TRUE(response.error);
    EXPECT_EQ((*response.error)["identifier"], "SVN-0501");
}

TEST_F(CapiTest, CancellationStopsTheChildAndReturnsCancelled) {
    Json config = base_config_;
    config["environment"]["OPENSVN_FAKE_SLEEP_MS"] = "4000";
    opensvn_service* cancellable = nullptr;
    char* creation_error = nullptr;
    ASSERT_EQ(opensvn_create_service(config.dump().c_str(), &cancellable, &creation_error), 1)
        << (creation_error ? creation_error : "");
    if (creation_error) opensvn_free_string(creation_error);

    const auto started = std::chrono::steady_clock::now();
    std::optional<Response> response;
    std::thread worker([&] {
        response = invoke(cancellable, "status",
                          Json{{"path", text::path_to_utf8(directory_->path())}}, 41);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(350));
    opensvn_cancel(cancellable, 41);
    worker.join();
    const auto elapsed = std::chrono::steady_clock::now() - started;
    opensvn_destroy_service(cancellable);

    ASSERT_TRUE(response.has_value());
    ASSERT_TRUE(response->error) << (response->value ? response->value->dump() : "no result");
    EXPECT_TRUE((*response->error)["cancelled"].get<bool>());
    EXPECT_LT(elapsed, std::chrono::seconds(4));
}

TEST_F(CapiTest, CancelledRegisteredRequestNeverLaunchesTheChild) {
    Json config = base_config_;
    const auto log_path = directory_->path() / "argv.log";
    config["environment"]["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);

    opensvn_service* cancellable = nullptr;
    char* creation_error = nullptr;
    ASSERT_EQ(opensvn_create_service(config.dump().c_str(), &cancellable, &creation_error), 1)
        << (creation_error ? creation_error : "");
    if (creation_error) opensvn_free_string(creation_error);

    std::filesystem::remove(log_path);
    char* register_error = nullptr;
    ASSERT_EQ(opensvn_register_request(cancellable, 99, &register_error), 1)
        << (register_error ? register_error : "");
    if (register_error) opensvn_free_string(register_error);

    opensvn_cancel(cancellable, 99);
    const auto response = invoke(
        cancellable, "delete",
        Json{{"paths", Json::array({text::path_to_utf8(directory_->path() / "docs" / "a.txt")})},
             {"confirmed", true}},
        99);
    ASSERT_TRUE(response.error);
    EXPECT_TRUE((*response.error)["cancelled"].get<bool>());
    EXPECT_FALSE(std::filesystem::exists(log_path));

    ASSERT_EQ(opensvn_register_request(cancellable, 100, nullptr), 1);
    opensvn_release_request(cancellable, 100);
    opensvn_destroy_service(cancellable);
}

TEST_F(CapiTest, RegisteredRequestCanBeConsumedAndStopsOnCancel) {
    char* register_error = nullptr;
    ASSERT_EQ(opensvn_register_request(service_, 101, &register_error), 1)
        << (register_error ? register_error : "");
    if (register_error) opensvn_free_string(register_error);

    const auto response = invoke(
        service_, "status", Json{{"path", text::path_to_utf8(directory_->path())}}, 101);
    ASSERT_TRUE(response.value) << response.error->dump();
    EXPECT_FALSE((*response.value)["entries"].empty());
}

TEST_F(CapiTest, EarlyInvokeValidationReleasesTheRegistration) {
    opensvn_service* isolated = nullptr;
    char* creation_error = nullptr;
    ASSERT_EQ(opensvn_create_service(base_config_.dump().c_str(), &isolated, &creation_error), 1)
        << (creation_error ? creation_error : "");
    if (creation_error) opensvn_free_string(creation_error);

    char* register_error = nullptr;
    ASSERT_EQ(opensvn_register_request(isolated, 77, &register_error), 1)
        << (register_error ? register_error : "");
    if (register_error) opensvn_free_string(register_error);

    const auto response = invoke(isolated, "", Json::object(), 77);
    ASSERT_TRUE(response.error);
    EXPECT_EQ((*response.error)["identifier"], "SVN-9001");

    // The failed invocation must leave no slot behind, so the id is reusable.
    const int32_t reregistered = opensvn_register_request(isolated, 77, &register_error);
    if (register_error) opensvn_free_string(register_error);
    EXPECT_EQ(reregistered, 1);
    opensvn_release_request(isolated, 77);

    std::packaged_task<void()> destroy([isolated] { opensvn_destroy_service(isolated); });
    auto destroyed = destroy.get_future();
    std::thread destroyer(std::move(destroy));
    if (destroyed.wait_for(std::chrono::seconds(2)) != std::future_status::ready) {
        destroyer.detach();
        FAIL() << "destroy_service still waits for a leaked registration";
    }
    destroyer.join();
}

TEST_F(CapiTest, ReleaseOfARunningRequestKeepsTheServiceAlive) {
    Json config = base_config_;
    opensvn_service* isolated = nullptr;
    char* creation_error = nullptr;
    ASSERT_EQ(opensvn_create_service(config.dump().c_str(), &isolated, &creation_error), 1)
        << (creation_error ? creation_error : "");
    if (creation_error) opensvn_free_string(creation_error);

    char* register_error = nullptr;
    ASSERT_EQ(opensvn_register_request(isolated, 123, &register_error), 1)
        << (register_error ? register_error : "");
    if (register_error) opensvn_free_string(register_error);

    struct ProgressGate {
        std::mutex mutex;
        std::condition_variable condition;
        bool entered = false;
        bool release = false;
    } gate;

    const auto progress = [](const char*, void* data) {
        auto* state = static_cast<ProgressGate*>(data);
        std::unique_lock lock(state->mutex);
        if (state->entered) return;
        state->entered = true;
        state->condition.notify_all();
        state->condition.wait(lock, [&] { return state->release; });
    };

    std::optional<Response> response;
    std::thread worker([&] {
        response = invoke(isolated, "log",
                          Json{{"target", "wc-a"}, {"limit", 10}}, 123, progress, &gate);
    });

    bool started = false;
    {
        std::unique_lock lock(gate.mutex);
        started = gate.condition.wait_for(lock, std::chrono::seconds(5),
                                          [&] { return gate.entered; });
    }
    if (!started) {
        {
            std::lock_guard lock(gate.mutex);
            gate.release = true;
        }
        gate.condition.notify_all();
        worker.join();
        opensvn_destroy_service(isolated);
        FAIL() << "svn log never delivered a progress line";
    }

    opensvn_release_request(isolated, 123);

    std::atomic<bool> destroyed{false};
    std::thread destroyer([&] {
        opensvn_destroy_service(isolated);
        destroyed.store(true);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    const bool returned_early = destroyed.load();

    {
        std::lock_guard lock(gate.mutex);
        gate.release = true;
    }
    gate.condition.notify_all();
    worker.join();
    destroyer.join();

    EXPECT_FALSE(returned_early)
        << "destroy_service freed the handle while opensvn_invoke was still running";
}

TEST_F(CapiTest, UnknownOperationIsAStructuredError) {
    const auto response = invoke(service_, "no_such_operation", Json::object());
    ASSERT_TRUE(response.error);
    EXPECT_EQ((*response.error)["identifier"], "SVN-9001");
}

TEST_F(CapiTest, InvalidUtf8InAnErrorStillCrossesTheBoundaryAsJson) {
    const std::string operation = std::string("bad") + static_cast<char>(0xff);
    char* error_text = nullptr;
    char* result = opensvn_invoke(service_, 0, operation.c_str(), "{}", nullptr, nullptr,
                                  &error_text);
    EXPECT_EQ(result, nullptr);
    ASSERT_NE(error_text, nullptr);
    const Json error = Json::parse(error_text);
    opensvn_free_string(error_text);
    EXPECT_EQ(error["identifier"], "SVN-9001");
    EXPECT_NE(error["message"].get<std::string>().find("bad"), std::string::npos);
}

TEST(CapiCreation, MissingExecutableIsReportedAsNotFound) {
    TempDir directory;
    const auto config = Json{{"svnPath", "Z:\\does-not-exist\\svn.exe"},
                             {"inMemoryCredentials", true},
                             {"journalDirectory", text::path_to_utf8(directory.path())}};
    opensvn_service* service = nullptr;
    char* error_text = nullptr;
    EXPECT_EQ(opensvn_create_service(config.dump().c_str(), &service, &error_text), 0);
    EXPECT_EQ(service, nullptr);
    ASSERT_NE(error_text, nullptr);
    const Json error = Json::parse(error_text);
    opensvn_free_string(error_text);
    EXPECT_EQ(error["identifier"], "SVN-0001");
    EXPECT_EQ(error["severity"], "fatal");
}

TEST_F(CapiTest, DuplicateRequestIdIsRejectedWhileAnInvocationIsRunning) {
    Json config = base_config_;
    const auto log_path = directory_->path() / "argv.log";
    config["environment"]["OPENSVN_FAKE_ARGV_LOG"] = text::path_to_utf8(log_path);
    config["environment"]["OPENSVN_FAKE_SLEEP_MS"] = "3000";

    opensvn_service* slow = nullptr;
    char* creation_error = nullptr;
    ASSERT_EQ(opensvn_create_service(config.dump().c_str(), &slow, &creation_error), 1)
        << (creation_error ? creation_error : "");
    if (creation_error) opensvn_free_string(creation_error);

    // Discovery logged --version already; only the operation's log proves
    // request 77 is registered and its child has started.
    std::filesystem::remove(log_path);

    std::optional<Response> first;
    std::thread worker([&] {
        first = invoke(slow, "status",
                       Json{{"path", text::path_to_utf8(directory_->path())}}, 77);
    });

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!std::filesystem::exists(log_path) &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    const bool child_started = std::filesystem::exists(log_path);
    Response duplicate;
    if (child_started) {
        duplicate = invoke(
            slow, "status", Json{{"path", text::path_to_utf8(directory_->path())}}, 77);
    }

    opensvn_cancel(slow, 77);
    worker.join();
    opensvn_destroy_service(slow);

    ASSERT_TRUE(child_started) << "fake svn never started";
    ASSERT_TRUE(first.has_value());
    ASSERT_TRUE(duplicate.error);
    EXPECT_EQ((*duplicate.error)["identifier"], "SVN-9001");
    EXPECT_NE((*duplicate.error)["message"].get<std::string>().find("request_id"),
              std::string::npos);
}

TEST_F(CapiTest, RejectsEmptyPathsAndOptionLikePropertyNames) {
    const auto status = invoke(service_, "status", Json{{"path", ""}});
    ASSERT_TRUE(status.error);
    EXPECT_EQ((*status.error)["identifier"], "SVN-9001");

    const auto deletion = invoke(
        service_, "delete", Json{{"paths", Json::array({""})}, {"confirmed", true}});
    ASSERT_TRUE(deletion.error);
    EXPECT_EQ((*deletion.error)["identifier"], "SVN-9001");

    const auto property = invoke(
        service_, "set_property",
        Json{{"name", "--config-option"},
             {"value", "x"},
             {"targets", Json::array({text::path_to_utf8(directory_->path())})}});
    ASSERT_TRUE(property.error);
    EXPECT_EQ((*property.error)["identifier"], "SVN-9001");
}

} // namespace
} // namespace opensvn::test
