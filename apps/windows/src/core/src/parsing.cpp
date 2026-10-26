#include "opensvn/parsing.hpp"

#include "opensvn/errors.hpp"
#include "opensvn/redaction.hpp"
#include "opensvn/text.hpp"

#include <pugixml.hpp>

#include <algorithm>
#include <cstdint>
#include <string>

namespace opensvn::parsing {

namespace {

[[noreturn]] void parse_failure(const std::string& message, std::string_view xml) {
    throw SVNException(
        SVNErrorCode::xml_parse_failure, message,
        LogRedactor::redact(
            std::string(xml.substr(0, std::min<std::size_t>(xml.size(), 2048)))));
}

pugi::xml_document load(std::string_view xml, const std::string& kind) {
    if (xml.empty()) parse_failure("空的 " + kind + " XML", xml);
    pugi::xml_document document;
    const pugi::xml_parse_result result =
        document.load_buffer(xml.data(), xml.size(),
                             pugi::parse_default | pugi::parse_ws_pcdata);
    if (!result) {
        parse_failure("无法解析 svn " + kind + " XML：" + result.description(), xml);
    }
    return document;
}

std::string attribute(const pugi::xml_node& node, const char* name) {
    const pugi::xml_attribute value = node.attribute(name);
    return value ? value.as_string() : std::string{};
}

std::optional<std::string> optional_attribute(const pugi::xml_node& node, const char* name) {
    const pugi::xml_attribute value = node.attribute(name);
    if (!value) return std::nullopt;
    return std::string(value.as_string());
}

std::optional<std::int64_t> optional_i64(const pugi::xml_node& node, const char* name) {
    const pugi::xml_attribute value = node.attribute(name);
    if (!value) return std::nullopt;
    try {
        return std::stoll(value.as_string());
    } catch (...) {
        return std::nullopt;
    }
}

std::optional<std::int64_t> parse_i64(const std::optional<std::string>& text) {
    if (!text || text->empty()) return std::nullopt;
    try {
        std::size_t used = 0;
        const long long value = std::stoll(*text, &used);
        if (used != text->size()) return std::nullopt;
        return static_cast<std::int64_t>(value);
    } catch (...) {
        return std::nullopt;
    }
}

std::string child_text(const pugi::xml_node& parent, const char* name) {
    return parent.child(name).text().as_string();
}

std::optional<std::string> optional_child_text(const pugi::xml_node& parent, const char* name) {
    const pugi::xml_node child = parent.child(name);
    if (!child) return std::nullopt;
    return std::string(child.text().as_string());
}

RepositoryLock parse_lock(const pugi::xml_node& lock) {
    RepositoryLock result;
    if (const pugi::xml_node token = lock.child("token")) {
        result.token = std::string(token.text().as_string());
    }
    if (const pugi::xml_node owner = lock.child("owner")) {
        result.owner = std::string(owner.text().as_string());
    }
    if (const pugi::xml_node comment = lock.child("comment")) {
        result.comment = std::string(comment.text().as_string());
    }
    if (const pugi::xml_node created = lock.child("created")) {
        result.created_at = parse_svn_date(created.text().as_string());
    }
    return result;
}

StatusEntry parse_status_entry(const pugi::xml_node& entry_node) {
    StatusEntry entry;
    entry.path = attribute(entry_node, "path");
    if (entry.path.empty()) return entry;

    const pugi::xml_node wc_status = entry_node.child("wc-status");
    const pugi::xml_node repos_status = entry_node.child("repos-status");

    const std::string item_token =
        wc_status ? attribute(wc_status, "item") : std::string("none");
    const std::string props_token =
        wc_status ? attribute(wc_status, "props") : std::string("none");
    entry.item = WCItemStatus(item_token.empty() ? "none" : item_token);
    entry.properties = WCItemStatus(props_token.empty() ? "none" : props_token);

    if (entry.item.is(WCItemStatus::Kind::conflicted)) {
        entry.conflicts = entry.conflicts | ConflictFlags::text;
    }
    if (entry.properties.is(WCItemStatus::Kind::conflicted)) {
        entry.conflicts = entry.conflicts | ConflictFlags::property;
    }
    if (wc_status && attribute(wc_status, "tree-conflicted") == "true") {
        entry.conflicts = entry.conflicts | ConflictFlags::tree;
    }

    entry.revision = optional_i64(wc_status, "revision");
    if (!entry.revision) entry.revision = optional_i64(entry_node, "revision");

    const std::string copied_entry = attribute(entry_node, "copied");
    const std::string copied_wc = wc_status ? attribute(wc_status, "copied") : std::string{};
    entry.is_copied = copied_entry == "true" || copied_wc == "true";

    if (wc_status) {
        if (const pugi::xml_node lock = wc_status.child("lock")) {
            entry.repository_lock = parse_lock(lock);
        }
    }
    if (repos_status) {
        if (const pugi::xml_node lock = repos_status.child("lock")) {
            entry.remote_lock = parse_lock(lock);
        }
        entry.remote_item = optional_attribute(repos_status, "item").has_value()
                                ? std::optional<WCItemStatus>(
                                      WCItemStatus(attribute(repos_status, "item")))
                                : std::nullopt;
        entry.remote_properties = optional_attribute(repos_status, "props").has_value()
                                      ? std::optional<WCItemStatus>(
                                            WCItemStatus(attribute(repos_status, "props")))
                                      : std::nullopt;
    }

    if (wc_status) {
        if (const pugi::xml_node commit_node = wc_status.child("commit")) {
            CommitInfo commit;
            commit.revision = optional_i64(commit_node, "revision").value_or(0);
            commit.author = optional_child_text(commit_node, "author");
            if (const pugi::xml_node date = commit_node.child("date")) {
                commit.date = parse_svn_date(date.text().as_string());
            }
            entry.commit = std::move(commit);
        }
    }

    entry.is_working_copy_locked = wc_status && attribute(wc_status, "locked") == "true";
    entry.changelist = optional_attribute(entry_node, "changelist");
    entry.depth = wc_status ? optional_attribute(wc_status, "depth") : std::nullopt;
    return entry;
}

} // namespace

StatusSnapshot parse_status(std::string_view xml) {
    pugi::xml_document document = load(xml, "status");
    const pugi::xml_node root = document.document_element();
    if (!root || std::string_view(root.name()) != "status") {
        parse_failure("根元素不是 <status>", xml);
    }

    StatusSnapshot snapshot;
    if (const pugi::xml_node target = root.child("target")) {
        snapshot.target = optional_attribute(target, "path");
    }

    std::optional<std::int64_t> working_copy_revision;
    std::optional<std::int64_t> server_revision;

    for (const pugi::xml_node target : root.children("target")) {
        for (const pugi::xml_node entry : target.children("entry")) {
            snapshot.entries.push_back(parse_status_entry(entry));
        }
        if (const pugi::xml_node against = target.child("against")) {
            if (const auto revision = optional_i64(against, "revision")) {
                server_revision = std::max(server_revision.value_or(*revision), *revision);
            }
        }
    }

    for (const auto& entry : snapshot.entries) {
        if (entry.revision) {
            working_copy_revision = std::min(working_copy_revision.value_or(*entry.revision),
                                             *entry.revision);
        }
    }
    snapshot.working_copy_revision = working_copy_revision;
    snapshot.server_revision = server_revision;
    return snapshot;
}

std::vector<LogEntry> parse_log(std::string_view xml) {
    pugi::xml_document document = load(xml, "log");
    const pugi::xml_node root = document.document_element();
    if (!root || std::string_view(root.name()) != "log") {
        parse_failure("根元素不是 <log>", xml);
    }

    std::vector<LogEntry> entries;
    for (const pugi::xml_node logentry : root.children("logentry")) {
        const auto revision = optional_i64(logentry, "revision");
        if (!revision) continue;

        LogEntry entry;
        entry.revision = *revision;
        if (const pugi::xml_node author = logentry.child("author")) {
            const std::string value = author.text().as_string();
            if (!value.empty()) entry.author = value;
        }
        if (const pugi::xml_node date = logentry.child("date")) {
            entry.date = parse_svn_date(date.text().as_string());
        }
        entry.message = logentry.child("msg").text().as_string();

        if (const pugi::xml_node paths = logentry.child("paths")) {
            for (const pugi::xml_node path : paths.children("path")) {
                ChangedPath changed;
                changed.path = path.text().as_string();
                const std::string action = attribute(path, "action");
                changed.action = parse_changed_path_action(action.empty() ? "?" : action);
                changed.kind = optional_attribute(path, "kind");
                changed.copy_from_path = optional_attribute(path, "copyfrom-path");
                if (const auto copy_revision = optional_i64(path, "copyfrom-rev")) {
                    changed.copy_from_revision = *copy_revision;
                }
                entry.changed_paths.push_back(std::move(changed));
            }
        }
        entries.push_back(std::move(entry));
    }
    return entries;
}

InfoReport parse_info(std::string_view xml) {
    pugi::xml_document document = load(xml, "info");
    const pugi::xml_node root = document.document_element();
    if (!root || std::string_view(root.name()) != "info") {
        parse_failure("根元素不是 <info>", xml);
    }

    InfoReport report;
    for (const pugi::xml_node entry : root.children("entry")) {
        const std::string path = attribute(entry, "path");
        const pugi::xml_node url_node = entry.child("url");
        if (path.empty() || !url_node) continue;

        RepositoryInfo info;
        info.path = path;
        info.url = url_node.text().as_string();
        info.revision = optional_i64(entry, "revision");
        const std::string kind = attribute(entry, "kind");
        info.kind = parse_node_kind(kind.empty() ? "none" : kind);

        if (const pugi::xml_node repository = entry.child("repository")) {
            info.repository_root = optional_child_text(repository, "root");
            info.repository_uuid = optional_child_text(repository, "uuid");
        }
        if (const pugi::xml_node wc_info = entry.child("wc-info")) {
            info.working_copy_root = optional_child_text(wc_info, "wcroot-abspath");
            info.schedule = optional_child_text(wc_info, "schedule");
            info.depth = optional_child_text(wc_info, "depth");
        }
        if (const pugi::xml_node commit = entry.child("commit")) {
            info.last_changed_revision = optional_i64(commit, "revision");
            info.last_changed_author = optional_child_text(commit, "author");
            if (const pugi::xml_node date = commit.child("date")) {
                info.last_changed_date = parse_svn_date(date.text().as_string());
            }
        }
        if (const pugi::xml_node lock = entry.child("lock")) {
            info.repository_lock = parse_lock(lock);
        }
        if (const pugi::xml_node conflict = entry.child("conflict")) {
            info.conflict_operation = optional_attribute(conflict, "operation");
            info.conflict_type = optional_attribute(conflict, "type");
        }
        report.entries.push_back(std::move(info));
    }

    if (report.entries.empty()) {
        parse_failure("<info> 中没有 <entry>", xml);
    }
    return report;
}

std::vector<PropertyTarget> parse_properties(std::string_view xml) {
    pugi::xml_document document = load(xml, "propget");
    const pugi::xml_node root = document.document_element();
    if (!root || std::string_view(root.name()) != "properties") {
        parse_failure("根元素不是 <properties>", xml);
    }

    std::vector<PropertyTarget> targets;
    for (const pugi::xml_node target : root.children("target")) {
        PropertyTarget parsed;
        parsed.path = attribute(target, "path");
        for (const pugi::xml_node property : target.children("property")) {
            const std::string name = attribute(property, "name");
            if (name.empty()) continue;
            parsed.properties.push_back(SVNProperty{name, property.text().as_string()});
        }
        targets.push_back(std::move(parsed));
    }
    return targets;
}

std::optional<ConflictArtifacts> parse_conflict_artifacts(std::string_view xml) {
    pugi::xml_document document = load(xml, "info");
    const pugi::xml_node root = document.document_element();
    if (!root || std::string_view(root.name()) != "info") {
        parse_failure("根元素不是 <info>", xml);
    }

    for (const pugi::xml_node entry : root.children("entry")) {
        const pugi::xml_node conflict = entry.child("conflict");
        if (!conflict) continue;

        ConflictArtifacts artifacts;
        artifacts.path = attribute(entry, "path");
        artifacts.operation = attribute(conflict, "operation");
        artifacts.type = attribute(conflict, "type");
        artifacts.prev_base_file = optional_child_text(conflict, "prev-base-file");
        artifacts.prev_wc_file = optional_child_text(conflict, "prev-wc-file");
        artifacts.cur_base_file = optional_child_text(conflict, "cur-base-file");

        for (const pugi::xml_node version : conflict.children("version")) {
            const std::string side = attribute(version, "side");
            if (side == "source-left") {
                artifacts.source_left_path = optional_attribute(version, "path-in-repos");
                artifacts.source_left_revision = optional_i64(version, "revision");
            } else if (side == "source-right") {
                artifacts.source_right_path = optional_attribute(version, "path-in-repos");
                artifacts.source_right_revision = optional_i64(version, "revision");
            }
        }
        return artifacts;
    }
    return std::nullopt;
}

} // namespace opensvn::parsing
