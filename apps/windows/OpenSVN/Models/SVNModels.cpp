// Implementations for SVNModels.h — no Windows dependencies, so this compiles
// and is unit-testable on any C++20 toolchain. The Windows build must produce
// byte-identical JSON to the macOS build for the same fixture; keeping this
// file portable is what makes that testable off-Windows.

#include "SVNModels.h"

#include <array>
#include <utility>

namespace opensvn {
namespace {

struct StatusToken {
    std::string_view token;
    WCItemStatus::Kind kind;
};

// Must match WCItemStatus in the macOS implementation. Order is irrelevant;
// lookup is by token.
constexpr std::array<StatusToken, 15> kStatusTokens{{
    {"added", WCItemStatus::Kind::added},
    {"conflicted", WCItemStatus::Kind::conflicted},
    {"deleted", WCItemStatus::Kind::deleted},
    {"external", WCItemStatus::Kind::external},
    {"ignored", WCItemStatus::Kind::ignored},
    {"incomplete", WCItemStatus::Kind::incomplete},
    {"invalid", WCItemStatus::Kind::invalid},
    {"merged", WCItemStatus::Kind::merged},
    {"missing", WCItemStatus::Kind::missing},
    {"modified", WCItemStatus::Kind::modified},
    {"none", WCItemStatus::Kind::none},
    {"normal", WCItemStatus::Kind::normal},
    {"obstructed", WCItemStatus::Kind::obstructed},
    {"replaced", WCItemStatus::Kind::replaced},
    {"unversioned", WCItemStatus::Kind::unversioned},
}};

std::string_view CanonicalName(WCItemStatus::Kind kind) {
    switch (kind) {
        case WCItemStatus::Kind::added: return "added";
        case WCItemStatus::Kind::conflicted: return "conflicted";
        case WCItemStatus::Kind::deleted: return "deleted";
        case WCItemStatus::Kind::external: return "external";
        case WCItemStatus::Kind::ignored: return "ignored";
        case WCItemStatus::Kind::incomplete: return "incomplete";
        case WCItemStatus::Kind::invalid: return "invalid";
        case WCItemStatus::Kind::merged: return "merged";
        case WCItemStatus::Kind::missing: return "missing";
        case WCItemStatus::Kind::modified: return "modified";
        case WCItemStatus::Kind::none: return "none";
        case WCItemStatus::Kind::normal: return "normal";
        case WCItemStatus::Kind::obstructed: return "obstructed";
        case WCItemStatus::Kind::replaced: return "replaced";
        case WCItemStatus::Kind::unversioned: return "unversioned";
        case WCItemStatus::Kind::unknown: return "unknown";
    }
    return "unknown";
}

}  // namespace

WCItemStatus WCItemStatus::Parse(std::string_view token) {
    for (const auto& entry : kStatusTokens) {
        if (entry.token == token) {
            return WCItemStatus{entry.kind};
        }
    }
    // data-models.md §2: an unrecognised token is preserved verbatim. Guessing
    // "normal" here would hide a real state from the user.
    return WCItemStatus{Kind::unknown, std::string(token)};
}

std::string_view WCItemStatus::ToString() const {
    if (kind == Kind::unknown) {
        return raw;
    }
    return CanonicalName(kind);
}

std::vector<std::string> ConflictFlags::ToList() const {
    std::vector<std::string> result;
    if (Has(kConflictText)) result.emplace_back("text");
    if (Has(kConflictProperty)) result.emplace_back("property");
    if (Has(kConflictTree)) result.emplace_back("tree");
    return result;
}

StatusCategory CategoryOf(const StatusEntry& entry) {
    // Conflict wins over the underlying item: a text conflict is still a
    // `modified` entry in svn's output, but the user must see "conflict".
    if (entry.HasConflicts()) {
        return StatusCategory::conflicted;
    }
    switch (entry.text_status.kind) {
        case WCItemStatus::Kind::modified: return StatusCategory::modified;
        case WCItemStatus::Kind::added: return StatusCategory::added;
        case WCItemStatus::Kind::deleted:
        case WCItemStatus::Kind::missing: return StatusCategory::deleted;
        case WCItemStatus::Kind::replaced: return StatusCategory::replaced;
        case WCItemStatus::Kind::unversioned: return StatusCategory::unversioned;
        case WCItemStatus::Kind::ignored: return StatusCategory::ignored;
        case WCItemStatus::Kind::normal:
        case WCItemStatus::Kind::none: return StatusCategory::normal;
        default: return StatusCategory::other;
    }
}

std::optional<std::int64_t> LogPage::oldest_revision() const {
    if (entries.empty()) {
        return std::nullopt;
    }
    // svn log is newest-first; the oldest revision is the last entry, but do not
    // assume ordering — take the minimum so a reversed page still pages right.
    std::int64_t oldest = entries.front().revision;
    for (const auto& entry : entries) {
        if (entry.revision < oldest) {
            oldest = entry.revision;
        }
    }
    return oldest;
}

std::string SVNError::identifier() const {
    switch (code) {
        case SVNErrorCode::svnNotFound: return "SVN-0001";
        case SVNErrorCode::unsupportedVersion: return "SVN-0002";
        case SVNErrorCode::notAWorkingCopy: return "SVN-0003";
        case SVNErrorCode::workingCopyLocked: return "SVN-0004";
        case SVNErrorCode::workingCopyNeedsUpgrade: return "SVN-0005";
        case SVNErrorCode::authenticationRequired: return "SVN-0101";
        case SVNErrorCode::authorizationFailed: return "SVN-0102";
        case SVNErrorCode::hostKeyVerificationFailed: return "SVN-0103";
        case SVNErrorCode::networkFailure: return "SVN-0201";
        case SVNErrorCode::outOfDate: return "SVN-0202";
        case SVNErrorCode::conflictRemains: return "SVN-0301";
        case SVNErrorCode::pathNotFound: return "SVN-0302";
        case SVNErrorCode::backupFailed: return "SVN-0303";
        case SVNErrorCode::timeout: return "SVN-0401";
        case SVNErrorCode::cancelled: return "SVN-0402";
        case SVNErrorCode::confirmationRequired: return "SVN-0501";
        case SVNErrorCode::invalidInvocation: return "SVN-9001";
        case SVNErrorCode::xmlParseFailure: return "SVN-9002";
        case SVNErrorCode::commandFailed: return "SVN-9999";
        case SVNErrorCode::unknown: return "SVN-9998";
    }
    return "SVN-9998";
}

std::string SVNError::remediation() const {
    switch (code) {
        case SVNErrorCode::workingCopyLocked:
            return "工作副本被锁定。请先执行 Cleanup 清理内部锁。";
        case SVNErrorCode::workingCopyNeedsUpgrade:
            return "该工作副本由更新版本的 Subversion 创建，OpenSVN 不会自动升级它。请使用兼容版本的客户端。";
        case SVNErrorCode::notAWorkingCopy:
            return "所选目录不是 SVN 工作副本，或已被移动。";
        case SVNErrorCode::authenticationRequired:
            return "需要输入该仓库的用户名与密码。";
        case SVNErrorCode::authorizationFailed:
            return "凭据已被服务器拒绝，请检查用户名、密码或访问权限。";
        case SVNErrorCode::networkFailure:
            return "无法连接服务器，请检查网络、代理或仓库地址。";
        case SVNErrorCode::outOfDate:
            return "本地副本已过期，请先 Update 再提交。";
        case SVNErrorCode::conflictRemains:
            return "仍有未解决的冲突，解决后需标记 resolve 才能提交。";
        case SVNErrorCode::hostKeyVerificationFailed:
            return "服务器 SSH 主机密钥未被信任，请核对指纹后再连接。";
        case SVNErrorCode::timeout:
            return "操作超时，可重试或检查网络。";
        case SVNErrorCode::cancelled:
            return "操作已取消。工作副本可能处于中间状态，必要时执行 Cleanup。";
        case SVNErrorCode::confirmationRequired:
            return "该操作会修改或丢弃本地数据，需要确认后才能执行。";
        case SVNErrorCode::svnNotFound:
            return "未找到可用的 svn 可执行文件，请在设置中指定路径或安装运行时。";
        case SVNErrorCode::unsupportedVersion:
            return "当前 svn 版本不在支持区间内，请升级 OpenSVN 或改用受支持的 svn。";
        case SVNErrorCode::pathNotFound:
            return "目标路径不存在或已被删除。";
        case SVNErrorCode::backupFailed:
            return "无法在解决冲突前备份文件，操作已中止以免数据丢失。请检查磁盘空间与目录写权限。";
        case SVNErrorCode::invalidInvocation:
        case SVNErrorCode::xmlParseFailure:
        case SVNErrorCode::commandFailed:
        case SVNErrorCode::unknown:
            return "请查看诊断日志，如可复现请附上日志提交 issue。";
    }
    return "请查看诊断日志，如可复现请附上日志提交 issue。";
}

ErrorSeverity SVNError::severity() const {
    switch (code) {
        case SVNErrorCode::networkFailure:
        case SVNErrorCode::workingCopyLocked:
        case SVNErrorCode::outOfDate:
            return ErrorSeverity::recoverable;
        case SVNErrorCode::authenticationRequired:
        case SVNErrorCode::authorizationFailed:
        case SVNErrorCode::conflictRemains:
        case SVNErrorCode::confirmationRequired:
        case SVNErrorCode::hostKeyVerificationFailed:
        case SVNErrorCode::notAWorkingCopy:
            return ErrorSeverity::needsUserAction;
        default:
            return ErrorSeverity::fatal;
    }
}

std::string SVNError::Display() const {
    std::string text = "[" + identifier() + "] " + message;
    if (!svn_code.empty()) {
        text += " (" + svn_code + ")";
    }
    text += "\n" + remediation();
    return text;
}

bool IsDestructive(ResolveStrategy strategy) {
    // `working` only records that the user resolved the conflict by hand; the
    // other three overwrite a side of the merge and cannot be undone.
    return strategy != ResolveStrategy::working;
}

std::string_view ToToken(ResolveStrategy strategy) {
    switch (strategy) {
        case ResolveStrategy::working: return "working";
        case ResolveStrategy::mine_full: return "mine-full";
        case ResolveStrategy::theirs_full: return "theirs-full";
        case ResolveStrategy::base: return "base";
    }
    return "working";
}

}  // namespace opensvn
