#include "opensvn/capi.h"

#include "opensvn/credentials.hpp"
#include "opensvn/discovery.hpp"
#include "opensvn/errors.hpp"
#include "opensvn/journal.hpp"
#include "opensvn/json_contract.hpp"
#include "opensvn/models.hpp"
#include "opensvn/service.hpp"
#include "opensvn/text.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <stop_token>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

struct opensvn_service {
    std::shared_ptr<opensvn::SVNService> service;
    std::shared_ptr<opensvn::OperationJournal> journal;
    std::mutex mutex;
    std::condition_variable idle;
    std::unordered_map<std::uint64_t, std::shared_ptr<std::stop_source>> requests;
    std::size_t active_invocations = 0;
    bool closing = false;
};

namespace {

struct InvocationRegistration {
    opensvn_service* handle;
    std::uint64_t request_id;
    std::shared_ptr<std::stop_source> source;

    InvocationRegistration(opensvn_service* owner, std::uint64_t id,
                           std::shared_ptr<std::stop_source> stop_source)
        : handle(owner), request_id(id), source(std::move(stop_source)) {}

    InvocationRegistration(const InvocationRegistration&) = delete;
    InvocationRegistration& operator=(const InvocationRegistration&) = delete;

    ~InvocationRegistration() {
        std::lock_guard lock(handle->mutex);
        if (request_id != 0) {
            const auto iterator = handle->requests.find(request_id);
            if (iterator != handle->requests.end() && iterator->second == source) {
                handle->requests.erase(iterator);
            }
        }
        if (handle->active_invocations > 0) --handle->active_invocations;
        if (handle->active_invocations == 0) handle->idle.notify_all();
    }
};


using opensvn::Json;

[[noreturn]] void invalid(const std::string& message) {
    opensvn::throw_svn_error(opensvn::SVNErrorCode::invalid_invocation, message);
}

const Json& require_object(const Json& parameters) {
    if (!parameters.is_object()) invalid("参数必须是 JSON 对象");
    return parameters;
}

std::string required_string(const Json& parameters, const char* key) {
    const auto iterator = parameters.find(key);
    if (iterator == parameters.end() || !iterator->is_string()) {
        invalid(std::string("缺少字符串参数: ") + key);
    }
    return iterator->get<std::string>();
}

std::optional<std::string> optional_string(const Json& parameters, const char* key) {
    const auto iterator = parameters.find(key);
    if (iterator == parameters.end() || iterator->is_null()) return std::nullopt;
    if (!iterator->is_string()) invalid(std::string("参数类型错误: ") + key);
    return iterator->get<std::string>();
}

bool boolean(const Json& parameters, const char* key, bool fallback) {
    const auto iterator = parameters.find(key);
    if (iterator == parameters.end() || iterator->is_null()) return fallback;
    if (!iterator->is_boolean()) invalid(std::string("参数类型错误: ") + key);
    return iterator->get<bool>();
}

std::optional<std::int64_t> optional_integer(const Json& parameters, const char* key) {
    const auto iterator = parameters.find(key);
    if (iterator == parameters.end() || iterator->is_null()) return std::nullopt;
    if (!iterator->is_number_integer()) invalid(std::string("参数类型错误: ") + key);
    return iterator->get<std::int64_t>();
}

int integer(const Json& parameters, const char* key, int fallback) {
    const auto value = optional_integer(parameters, key);
    if (!value) return fallback;
    if (*value < std::numeric_limits<int>::min() ||
        *value > std::numeric_limits<int>::max()) {
        invalid(std::string("参数超出 int 范围: ") + key);
    }
    return static_cast<int>(*value);
}

std::size_t size_parameter(const Json& parameters, const char* key, std::size_t fallback) {
    const auto value = optional_integer(parameters, key);
    if (!value || *value < 0) return fallback;
    if (static_cast<std::uint64_t>(*value) >
        static_cast<std::uint64_t>(std::numeric_limits<std::size_t>::max())) {
        invalid(std::string("参数超出 size_t 范围: ") + key);
    }
    return static_cast<std::size_t>(*value);
}

std::filesystem::path path_parameter(const Json& parameters, const char* key) {
    const std::string value = required_string(parameters, key);
    if (value.empty()) invalid(std::string("路径不能为空: ") + key);
    return opensvn::text::path_from_utf8(value);
}

std::vector<std::filesystem::path> path_array(const Json& parameters, const char* key) {
    const auto iterator = parameters.find(key);
    if (iterator == parameters.end() || !iterator->is_array()) {
        invalid(std::string("缺少路径数组参数: ") + key);
    }
    std::vector<std::filesystem::path> paths;
    paths.reserve(iterator->size());
    for (const auto& item : *iterator) {
        if (!item.is_string()) invalid(std::string("路径数组包含非字符串: ") + key);
        const std::string value = item.get<std::string>();
        if (value.empty()) invalid(std::string("路径数组包含空路径: ") + key);
        paths.push_back(opensvn::text::path_from_utf8(value));
    }
    if (paths.empty()) invalid(std::string("路径数组为空: ") + key);
    return paths;
}

std::vector<std::string> string_array(const Json& parameters, const char* key) {
    const auto iterator = parameters.find(key);
    if (iterator == parameters.end() || !iterator->is_array()) return {};
    std::vector<std::string> values;
    values.reserve(iterator->size());
    for (const auto& item : *iterator) {
        if (item.is_string()) values.push_back(item.get<std::string>());
    }
    return values;
}

std::optional<opensvn::SVNCredential> credential_parameter(const Json& parameters) {
    const auto iterator = parameters.find("credential");
    if (iterator == parameters.end() || iterator->is_null()) return std::nullopt;
    if (!iterator->is_object()) invalid("credential 必须是对象");
    opensvn::SVNCredential credential;
    credential.username = iterator->value("username", std::string{});
    credential.password = iterator->value("password", std::string{});
    return credential;
}

Json optional_json(const std::optional<std::string>& value) {
    return value ? Json(*value) : Json(nullptr);
}

Json optional_json(const std::optional<std::int64_t>& value) {
    return value ? Json(*value) : Json(nullptr);
}

Json error_to_json(const opensvn::SVNError& error) {
    return Json{
        {"identifier", error.identifier()},
        {"message", error.message},
        {"detail", optional_json(error.diagnostic_output)},
        {"svnCode", optional_json(error.svn_code)},
        {"exitCode", error.exit_code ? Json(*error.exit_code) : Json(nullptr)},
        {"severity", std::string(opensvn::to_string(error.severity()))},
        {"remediation", std::string(opensvn::remediation(error.code))},
        {"authenticationRequired", opensvn::is_authentication_related(error.code)},
        {"cancelled", error.code == opensvn::SVNErrorCode::cancelled},
    };
}

char* duplicate_string(std::string_view value) noexcept {
    char* copy = static_cast<char*>(std::malloc(value.size() + 1));
    if (!copy) return nullptr;
    std::memcpy(copy, value.data(), value.size());
    copy[value.size()] = '\0';
    return copy;
}

constexpr std::string_view fallback_error_json =
    R"({"identifier":"SVN-9998","message":"无法序列化错误","detail":null,"svnCode":null,"exitCode":null,"severity":"fatal","remediation":"请查看诊断日志。","authenticationRequired":false,"cancelled":false})";

char* duplicate_json(const Json& value) noexcept {
    try {
        return duplicate_string(value.dump(-1, ' ', false, Json::error_handler_t::replace));
    } catch (...) {
        return nullptr;
    }
}

void set_fixed_error(char** out_error) noexcept {
    if (out_error) *out_error = duplicate_string(fallback_error_json);
}

void set_error(char** out_error, const opensvn::SVNError& error) noexcept {
    if (!out_error) return;
    char* json = nullptr;
    try {
        json = duplicate_json(error_to_json(error));
    } catch (...) {
    }
    *out_error = json ? json : duplicate_string(fallback_error_json);
}

opensvn::SVNError fallback_error(const std::exception& exception) {
    opensvn::SVNError error;
    error.code = opensvn::SVNErrorCode::unknown;
    error.message = exception.what();
    return error;
}

std::string risk_token(opensvn::OperationPreview::Risk risk) {
    switch (risk) {
    case opensvn::OperationPreview::Risk::low: return "low";
    case opensvn::OperationPreview::Risk::medium: return "medium";
    case opensvn::OperationPreview::Risk::high: return "high";
    }
    return "low";
}

Json preview_to_json(const opensvn::OperationPreview& preview) {
    return Json{
        {"summary", preview.summary},
        {"detail", preview.detail},
        {"risk", risk_token(preview.risk)},
        {"affectedPaths", preview.affected_paths},
        {"discardedPaths", preview.discarded_paths},
    };
}

Json diff_to_json(const opensvn::DiffResult& diff) {
    return Json{
        {"text", diff.text},
        {"isTruncated", diff.is_truncated},
        {"byteCount", diff.byte_count},
    };
}

std::optional<opensvn::ResolveStrategy> parse_strategy(std::string_view token) {
    if (token == "working") return opensvn::ResolveStrategy::working;
    if (token == "mine-full" || token == "mine_full") return opensvn::ResolveStrategy::mine_full;
    if (token == "theirs-full" || token == "theirs_full") {
        return opensvn::ResolveStrategy::theirs_full;
    }
    if (token == "base") return opensvn::ResolveStrategy::base;
    return std::nullopt;
}

std::optional<opensvn::CheckoutDepth> parse_depth(std::string_view token) {
    if (token == "infinity") return opensvn::CheckoutDepth::infinity;
    if (token == "immediates") return opensvn::CheckoutDepth::immediates;
    if (token == "files") return opensvn::CheckoutDepth::files;
    if (token == "empty") return opensvn::CheckoutDepth::empty;
    return std::nullopt;
}

Json installation_to_json(const opensvn::SVNInstallation& installation) {
    return Json{
        {"executable", opensvn::text::path_to_utf8(installation.executable)},
        {"version", installation.version.to_string()},
        {"source", std::string(opensvn::to_string(installation.source))},
    };
}

Json journal_to_json(const opensvn::OperationJournal& journal) {
    Json entries = Json::array();
    for (const auto& entry : journal.unfinished()) {
        entries.push_back(Json{
            {"id", entry.id},
            {"kind", std::string(opensvn::OperationJournal::kind_token(entry.kind))},
            {"title", entry.title()},
            {"workingCopy", entry.working_copy},
            {"summary", entry.summary},
            {"startedAt", opensvn::format_iso8601(entry.started_at)},
            {"recoveryAdvice", entry.recovery_advice()},
        });
    }
    const auto quarantine = journal.quarantine_path();
    const auto write_failure = journal.write_failure();
    return Json{
        {"entries", std::move(entries)},
        {"quarantined", quarantine ? Json(opensvn::text::path_to_utf8(*quarantine))
                                   : Json(nullptr)},
        {"writeFailure", optional_json(write_failure)},
    };
}

Json dispatch(opensvn_service& handle, const std::string& operation,
              const Json& parameters, const opensvn::SVNProgressCallback& progress,
              std::stop_token stop) {
    using namespace opensvn;
    auto& service = *handle.service;

    if (operation == "installation") {
        return installation_to_json(service.installation());
    }

    if (operation == "journal") {
        if (!handle.journal) return Json{{"entries", Json::array()},
                                         {"quarantined", nullptr},
                                         {"writeFailure", nullptr}};
        return journal_to_json(*handle.journal);
    }

    if (operation == "discard_journal_entry") {
        if (!handle.journal) return Json{{"ok", true}};
        handle.journal->discard(required_string(parameters, "id"));
        return Json{{"ok", true}};
    }

    if (operation == "discard_all_journal") {
        if (handle.journal) handle.journal->discard_all();
        return Json{{"ok", true}};
    }

    if (operation == "status") {
        const auto snapshot = service.status(
            path_parameter(parameters, "path"),
            boolean(parameters, "includeIgnored", false),
            boolean(parameters, "checkRepository", false),
            credential_parameter(parameters), stop);
        return status_to_json(snapshot);
    }

    if (operation == "remote_preview") {
        return remote_preview_to_json(service.remote_preview(
            path_parameter(parameters, "path"), credential_parameter(parameters), stop));
    }

    if (operation == "info") {
        return info_to_json(service.info(required_string(parameters, "target"),
                                         credential_parameter(parameters), stop));
    }

    if (operation == "log") {
        const auto page = service.log(
            required_string(parameters, "target"), integer(parameters, "limit", 50),
            optional_integer(parameters, "startRevision"),
            optional_integer(parameters, "endRevision"),
            credential_parameter(parameters), progress, stop);
        return Json{
            {"entries", log_to_json(page.entries)},
            {"target", optional_json(page.target)},
            {"limit", page.limit},
            {"hasMore", page.has_more},
        };
    }

    if (operation == "diff_working_copy") {
        return diff_to_json(service.diff_working_copy(
            path_parameter(parameters, "path"), integer(parameters, "contextLines", 3),
            size_parameter(parameters, "maxBytes", 2'000'000), stop));
    }

    if (operation == "diff_revision") {
        const auto revision = optional_integer(parameters, "revision");
        if (!revision) invalid("缺少修订号");
        return diff_to_json(service.diff_revision(
            path_parameter(parameters, "path"), *revision, credential_parameter(parameters),
            integer(parameters, "contextLines", 3),
            size_parameter(parameters, "maxBytes", 2'000'000), stop));
    }

    if (operation == "properties") {
        return properties_to_json(service.properties(path_parameter(parameters, "path"),
                                                     boolean(parameters, "recursive", false),
                                                     stop));
    }

    if (operation == "property_value") {
        const auto value = service.property_value(required_string(parameters, "name"),
                                                  path_parameter(parameters, "path"), stop);
        return Json{{"value", optional_json(value)}};
    }

    if (operation == "locks") {
        const auto snapshot =
            service.locks(path_parameter(parameters, "path"),
                          credential_parameter(parameters), stop);
        Json locks = Json::array();
        for (const auto& [path, lock] : snapshot.locks) {
            Json entry = lock_to_json(lock);
            entry["path"] = path;
            entry["isMine"] = snapshot.is_own_lock(path);
            locks.push_back(std::move(entry));
        }
        return Json{{"locks", std::move(locks)}};
    }

    if (operation == "conflict_artifacts") {
        const auto artifacts = service.conflict_artifacts(
            path_parameter(parameters, "path"), stop);
        if (!artifacts) return Json(nullptr);
        return Json{
            {"path", artifacts->path},
            {"operation", artifacts->operation},
            {"type", artifacts->type},
            {"prevBaseFile", optional_json(artifacts->prev_base_file)},
            {"prevWorkingCopyFile", optional_json(artifacts->prev_wc_file)},
            {"currentBaseFile", optional_json(artifacts->cur_base_file)},
            {"sourceLeftPath", optional_json(artifacts->source_left_path)},
            {"sourceRightPath", optional_json(artifacts->source_right_path)},
            {"sourceLeftRevision", optional_json(artifacts->source_left_revision)},
            {"sourceRightRevision", optional_json(artifacts->source_right_revision)},
        };
    }

    if (operation == "checkout") {
        const auto depth = parse_depth(parameters.value("depth", std::string("infinity")));
        if (!depth) invalid("未知的检出深度");
        service.checkout(required_string(parameters, "url"),
                         path_parameter(parameters, "destination"),
                         optional_integer(parameters, "revision"), *depth,
                         credential_parameter(parameters), progress, stop);
        return Json{{"ok", true}};
    }

    if (operation == "update") {
        const auto summary = service.update(
            path_parameter(parameters, "path"), optional_integer(parameters, "revision"),
            credential_parameter(parameters), progress, stop);
        return Json{
            {"target", summary.target},
            {"fromRevision", optional_json(summary.from_revision)},
            {"toRevision", optional_json(summary.to_revision)},
            {"updatedPaths", summary.updated_paths},
            {"conflictedPaths", summary.conflicted_paths},
            {"removedPaths", summary.removed_paths},
        };
    }

    if (operation == "add") {
        service.add(path_array(parameters, "paths"), boolean(parameters, "force", false),
                    boolean(parameters, "includeIgnored", false), stop);
        return Json{{"ok", true}};
    }

    if (operation == "preview_delete") {
        return preview_to_json(service.preview_delete(path_array(parameters, "paths")));
    }

    if (operation == "delete") {
        service.delete_paths(path_array(parameters, "paths"),
                             boolean(parameters, "confirmed", false),
                             boolean(parameters, "force", false), stop);
        return Json{{"ok", true}};
    }

    if (operation == "preview_revert") {
        return preview_to_json(service.preview_revert(path_array(parameters, "paths")));
    }

    if (operation == "revert") {
        service.revert(path_array(parameters, "paths"), boolean(parameters, "recursive", true),
                       boolean(parameters, "confirmed", false), stop);
        return Json{{"ok", true}};
    }

    if (operation == "commit") {
        const auto summary = service.commit(
            path_array(parameters, "paths"), required_string(parameters, "message"),
            credential_parameter(parameters), progress, stop);
        return Json{
            {"revision", optional_json(summary.revision)},
            {"committedPaths", summary.committed_paths},
        };
    }

    if (operation == "lock") {
        const auto outcome = service.lock(
            path_array(parameters, "paths"), optional_string(parameters, "comment"),
            boolean(parameters, "steal", false), boolean(parameters, "confirmed", false),
            credential_parameter(parameters), stop);
        return Json{
            {"lockedPaths", outcome.locked_paths},
            {"owner", optional_json(outcome.owner)},
        };
    }

    if (operation == "unlock") {
        const auto outcome = service.unlock(
            path_array(parameters, "paths"), boolean(parameters, "breakLock", false),
            boolean(parameters, "confirmed", false), credential_parameter(parameters), stop);
        return Json{{"unlockedPaths", outcome.unlocked_paths}};
    }

    if (operation == "cleanup") {
        service.cleanup(path_parameter(parameters, "path"), stop);
        return Json{{"ok", true}};
    }

    if (operation == "resolve") {
        const auto strategy = parse_strategy(parameters.value("strategy", std::string{}));
        if (!strategy) invalid("未知的冲突解决策略");
        const auto outcome = service.resolve(
            path_array(parameters, "paths"), *strategy,
            boolean(parameters, "confirmed", false), boolean(parameters, "backup", true), stop);
        Json scans = Json::array();
        for (const auto& scan : outcome.scans) {
            scans.push_back(Json{
                {"path", scan.path},
                {"markerLines", scan.marker_lines},
                {"skipped", scan.skipped},
                {"skipReason", scan.skip_reason},
            });
        }
        Json backup = nullptr;
        if (outcome.backup) {
            backup = Json{{"directory", outcome.backup->directory},
                          {"files", outcome.backup->files}};
        }
        return Json{
            {"resolvedPaths", outcome.resolved_paths},
            {"backup", std::move(backup)},
            {"scans", std::move(scans)},
            {"residualMarkers", outcome.paths_with_residual_markers()},
        };
    }

    if (operation == "set_property") {
        service.set_property(required_string(parameters, "name"),
                             required_string(parameters, "value"),
                             path_array(parameters, "targets"), stop);
        return Json{{"ok", true}};
    }

    if (operation == "delete_property") {
        return Json{
            {"deletedCount",
             service.delete_property(required_string(parameters, "name"),
                                     path_array(parameters, "targets"), stop)},
        };
    }

    if (operation == "add_ignore_pattern") {
        return Json{{"changed",
                     service.add_ignore_pattern(required_string(parameters, "pattern"),
                                                path_parameter(parameters, "directory"), stop)}};
    }

    if (operation == "ignore") {
        const auto outcome = service.ignore(path_array(parameters, "paths"), stop);
        return Json{{"added", outcome.added}, {"already", outcome.already}};
    }

    if (operation == "credential_scopes") {
        Json scopes = Json::array();
        for (const auto& scope : service.credential_scopes()) {
            scopes.push_back(Json{{"host", scope.host},
                                  {"realm", optional_json(scope.realm)},
                                  {"storageKey", scope.storage_key()}});
        }
        return Json{{"scopes", std::move(scopes)}};
    }

    if (operation == "forget_credential") {
        const auto realm = optional_string(parameters, "realm");
        service.forget_credential(
            CredentialScope{required_string(parameters, "host"), realm});
        return Json{{"ok", true}};
    }

    if (operation == "forget_all_credentials") {
        service.forget_all_credentials();
        return Json{{"ok", true}};
    }

    invalid("未知操作: " + operation);
}

} // namespace

extern "C" {

OPENSVN_CAPI int32_t opensvn_create_service(const char* config_json_utf8,
                                            opensvn_service** out_service,
                                            char** out_error_json) {
    if (out_service) *out_service = nullptr;
    if (out_error_json) *out_error_json = nullptr;
    if (!out_service) return 0;

    try {
        Json config = Json::object();
        if (config_json_utf8 && *config_json_utf8) {
            config = Json::parse(config_json_utf8);
            if (!config.is_object()) invalid("配置必须是 JSON 对象");
        }

        opensvn::SVNDiscovery discovery;
        const auto svn_path = optional_string(config, "svnPath");
        if (svn_path && !svn_path->empty()) {
            discovery.explicit_executable = opensvn::text::path_from_utf8(*svn_path);
        }
        const auto environment = config.find("environment");
        if (environment != config.end() && environment->is_object()) {
            for (const auto& [name, value] : environment->items()) {
                if (value.is_string()) discovery.environment[name] = value.get<std::string>();
            }
        }

        const int timeout_seconds = integer(config, "timeoutSeconds", 300);
        if (timeout_seconds <= 0) invalid("timeoutSeconds 必须为正数");

        std::shared_ptr<opensvn::CredentialStoring> credentials;
        if (boolean(config, "inMemoryCredentials", false)) {
            credentials = std::make_shared<opensvn::InMemoryCredentialStore>();
        } else {
            credentials = std::make_shared<opensvn::WindowsCredentialStore>();
        }

        std::shared_ptr<opensvn::OperationJournal> journal;
        const auto journal_directory = optional_string(config, "journalDirectory");
        if (journal_directory && !journal_directory->empty()) {
            journal = std::make_shared<opensvn::OperationJournal>(
                opensvn::text::path_from_utf8(*journal_directory));
        } else {
            journal = std::make_shared<opensvn::OperationJournal>();
        }

        std::optional<std::filesystem::path> backup_root;
        const auto backup_path = optional_string(config, "conflictBackupRoot");
        if (backup_path && !backup_path->empty()) {
            backup_root = opensvn::text::path_from_utf8(*backup_path);
        }

        auto handle = std::make_unique<opensvn_service>();
        handle->journal = journal;
        handle->service = opensvn::make_service(
            discovery, credentials, journal, std::chrono::seconds(timeout_seconds),
            backup_root);
        const int max_writes = integer(config, "maxConcurrentWrites", 4);
        if (max_writes > 0) handle->service->set_max_concurrent_writes(max_writes);
        *out_service = handle.release();
        return 1;
    } catch (const opensvn::SVNException& exception) {
        set_error(out_error_json, exception.error());
        return 0;
    } catch (const std::exception& exception) {
        try {
            set_error(out_error_json, fallback_error(exception));
        } catch (...) {
            set_fixed_error(out_error_json);
        }
        return 0;
    } catch (...) {
        set_fixed_error(out_error_json);
        return 0;
    }
}

OPENSVN_CAPI void opensvn_destroy_service(opensvn_service* service) {
    if (!service) return;
    try {
        std::unique_lock lock(service->mutex);
        service->closing = true;
        for (auto& [id, source] : service->requests) source->request_stop();
        service->idle.wait(lock, [&] { return service->active_invocations == 0; });
    } catch (...) {
    }
    try {
        delete service;
    } catch (...) {
    }
}

OPENSVN_CAPI char* opensvn_invoke(opensvn_service* service, uint64_t request_id,
                                  const char* operation_utf8,
                                  const char* parameters_json_utf8,
                                  opensvn_progress_callback progress, void* user_data,
                                  char** out_error_json) {
    if (out_error_json) *out_error_json = nullptr;

    if (!service) {
        try {
            set_error(out_error_json,
                      opensvn::SVNError{opensvn::SVNErrorCode::invalid_invocation,
                                        "服务句柄为空"});
        } catch (...) {
            set_fixed_error(out_error_json);
        }
        return nullptr;
    }
    if (!operation_utf8 || !*operation_utf8) {
        try {
            set_error(out_error_json,
                      opensvn::SVNError{opensvn::SVNErrorCode::invalid_invocation,
                                        "操作名为空"});
        } catch (...) {
            set_fixed_error(out_error_json);
        }
        return nullptr;
    }

    try {
        auto stop_source = std::make_shared<std::stop_source>();
        {
            std::lock_guard lock(service->mutex);
            if (service->closing) {
                opensvn::SVNError error{opensvn::SVNErrorCode::invalid_invocation,
                                        "服务正在关闭"};
                set_error(out_error_json, error);
                return nullptr;
            }
            if (request_id != 0 &&
                !service->requests.emplace(request_id, stop_source).second) {
                opensvn::SVNError error{opensvn::SVNErrorCode::invalid_invocation,
                                        "request_id 已被使用"};
                set_error(out_error_json, error);
                return nullptr;
            }
            ++service->active_invocations;
        }

        InvocationRegistration registration{service, request_id, stop_source};

        Json parameters = Json::object();
        if (parameters_json_utf8 && *parameters_json_utf8) {
            parameters = Json::parse(parameters_json_utf8);
        }
        require_object(parameters);

        opensvn::SVNProgressCallback line_callback;
        if (progress) {
            line_callback = [progress, user_data](std::string_view line) {
                const std::string copy(line);
                progress(copy.c_str(), user_data);
            };
        }

        Json result = dispatch(*service, operation_utf8, parameters, line_callback,
                               stop_source->get_token());
        char* output = duplicate_json(result);
        if (!output) {
            opensvn::SVNError error{opensvn::SVNErrorCode::unknown,
                                    "内存不足，无法返回操作结果"};
            set_error(out_error_json, error);
            return nullptr;
        }
        return output;
    } catch (const opensvn::SVNException& exception) {
        set_error(out_error_json, exception.error());
    } catch (const std::exception& exception) {
        try {
            set_error(out_error_json, fallback_error(exception));
        } catch (...) {
            set_fixed_error(out_error_json);
        }
    } catch (...) {
        set_fixed_error(out_error_json);
    }
    return nullptr;
}

OPENSVN_CAPI void opensvn_cancel(opensvn_service* service, uint64_t request_id) {
    if (!service || request_id == 0) return;
    try {
        std::shared_ptr<std::stop_source> source;
        {
            std::lock_guard lock(service->mutex);
            const auto iterator = service->requests.find(request_id);
            if (iterator == service->requests.end()) return;
            source = iterator->second;
        }
        source->request_stop();
    } catch (...) {
    }
}

OPENSVN_CAPI void opensvn_free_string(char* value) {
    std::free(value);
}

OPENSVN_CAPI const char* opensvn_capi_version(void) {
    return "1";
}

} // extern "C"
