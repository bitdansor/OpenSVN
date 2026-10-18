import Foundation

/// Application-level error classification. These map 1:1 to the table in
/// `specifications/error-codes.md`; the raw SVN error code (e.g. `E155004`)
/// is preserved on the error so support reports stay actionable.
public enum SVNErrorCode: Sendable, Hashable, Codable {
    case svnNotFound
    case unsupportedVersion(found: String, minimum: String)
    case notAWorkingCopy
    case workingCopyLocked
    case workingCopyNeedsUpgrade
    case authenticationRequired
    case authorizationFailed
    case networkFailure
    case outOfDate
    case conflictRemains
    case pathNotFound
    case hostKeyVerificationFailed
    case timeout
    case cancelled
    case confirmationRequired
    case invalidInvocation
    case xmlParseFailure
    case commandFailed(exitCode: Int32)
    case unknown

    /// How the UI should present the failure.
    public enum Severity: String, Sendable, Codable {
        /// Safe to retry automatically (transient network, lock held by us).
        case recoverable
        /// Needs a user decision (credentials, conflict, confirmation).
        case needsUserAction
        /// Cannot continue; report with diagnostics.
        case fatal
    }

    public var severity: Severity {
        switch self {
        case .networkFailure, .workingCopyLocked, .outOfDate:
            return .recoverable
        case .authenticationRequired, .authorizationFailed, .conflictRemains,
             .confirmationRequired, .hostKeyVerificationFailed, .notAWorkingCopy:
            return .needsUserAction
        case .svnNotFound, .unsupportedVersion, .workingCopyNeedsUpgrade,
             .pathNotFound, .timeout, .cancelled, .invalidInvocation,
             .xmlParseFailure, .commandFailed, .unknown:
            return .fatal
        }
    }

    /// Stable identifier shared by both platforms. Do not renumber.
    public var identifier: String {
        switch self {
        case .svnNotFound: return "SVN-0001"
        case .unsupportedVersion: return "SVN-0002"
        case .notAWorkingCopy: return "SVN-0003"
        case .workingCopyLocked: return "SVN-0004"
        case .workingCopyNeedsUpgrade: return "SVN-0005"
        case .authenticationRequired: return "SVN-0101"
        case .authorizationFailed: return "SVN-0102"
        case .networkFailure: return "SVN-0201"
        case .outOfDate: return "SVN-0202"
        case .conflictRemains: return "SVN-0301"
        case .pathNotFound: return "SVN-0302"
        case .hostKeyVerificationFailed: return "SVN-0103"
        case .timeout: return "SVN-0401"
        case .cancelled: return "SVN-0402"
        case .confirmationRequired: return "SVN-0501"
        case .invalidInvocation: return "SVN-9001"
        case .xmlParseFailure: return "SVN-9002"
        case .commandFailed: return "SVN-9999"
        case .unknown: return "SVN-9998"
        }
    }

    /// What the user can do about it. UI shows this as the recovery hint.
    public var remediation: String? {
        switch self {
        case .workingCopyLocked:
            return "工作副本被锁定。请先执行 Cleanup 清理内部锁。"
        case .workingCopyNeedsUpgrade:
            return "该工作副本由更新版本的 Subversion 创建，OpenSVN 不会自动升级它。请使用兼容版本的客户端。"
        case .notAWorkingCopy:
            return "所选目录不是 SVN 工作副本，或已被移动。"
        case .authenticationRequired:
            return "需要输入该仓库的用户名与密码。"
        case .authorizationFailed:
            return "凭据已被服务器拒绝，请检查用户名、密码或访问权限。"
        case .networkFailure:
            return "无法连接服务器，请检查网络、代理或仓库地址。"
        case .outOfDate:
            return "本地副本已过期，请先 Update 再提交。"
        case .conflictRemains:
            return "仍有未解决的冲突，解决后需标记 resolve 才能提交。"
        case .hostKeyVerificationFailed:
            return "服务器 SSH 主机密钥未被信任，请核对指纹后再连接。"
        case .timeout:
            return "操作超时，可重试或检查网络。"
        case .cancelled:
            return "操作已取消。工作副本可能处于中间状态，必要时执行 Cleanup。"
        case .confirmationRequired:
            return "该操作会修改或丢弃本地数据，需要确认后才能执行。"
        case .svnNotFound:
            return "未找到可用的 svn 可执行文件，请在设置中指定路径或安装运行时。"
        case .unsupportedVersion:
            return "当前 svn 版本不在支持区间内，请升级 OpenSVN 或改用受支持的 svn。"
        case .pathNotFound:
            return "目标路径不存在或已被删除。"
        case .invalidInvocation, .xmlParseFailure, .commandFailed, .unknown:
            return "请查看诊断日志，如可复现请附上日志提交 issue。"
        }
    }
}

/// The single error type surfaced by the core layer.
public struct SVNError: Error, Sendable, Hashable, LocalizedError {
    public var code: SVNErrorCode
    /// Redacted, user-presentable message.
    public var message: String
    /// Raw stderr, redacted. Kept for diagnostics only.
    public var diagnosticOutput: String?
    /// Raw SVN error token such as `E155004`, when one could be extracted.
    public var svnCode: String?
    public var exitCode: Int32?

    public init(
        code: SVNErrorCode,
        message: String,
        diagnosticOutput: String? = nil,
        svnCode: String? = nil,
        exitCode: Int32? = nil
    ) {
        self.code = code
        self.message = message
        self.diagnosticOutput = diagnosticOutput
        self.svnCode = svnCode
        self.exitCode = exitCode
    }

    public var errorDescription: String? {
        var text = "[\(code.identifier)] \(message)"
        if let svnCode { text += " (\(svnCode))" }
        if let remediation = code.remediation { text += "\n\(remediation)" }
        return text
    }

    public var failureReason: String? { code.remediation }

    public var recoverySuggestion: String? { code.remediation }

    public static func cancelled() -> SVNError {
        SVNError(code: .cancelled, message: "操作已取消")
    }

    public static func timeout(seconds: TimeInterval) -> SVNError {
        SVNError(code: .timeout, message: "操作超时（\(Int(seconds)) 秒）")
    }
}
