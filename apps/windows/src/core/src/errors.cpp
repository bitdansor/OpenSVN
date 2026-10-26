#include "opensvn/errors.hpp"

namespace opensvn {

std::string_view to_string(ErrorSeverity severity) {
    switch (severity) {
    case ErrorSeverity::recoverable: return "recoverable";
    case ErrorSeverity::needs_user_action: return "needsUserAction";
    case ErrorSeverity::fatal: return "fatal";
    }
    return "fatal";
}

std::string_view identifier(SVNErrorCode code) {
    switch (code) {
    case SVNErrorCode::svn_not_found: return "SVN-0001";
    case SVNErrorCode::unsupported_version: return "SVN-0002";
    case SVNErrorCode::not_a_working_copy: return "SVN-0003";
    case SVNErrorCode::working_copy_locked: return "SVN-0004";
    case SVNErrorCode::working_copy_needs_upgrade: return "SVN-0005";
    case SVNErrorCode::permission_denied: return "SVN-0006";
    case SVNErrorCode::repository_needs_upgrade: return "SVN-0007";
    case SVNErrorCode::authentication_required: return "SVN-0101";
    case SVNErrorCode::authorization_failed: return "SVN-0102";
    case SVNErrorCode::host_key_verification_failed: return "SVN-0103";
    case SVNErrorCode::network_failure: return "SVN-0201";
    case SVNErrorCode::out_of_date: return "SVN-0202";
    case SVNErrorCode::conflict_remains: return "SVN-0301";
    case SVNErrorCode::path_not_found: return "SVN-0302";
    case SVNErrorCode::backup_failed: return "SVN-0303";
    case SVNErrorCode::path_locked: return "SVN-0304";
    case SVNErrorCode::not_locked: return "SVN-0305";
    case SVNErrorCode::timeout: return "SVN-0401";
    case SVNErrorCode::cancelled: return "SVN-0402";
    case SVNErrorCode::confirmation_required: return "SVN-0501";
    case SVNErrorCode::invalid_invocation: return "SVN-9001";
    case SVNErrorCode::xml_parse_failure: return "SVN-9002";
    case SVNErrorCode::command_failed: return "SVN-9999";
    case SVNErrorCode::unknown: return "SVN-9998";
    }
    return "SVN-9998";
}

ErrorSeverity severity(SVNErrorCode code) {
    switch (code) {
    case SVNErrorCode::network_failure:
    case SVNErrorCode::working_copy_locked:
    case SVNErrorCode::out_of_date:
    case SVNErrorCode::not_locked:
        return ErrorSeverity::recoverable;
    case SVNErrorCode::authentication_required:
    case SVNErrorCode::authorization_failed:
    case SVNErrorCode::conflict_remains:
    case SVNErrorCode::confirmation_required:
    case SVNErrorCode::host_key_verification_failed:
    case SVNErrorCode::not_a_working_copy:
    case SVNErrorCode::permission_denied:
    case SVNErrorCode::path_locked:
        return ErrorSeverity::needs_user_action;
    default:
        return ErrorSeverity::fatal;
    }
}

std::string_view remediation(SVNErrorCode code) {
    switch (code) {
    case SVNErrorCode::working_copy_locked:
        return "工作副本被锁定。请先执行 Cleanup 清理内部锁。";
    case SVNErrorCode::working_copy_needs_upgrade:
        return "该工作副本由更新版本的 Subversion 创建，OpenSVN 不会自动升级它。请使用兼容版本的客户端。";
    case SVNErrorCode::permission_denied:
        return "工作副本目录或磁盘不可写。请检查文件权限、只读卷或磁盘空间；Cleanup 无法解决只读磁盘。";
    case SVNErrorCode::repository_needs_upgrade:
        return "仓库的数据格式不在当前 svn 的支持范围内。OpenSVN 不会自动升级仓库，请使用与该仓库匹配的 svn，或由仓库管理员升级。";
    case SVNErrorCode::not_a_working_copy:
        return "所选目录不是 SVN 工作副本，或已被移动。";
    case SVNErrorCode::authentication_required:
        return "需要输入该仓库的用户名与密码。";
    case SVNErrorCode::authorization_failed:
        return "凭据已被服务器拒绝，请检查用户名、密码或访问权限。";
    case SVNErrorCode::host_key_verification_failed:
        return "服务器 SSH 主机密钥未被信任，请核对指纹后再连接。";
    case SVNErrorCode::network_failure:
        return "无法连接服务器，请检查网络、代理或仓库地址。";
    case SVNErrorCode::out_of_date:
        return "本地副本已过期，请先 Update 再提交。";
    case SVNErrorCode::conflict_remains:
        return "仍有未解决的冲突，解决后需标记 resolve 才能提交。";
    case SVNErrorCode::path_not_found:
        return "目标路径不存在或已被删除。";
    case SVNErrorCode::backup_failed:
        return "无法在解决冲突前备份文件，操作已中止以免数据丢失。请检查磁盘空间与目录写权限。";
    case SVNErrorCode::path_locked:
        return "该路径已被他人锁定。请对方解除锁定，或在确认风险后使用「强制锁定」抢占。";
    case SVNErrorCode::not_locked:
        return "该路径当前没有锁。它可能已被他人释放或抢占，刷新锁定状态后再操作。";
    case SVNErrorCode::timeout:
        return "先刷新状态或检查服务器历史，确认操作没有完成后才重试；必要时调整超时。";
    case SVNErrorCode::cancelled:
        return "操作已取消。工作副本可能处于中间状态，必要时执行 Cleanup。";
    case SVNErrorCode::confirmation_required:
        return "该操作会修改或丢弃本地数据，需要确认后才能执行。";
    case SVNErrorCode::svn_not_found:
        return "未找到可用的 svn 可执行文件，请在设置中指定路径或安装运行时。";
    case SVNErrorCode::unsupported_version:
        return "当前 svn 版本不在支持区间内，请升级 OpenSVN 或改用受支持的 svn。";
    case SVNErrorCode::invalid_invocation:
    case SVNErrorCode::xml_parse_failure:
    case SVNErrorCode::command_failed:
    case SVNErrorCode::unknown:
        return "请查看诊断日志，如可复现请附上日志提交 issue。";
    }
    return "请查看诊断日志。";
}

bool is_authentication_related(SVNErrorCode code) {
    return code == SVNErrorCode::authentication_required ||
           code == SVNErrorCode::authorization_failed;
}

bool is_reachability_related(SVNErrorCode code) {
    return code == SVNErrorCode::network_failure || code == SVNErrorCode::timeout ||
           code == SVNErrorCode::host_key_verification_failed;
}

std::string SVNError::description() const {
    std::string text = "[" + identifier() + "] " + message;
    if (svn_code) text += " (" + *svn_code + ")";
    const auto hint = remediation(code);
    if (!hint.empty()) text += "\n" + std::string(hint);
    return text;
}

SVNException::SVNException(SVNError error)
    : std::runtime_error(render(error)), error_(std::move(error)) {}

SVNException::SVNException(SVNErrorCode code, std::string message,
                           std::optional<std::string> diagnostic_output,
                           std::optional<std::string> svn_code,
                           std::optional<std::int32_t> exit_code)
    : SVNException(SVNError{code, std::move(message), std::move(diagnostic_output),
                            std::move(svn_code), exit_code}) {}

std::string SVNException::render(const SVNError& error) { return error.description(); }

void throw_svn_error(SVNErrorCode code, std::string message,
                     std::optional<std::string> diagnostic_output,
                     std::optional<std::string> svn_code,
                     std::optional<std::int32_t> exit_code) {
    throw SVNException(code, std::move(message), std::move(diagnostic_output),
                       std::move(svn_code), exit_code);
}

} // namespace opensvn
