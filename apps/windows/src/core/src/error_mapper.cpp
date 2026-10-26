#include "opensvn/error_mapper.hpp"

#include "opensvn/redaction.hpp"
#include "opensvn/text.hpp"

#include <regex>
#include <utility>
#include <vector>

namespace opensvn {

namespace {

struct TokenRule {
    std::string_view token;
    SVNErrorCode code;
};

struct TextRule {
    std::string_view needle;
    SVNErrorCode code;
};

// Order is part of the contract: cause tokens must precede their consequences.
const std::vector<TokenRule>& token_table() {
    static const std::vector<TokenRule> table = {
        {"E170001", SVNErrorCode::authorization_failed},
        {"E215004", SVNErrorCode::authentication_required},
        {"E170008", SVNErrorCode::host_key_verification_failed},
        {"E170011", SVNErrorCode::host_key_verification_failed},
        {"E200031", SVNErrorCode::permission_denied},
        {"E000013", SVNErrorCode::permission_denied},
        {"E000030", SVNErrorCode::permission_denied},
        {"E155004", SVNErrorCode::working_copy_locked},
        {"E155037", SVNErrorCode::working_copy_locked},
        {"E155007", SVNErrorCode::not_a_working_copy},
        {"E155036", SVNErrorCode::working_copy_needs_upgrade},
        {"E195020", SVNErrorCode::working_copy_needs_upgrade},
        {"E155015", SVNErrorCode::conflict_remains},
        {"W160035", SVNErrorCode::path_locked},
        {"E160035", SVNErrorCode::path_locked},
        {"E160039", SVNErrorCode::path_locked},
        {"W160040", SVNErrorCode::not_locked},
        {"E160040", SVNErrorCode::not_locked},
        {"E195013", SVNErrorCode::not_locked},
        {"E155011", SVNErrorCode::out_of_date},
        {"E160028", SVNErrorCode::out_of_date},
        {"E160043", SVNErrorCode::repository_needs_upgrade},
        {"E160013", SVNErrorCode::path_not_found},
        {"E170013", SVNErrorCode::network_failure},
        {"E175002", SVNErrorCode::network_failure},
        {"E175012", SVNErrorCode::network_failure},
        {"E210002", SVNErrorCode::network_failure},
        {"E670002", SVNErrorCode::network_failure},
        {"E000111", SVNErrorCode::network_failure},
        {"E000054", SVNErrorCode::network_failure},
        {"E000104", SVNErrorCode::network_failure},
        {"E000061", SVNErrorCode::network_failure},
    };
    return table;
}

const std::vector<TextRule>& text_table() {
    static const std::vector<TextRule> table = {
        {"authorization failed", SVNErrorCode::authorization_failed},
        {"authentication failed", SVNErrorCode::authorization_failed},
        {"could not authenticate", SVNErrorCode::authentication_required},
        {"no more credentials", SVNErrorCode::authentication_required},
        {"is not a working copy", SVNErrorCode::not_a_working_copy},
        {"run 'svn cleanup'", SVNErrorCode::working_copy_locked},
        {"previous operation has not finished", SVNErrorCode::working_copy_locked},
        {"remains in conflict", SVNErrorCode::conflict_remains},
        {"one or more conflicts remain", SVNErrorCode::conflict_remains},
        {"is already locked by user", SVNErrorCode::path_locked},
        {"is not locked in this working copy", SVNErrorCode::not_locked},
        {"no lock on path", SVNErrorCode::not_locked},
        {"out of date", SVNErrorCode::out_of_date},
        {"unable to connect", SVNErrorCode::network_failure},
        {"connection refused", SVNErrorCode::network_failure},
        {"connection timed out", SVNErrorCode::network_failure},
        {"connection reset by peer", SVNErrorCode::network_failure},
        {"can't read from connection", SVNErrorCode::network_failure},
        {"connection was closed", SVNErrorCode::network_failure},
        {"host key verification failed", SVNErrorCode::host_key_verification_failed},
        {"unsupported working copy format", SVNErrorCode::working_copy_needs_upgrade},
        {"too old", SVNErrorCode::working_copy_needs_upgrade},
        {"attempt to write a readonly database", SVNErrorCode::permission_denied},
        {"permission denied", SVNErrorCode::permission_denied},
        {"read-only file system", SVNErrorCode::permission_denied},
        {"expected fs format", SVNErrorCode::repository_needs_upgrade},
        {"unsupported repository format", SVNErrorCode::repository_needs_upgrade},
    };
    return table;
}

std::optional<std::string> first_token(std::string_view text) {
    static const std::regex expression(R"(E\d{6})");
    std::smatch match;
    const std::string input(text);
    if (!std::regex_search(input, match, expression)) return std::nullopt;
    return match[0].str();
}

std::string first_meaningful_line(std::string_view output) {
    const auto lines = text::split_lines(output);
    std::string fallback;
    for (const auto& raw : lines) {
        const std::string line = text::trim(raw);
        if (line.empty()) continue;
        fallback = line;
        if (text::lower_ascii(line).rfind("svn:", 0) == 0) {
            static const std::regex prefix(R"(^svn:\s*E\d{6}:\s*)");
            std::smatch match;
            if (std::regex_search(line, match, prefix)) {
                return line.substr(static_cast<std::size_t>(match.length()));
            }
            return line;
        }
    }
    return fallback;
}

std::string user_message(SVNErrorCode code, std::string_view output) {
    switch (code) {
    case SVNErrorCode::working_copy_locked:
        return "工作副本被锁定或上一次操作未完成";
    case SVNErrorCode::not_a_working_copy:
        return "目标不是 SVN 工作副本";
    case SVNErrorCode::working_copy_needs_upgrade:
        return "工作副本格式不受支持";
    case SVNErrorCode::permission_denied:
        return "工作副本目录或磁盘不可写";
    case SVNErrorCode::repository_needs_upgrade:
        return "仓库数据格式不受支持";
    case SVNErrorCode::authentication_required:
        return "服务器要求认证";
    case SVNErrorCode::authorization_failed:
        return "认证被服务器拒绝";
    case SVNErrorCode::host_key_verification_failed:
        return "SSH 主机密钥校验失败";
    case SVNErrorCode::network_failure:
        return "无法连接仓库服务器";
    case SVNErrorCode::out_of_date:
        return "工作副本已过期";
    case SVNErrorCode::conflict_remains:
        return "存在未解决的冲突";
    case SVNErrorCode::path_not_found:
        return "路径不存在";
    case SVNErrorCode::backup_failed:
        return "无法在解决冲突前备份文件，操作已中止";
    case SVNErrorCode::path_locked:
        return "路径已被他人锁定";
    case SVNErrorCode::not_locked:
        return "路径没有锁";
    case SVNErrorCode::cancelled:
        return "操作已取消";
    case SVNErrorCode::timeout:
        return "操作超时";
    case SVNErrorCode::confirmation_required:
        return "需要确认后才能执行";
    case SVNErrorCode::invalid_invocation:
        return "命令参数无效";
    case SVNErrorCode::xml_parse_failure:
        return "无法解析 svn 输出";
    case SVNErrorCode::unsupported_version:
        return "svn 版本不受支持";
    case SVNErrorCode::svn_not_found:
        return "找不到 svn 可执行文件";
    case SVNErrorCode::command_failed: {
        // stdout/stderr can contain URLs with userinfo or --password literals.
        // The diagnostic field is redacted in make_error; the message shown to
        // the user must not be a second, unredacted path for the same text.
        const std::string detail = LogRedactor::redact(first_meaningful_line(output));
        return detail.empty() ? "svn 执行失败" : detail;
    }
    case SVNErrorCode::unknown:
        return "未知错误";
    }
    return "未知错误";
}

SVNError make_error(SVNErrorCode code, std::int32_t exit_code, std::string_view output,
                    std::optional<std::string> svn_code, std::string_view command_line) {
    (void)command_line;
    return SVNError{code, user_message(code, output),
                    LogRedactor::redact(output), std::move(svn_code), exit_code};
}

} // namespace

std::optional<SVNError> SVNErrorMapper::error_from(const ProcessResult& result) {
    if (result.success()) return std::nullopt;
    return error(result.exit_code, result.standard_error, result.standard_output,
                 result.command_line);
}

SVNError SVNErrorMapper::error(std::int32_t exit_code, std::string_view standard_error,
                               std::string_view standard_output,
                               std::string_view command_line) {
    const std::string_view haystack =
        standard_error.empty() ? standard_output : standard_error;
    const std::string lowered = text::lower_ascii(haystack);

    for (const auto& rule : token_table()) {
        if (haystack.find(rule.token) != std::string_view::npos) {
            return make_error(rule.code, exit_code, haystack, std::string(rule.token),
                              command_line);
        }
    }
    for (const auto& rule : text_table()) {
        if (lowered.find(rule.needle) != std::string::npos) {
            return make_error(rule.code, exit_code, haystack, first_token(haystack),
                              command_line);
        }
    }

    SVNError result =
        make_error(SVNErrorCode::command_failed, exit_code, haystack, first_token(haystack),
                   command_line);
    if (result.message == "svn 执行失败") {
        result.message += "（退出码 " + std::to_string(exit_code) + "）";
    }
    return result;
}

} // namespace opensvn
