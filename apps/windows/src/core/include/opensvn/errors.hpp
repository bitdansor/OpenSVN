#pragma once

#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

namespace opensvn {

/// Application-level classification, 1:1 with specifications/error-codes.md.
enum class SVNErrorCode {
    svn_not_found,
    unsupported_version,
    not_a_working_copy,
    working_copy_locked,
    working_copy_needs_upgrade,
    permission_denied,
    repository_needs_upgrade,
    authentication_required,
    authorization_failed,
    network_failure,
    out_of_date,
    conflict_remains,
    path_not_found,
    backup_failed,
    path_locked,
    not_locked,
    host_key_verification_failed,
    timeout,
    cancelled,
    confirmation_required,
    invalid_invocation,
    xml_parse_failure,
    command_failed,
    unknown,
};

enum class ErrorSeverity { recoverable, needs_user_action, fatal };

std::string_view to_string(ErrorSeverity severity);
std::string_view identifier(SVNErrorCode code);
ErrorSeverity severity(SVNErrorCode code);
std::string_view remediation(SVNErrorCode code);
bool is_authentication_related(SVNErrorCode code);
bool is_reachability_related(SVNErrorCode code);

/// The single error type surfaced by the core layer.
struct SVNError {
    SVNErrorCode code = SVNErrorCode::unknown;
    std::string message;
    std::optional<std::string> diagnostic_output;
    std::optional<std::string> svn_code;
    std::optional<std::int32_t> exit_code;

    std::string identifier() const { return std::string(opensvn::identifier(code)); }
    ErrorSeverity severity() const { return opensvn::severity(code); }
    std::string description() const;
};

class SVNException : public std::runtime_error {
public:
    explicit SVNException(SVNError error);
    explicit SVNException(SVNErrorCode code, std::string message,
                          std::optional<std::string> diagnostic_output = std::nullopt,
                          std::optional<std::string> svn_code = std::nullopt,
                          std::optional<std::int32_t> exit_code = std::nullopt);

    const SVNError& error() const { return error_; }

private:
    SVNError error_;
    static std::string render(const SVNError& error);
};

[[noreturn]] void throw_svn_error(SVNErrorCode code, std::string message,
                                  std::optional<std::string> diagnostic_output = std::nullopt,
                                  std::optional<std::string> svn_code = std::nullopt,
                                  std::optional<std::int32_t> exit_code = std::nullopt);

} // namespace opensvn
