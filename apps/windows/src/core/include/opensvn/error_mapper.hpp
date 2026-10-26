#pragma once

#include "opensvn/errors.hpp"
#include "opensvn/process.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace opensvn {

/// Translates raw svn failures into application error codes. The authoritative
/// table is specifications/error-codes.md; SVN tokens are matched before free
/// text because wording changes between releases and locales.
class SVNErrorMapper {
public:
    /// Returns nullopt when the result represents success.
    static std::optional<SVNError> error_from(const ProcessResult& result);

    static SVNError error(std::int32_t exit_code, std::string_view standard_error,
                          std::string_view standard_output = {},
                          std::string_view command_line = {});
};

} // namespace opensvn
