// OpenSVN — `svn --xml` parsing (Windows).
//
// Contract: specifications/data-models.md. The parser is the one place where the
// two platforms must agree byte for byte, so it is deliberately boring: read the
// document, map attributes, never guess. Unknown values are preserved, not
// normalised away (an unknown status token must reach the UI, not become "normal").
//
// Implementation uses Windows.Data.Xml.Dom (already available to a WinUI 3 app),
// which keeps the dependency count at zero — no pugixml, no vcpkg for this part.

#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>
#include <string_view>

#include "Models/SVNModels.h"

namespace opensvn {

// Thrown for malformed XML or a document whose shape does not match the command
// that produced it. Callers map it to SVNErrorCode::xmlParseFailure (SVN-9002).
class SVNParseError : public std::runtime_error {
public:
    explicit SVNParseError(const std::string& message) : std::runtime_error(message) {}
};

class SVNXMLParser {
public:
    // `svn status --xml`
    static StatusSnapshot ParseStatus(std::string_view xml);

    // `svn log --xml -v`. `limit` is the limit that was requested, so the page
    // can report `has_more()` without re-reading svn's mind.
    static LogPage ParseLog(std::string_view xml, std::size_t limit);

    // `svn info --xml`
    static InfoReport ParseInfo(std::string_view xml);

    // "2026-10-18T04:35:56.116935Z" -> "2026-10-18T04:35:56.116Z".
    // Truncates, never rounds: rounding could move a commit into the next second
    // and make two platforms disagree.
    static std::string NormalizeDate(std::string_view raw);
};

}  // namespace opensvn
