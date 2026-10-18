// OpenSVN — Windows implementation of the svn XML readers.
//
// NOT yet compiled on Windows (see apps/windows/README.md). The structure mirrors
// apps/macos/Sources/OpenSVNCore/Parsing/SVNXMLParser.swift one function at a time
// so that a reviewer can diff the two by eye.

#include "Services/SVNXMLParser.h"

#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>

#include <algorithm>
#include <optional>
#include <string>
#include <vector>

namespace opensvn {
namespace {

using winrt::Windows::Data::Xml::Dom::IXmlNode;
using winrt::Windows::Data::Xml::Dom::XmlDocument;

// hstring comparisons against wstring_view literals are easy to get subtly
// wrong; going through a plain view keeps the comparisons unambiguous.
std::wstring_view NameOf(IXmlNode node) {
    return std::wstring_view(node.NodeName().c_str());
}

std::string Text(IXmlNode node) {
    // `InnerText` is "" for an empty element such as <author/>, which the contract
    // maps to nullopt rather than an empty string (data-models.md §4).
    return winrt::to_string(node.InnerText());
}

std::vector<IXmlNode> ChildrenNamed(IXmlNode parent, std::wstring_view name) {
    std::vector<IXmlNode> result;
    for (const auto& child : parent.ChildNodes()) {
        if (NameOf(child) == name) {
            result.push_back(child);
        }
    }
    return result;
}

std::optional<IXmlNode> FirstChildNamed(IXmlNode parent, std::wstring_view name) {
    for (const auto& child : parent.ChildNodes()) {
        if (NameOf(child) == name) {
            return child;
        }
    }
    return std::nullopt;
}

std::optional<std::string> Attribute(IXmlNode node, std::wstring_view name) {
    const auto element = node.try_as<winrt::Windows::Data::Xml::Dom::XmlElement>();
    if (!element || !element.HasAttribute(name)) {
        return std::nullopt;
    }
    return winrt::to_string(element.GetAttribute(name));
}

std::optional<std::int64_t> IntegerAttribute(IXmlNode node, std::wstring_view name) {
    const auto raw = Attribute(node, name);
    if (!raw || raw->empty()) {
        return std::nullopt;
    }
    try {
        return std::stoll(*raw);
    } catch (const std::exception&) {
        // A non-numeric revision is a parser bug or a new svn output shape; keep
        // it visible instead of silently pretending the field was absent.
        throw SVNParseError("expected an integer in attribute " + winrt::to_string(winrt::hstring(std::wstring(name))) +
                            ", got '" + *raw + "'");
    }
}

std::optional<CommitInfo> ParseCommit(IXmlNode commit_node) {
    if (!commit_node) {
        return std::nullopt;
    }
    CommitInfo commit;
    commit.revision = IntegerAttribute(commit_node, L"revision").value_or(0);
    if (const auto author = FirstChildNamed(commit_node, L"author")) {
        const std::string value = Text(*author);
        if (!value.empty()) {
            commit.author = value;
        }
    }
    if (const auto date = FirstChildNamed(commit_node, L"date")) {
        commit.date = SVNXMLParser::NormalizeDate(Text(*date));
    }
    return commit;
}

std::optional<RepositoryLock> ParseLock(IXmlNode lock_node) {
    if (!lock_node) {
        return std::nullopt;
    }
    RepositoryLock lock;
    for (const auto& child : lock_node.ChildNodes()) {
        const auto name = NameOf(child);
        if (name == L"token") {
            lock.token = Text(child);
        } else if (name == L"owner") {
            lock.owner = Text(child);
        } else if (name == L"comment") {
            lock.comment = Text(child);
        } else if (name == L"created") {
            lock.created = SVNXMLParser::NormalizeDate(Text(child));
        }
    }
    return lock;
}

XmlDocument Load(std::string_view xml) {
    if (xml.empty()) {
        throw SVNParseError("empty XML document");
    }
    XmlDocument document;
    try {
        document.LoadXml(winrt::to_hstring(xml));
    } catch (const winrt::hresult_error& error) {
        throw SVNParseError("malformed XML: " + winrt::to_string(error.message()));
    }
    return document;
}

void RequireRoot(const XmlDocument& document, std::wstring_view expected) {
    const auto root = document.DocumentElement();
    if (!root || root.NodeName() != expected) {
        throw SVNParseError("unexpected root element <" +
                            winrt::to_string(root ? std::wstring(NameOf(root)) : std::wstring(L"none")) +
                            ">, expected <" +
                            winrt::to_string(winrt::hstring(std::wstring(expected))) + ">");
    }
}

}  // namespace

// ---------------------------------------------------------------------------
std::string SVNXMLParser::NormalizeDate(std::string_view raw) {
    if (raw.empty()) {
        return {};
    }
    std::string value(raw);
    // svn always emits Z-suffixed UTC, but be tolerant about a trailing '+00:00'.
    const auto dot = value.find('.');
    const auto zone = value.find_first_of("Z+", dot == std::string::npos ? 0 : dot);

    if (dot == std::string::npos) {
        std::string result = value.substr(0, zone == std::string::npos ? value.size() : zone);
        result += ".000Z";
        return result;
    }

    const std::string head = value.substr(0, dot);
    const std::size_t fraction_end = zone == std::string::npos ? value.size() : zone;
    std::string fraction = value.substr(dot + 1, fraction_end - dot - 1);
    fraction.resize(std::min<std::size_t>(fraction.size(), 3), '0');
    return head + "." + fraction + "Z";
}

// ---------------------------------------------------------------------------
StatusSnapshot SVNXMLParser::ParseStatus(std::string_view xml) {
    const XmlDocument document = Load(xml);
    RequireRoot(document, L"status");

    StatusSnapshot snapshot;
    const auto root = document.DocumentElement();
    for (const auto& child : root.ChildNodes()) {
        const auto name = NameOf(child);
        if (name == L"target") {
            snapshot.target = Text(child);
        } else if (name == L"entry") {
            StatusEntry entry;
            entry.path = Attribute(child, L"path").value_or("");
            entry.revision = IntegerAttribute(child, L"revision");
            if (const auto copied = Attribute(child, L"copied"); copied && *copied == "true") {
                entry.is_copied = true;
            }
            if (const auto changelist = Attribute(child, L"changelist")) {
                entry.changelist = *changelist;
            }

            if (const auto wc_status = FirstChildNamed(child, L"wc-status")) {
                entry.text_status = WCItemStatus::Parse(Attribute(*wc_status, L"item").value_or("none"));
                entry.property_status =
                    WCItemStatus::Parse(Attribute(*wc_status, L"props").value_or("none"));
                if (const auto revision = IntegerAttribute(*wc_status, L"revision")) {
                    entry.revision = revision;
                }
                if (const auto depth = Attribute(*wc_status, L"depth")) {
                    entry.depth = *depth;
                }
                if (const auto tree = Attribute(*wc_status, L"tree-conflicted");
                    tree && *tree == "true") {
                    entry.conflicts.Set(kConflictTree);
                }
                if (entry.text_status.kind == WCItemStatus::Kind::conflicted) {
                    entry.conflicts.Set(kConflictText);
                }
                if (entry.property_status.kind == WCItemStatus::Kind::conflicted) {
                    entry.conflicts.Set(kConflictProperty);
                }
                // A local lock is a *working copy* lock; it is not the server-side
                // file lock and must not be shown as one (data-models.md §1).
                if (entry.text_status.kind == WCItemStatus::Kind::incomplete) {
                    entry.is_working_copy_locked = true;
                }
                if (const auto commit = FirstChildNamed(*wc_status, L"commit")) {
                    entry.commit = ParseCommit(*commit);
                }
                if (const auto lock = FirstChildNamed(*wc_status, L"lock")) {
                    entry.repository_lock = ParseLock(*lock);
                }
            }

            snapshot.entries.push_back(std::move(entry));
        }
    }

    for (const auto& entry : snapshot.entries) {
        if (entry.revision) {
            if (!snapshot.working_copy_revision || *entry.revision < *snapshot.working_copy_revision) {
                snapshot.working_copy_revision = entry.revision;
            }
        }
    }
    return snapshot;
}

// ---------------------------------------------------------------------------
LogPage SVNXMLParser::ParseLog(std::string_view xml, std::size_t limit) {
    const XmlDocument document = Load(xml);
    RequireRoot(document, L"log");

    LogPage page;
    page.limit = limit;

    for (const auto& logentry : ChildrenNamed(document.DocumentElement(), L"logentry")) {
        LogEntry entry;
        entry.revision = IntegerAttribute(logentry, L"revision").value_or(0);

        for (const auto& child : logentry.ChildNodes()) {
            const auto name = NameOf(child);
            if (name == L"author") {
                const std::string value = Text(child);
                if (!value.empty()) {
                    entry.author = value;
                }
            } else if (name == L"date") {
                entry.date = NormalizeDate(Text(child));
            } else if (name == L"msg") {
                entry.message = Text(child);
            } else if (name == L"paths") {
                for (const auto& path : ChildrenNamed(child, L"path")) {
                    ChangedPath changed;
                    changed.action = Attribute(path, L"action").value_or("?");
                    changed.path = Text(path);
                    if (auto copy_from = Attribute(path, L"copyfrom-path")) {
                        changed.copy_from_path = *copy_from;
                    }
                    changed.copy_from_revision = IntegerAttribute(path, L"copyfrom-rev");
                    entry.changed_paths.push_back(std::move(changed));
                }
            }
        }
        page.entries.push_back(std::move(entry));
    }
    return page;
}

// ---------------------------------------------------------------------------
InfoReport SVNXMLParser::ParseInfo(std::string_view xml) {
    const XmlDocument document = Load(xml);
    RequireRoot(document, L"info");

    const auto entries = ChildrenNamed(document.DocumentElement(), L"entry");
    if (entries.empty()) {
        throw SVNParseError("<info> contains no <entry>");
    }

    // Multiple entries can be produced by `svn info . dir1 dir2`; the first is the
    // primary target (data-models.md §5).
    const auto entry = entries.front();

    InfoReport report;
    report.path = Attribute(entry, L"path").value_or("");
    report.revision = IntegerAttribute(entry, L"revision");

    if (const auto kind = Attribute(entry, L"kind")) {
        if (*kind == "file") {
            report.kind = NodeKind::file;
        } else if (*kind == "dir") {
            report.kind = NodeKind::dir;
        } else if (*kind == "none") {
            report.kind = NodeKind::none;
        } else {
            report.kind = NodeKind::unknown;
        }
    }

    for (const auto& child : entry.ChildNodes()) {
        const auto name = NameOf(child);
        if (name == L"url") {
            report.url = Text(child);
        } else if (name == L"repository") {
            if (const auto repo_root = FirstChildNamed(child, L"root")) {
                report.repository_root = Text(*repo_root);
            }
            if (const auto uuid = FirstChildNamed(child, L"uuid")) {
                report.repository_uuid = Text(*uuid);
            }
        } else if (name == L"wc-info") {
            if (const auto wcroot = FirstChildNamed(child, L"wcroot-abspath")) {
                report.working_copy_root = Text(*wcroot);
            }
            if (const auto schedule = FirstChildNamed(child, L"schedule")) {
                report.schedule = Text(*schedule);
            }
            if (const auto depth = FirstChildNamed(child, L"depth")) {
                report.depth = Text(*depth);
            }
        } else if (name == L"commit") {
            report.last_changed = ParseCommit(child);
        } else if (name == L"lock") {
            report.repository_lock = ParseLock(child);
        }
    }
    return report;
}

}  // namespace opensvn
