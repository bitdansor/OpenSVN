#include "opensvn/json_contract.hpp"

namespace opensvn {

namespace {

Json nullable_string(const std::optional<std::string>& value) {
    return value ? Json(*value) : Json(nullptr);
}

Json nullable_i64(const std::optional<std::int64_t>& value) {
    return value ? Json(*value) : Json(nullptr);
}

Json nullable_date(const std::optional<Timestamp>& value) {
    return value ? Json(format_iso8601(*value)) : Json(nullptr);
}

} // namespace

Json lock_to_json(const RepositoryLock& lock) {
    return Json{{"token", nullable_string(lock.token)},
                {"owner", nullable_string(lock.owner)},
                {"comment", nullable_string(lock.comment)},
                {"createdAt", nullable_date(lock.created_at)}};
}

Json status_to_json(const StatusSnapshot& snapshot) {
    Json entries = Json::array();
    for (const auto& entry : snapshot.entries) {
        Json conflicts = Json::array();
        for (const auto& code : conflict_codes(entry.conflicts)) conflicts.push_back(code);

        Json commit = nullptr;
        if (entry.commit) {
            commit = Json{{"revision", entry.commit->revision},
                          {"author", nullable_string(entry.commit->author)},
                          {"date", nullable_date(entry.commit->date)}};
        }

        Json json_entry{
            {"path", entry.path},
            {"item", entry.item.raw()},
            {"properties", entry.properties.raw()},
            {"revision", nullable_i64(entry.revision)},
            {"isCopied", entry.is_copied},
            {"conflicts", std::move(conflicts)},
            {"repositoryLock",
             entry.repository_lock ? lock_to_json(*entry.repository_lock) : Json(nullptr)},
            {"remoteLock", entry.remote_lock ? lock_to_json(*entry.remote_lock)
                                             : Json(nullptr)},
            {"remoteItem", entry.remote_item ? Json(entry.remote_item->raw())
                                            : Json(nullptr)},
            {"remoteProperties",
             entry.remote_properties ? Json(entry.remote_properties->raw())
                                     : Json(nullptr)},
            {"isWorkingCopyLocked", entry.is_working_copy_locked},
            {"changelist", nullable_string(entry.changelist)},
            {"commit", std::move(commit)},
            {"depth", nullable_string(entry.depth)},
            {"category", std::string(to_string(entry.category()))},
        };
        entries.push_back(std::move(json_entry));
    }

    return Json{{"target", nullable_string(snapshot.target)},
                {"entries", std::move(entries)},
                {"workingCopyRevision", nullable_i64(snapshot.working_copy_revision)},
                {"serverRevision", nullable_i64(snapshot.server_revision)}};
}

Json log_to_json(const std::vector<LogEntry>& log_entries) {
    Json entries = Json::array();
    for (const auto& entry : log_entries) {
        Json paths = Json::array();
        for (const auto& path : entry.changed_paths) {
            paths.push_back(Json{
                {"path", path.path},
                {"action", std::string(to_string(path.action))},
                {"kind", nullable_string(path.kind)},
                {"copyFromPath", nullable_string(path.copy_from_path)},
                {"copyFromRevision", nullable_i64(path.copy_from_revision)},
            });
        }
        entries.push_back(Json{
            {"revision", entry.revision},
            {"author", nullable_string(entry.author)},
            {"date", nullable_date(entry.date)},
            {"message", entry.message},
            {"changedPaths", std::move(paths)},
        });
    }
    return entries;
}

Json info_to_json(const InfoReport& report) {
    Json entries = Json::array();
    for (const auto& info : report.entries) {
        entries.push_back(Json{
            {"path", info.path},
            {"url", info.url},
            {"repositoryRoot", nullable_string(info.repository_root)},
            {"repositoryUUID", nullable_string(info.repository_uuid)},
            {"revision", nullable_i64(info.revision)},
            {"kind", std::string(to_string(info.kind))},
            {"schedule", nullable_string(info.schedule)},
            {"depth", nullable_string(info.depth)},
            {"workingCopyRoot", nullable_string(info.working_copy_root)},
            {"lastChangedRevision", nullable_i64(info.last_changed_revision)},
            {"lastChangedAuthor", nullable_string(info.last_changed_author)},
            {"lastChangedDate", nullable_date(info.last_changed_date)},
            {"repositoryLock",
             info.repository_lock ? lock_to_json(*info.repository_lock) : Json(nullptr)},
            {"conflictOperation", nullable_string(info.conflict_operation)},
            {"conflictType", nullable_string(info.conflict_type)},
        });
    }
    return Json{{"entries", std::move(entries)}};
}

Json properties_to_json(const std::vector<PropertyTarget>& targets) {
    Json json_targets = Json::array();
    for (const auto& target : targets) {
        Json properties = Json::array();
        for (const auto& property : target.properties) {
            properties.push_back(
                Json{{"name", property.name}, {"value", property.value}});
        }
        json_targets.push_back(
            Json{{"path", target.path}, {"properties", std::move(properties)}});
    }
    return json_targets;
}

Json remote_preview_to_json(const RemotePreview& preview) {
    const auto change_json = [](const RemoteChange& change) {
        return Json{
            {"path", change.path},
            {"item", change.item.raw()},
            {"properties", change.properties.raw()},
            {"localItem", change.local_item.raw()},
            {"localProperties", change.local_properties.raw()},
            {"conflictsWithLocal", change.conflicts_with_local()},
        };
    };

    Json changes = Json::array();
    for (const auto& change : preview.changes) changes.push_back(change_json(change));
    Json root = nullptr;
    if (preview.root_property_change) root = change_json(*preview.root_property_change);

    return Json{{"changes", std::move(changes)},
                {"rootPropertyChange", std::move(root)},
                {"workingCopyRevision", nullable_i64(preview.working_copy_revision)},
                {"serverRevision", nullable_i64(preview.server_revision)}};
}

} // namespace opensvn
