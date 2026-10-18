import Foundation

/// Translates a raw `svn` failure into an application error code.
///
/// The authoritative mapping table lives in `specifications/error-codes.md`;
/// this type must stay in sync with it. SVN error tokens (`E155004`, …) are
/// matched before free-text heuristics because message wording changes between
/// releases and locales.
public enum SVNErrorMapper {
    /// Ordered by specificity: authentication and working-copy states first,
    /// generic transport failures last.
    private static let tokenTable: [(token: String, code: SVNErrorCode)] = [
        ("E170001", .authorizationFailed),
        ("E215004", .authenticationRequired),
        ("E170008", .hostKeyVerificationFailed),
        ("E170011", .hostKeyVerificationFailed),
        // A read-only working copy reports `E155004 … Failed to lock working copy`
        // followed by `E200031: sqlite: attempt to write a readonly database`.
        // The lock token comes first in the output, so the permission tokens must
        // be *matched* first — otherwise the user is told to run cleanup, which
        // fails for the same reason the commit did.
        ("E200031", .permissionDenied),
        ("E000013", .permissionDenied),
        ("E000030", .permissionDenied),
        ("E155004", .workingCopyLocked),
        ("E155037", .workingCopyLocked),
        ("E155007", .notAWorkingCopy),
        ("E155036", .workingCopyNeedsUpgrade),
        ("E195020", .workingCopyNeedsUpgrade),
        ("E155015", .conflictRemains),
        ("E155011", .outOfDate),
        ("E160028", .outOfDate),
        // `svn checkout file://repo` against a repository written by a newer
        // svn reports "Unable to connect" (E170013), "Unable to open
        // repository" (E180001) and only then the real cause, E160043. Matching
        // E170013 first sends the user to check the network for a repository
        // that is simply too new.
        ("E160043", .repositoryNeedsUpgrade),
        ("E160013", .pathNotFound),
        ("E170013", .networkFailure),
        ("E175002", .networkFailure),
        ("E175012", .networkFailure),
        ("E210002", .networkFailure),
        ("E670002", .networkFailure),
        ("E000111", .networkFailure),
        // APR_ECONNRESET: the peer reset the connection mid-response. This is
        // what a dropped Wi-Fi link or a flapping VPN looks like, and it arrives
        // with no other `E` token to lean on.
        //
        // The numeric suffix is the platform's errno, so the same failure has
        // different tokens on macOS (54 / 61) and Linux (104 / 111) — which is
        // why E000111 is already in this table.
        ("E000054", .networkFailure),
        ("E000104", .networkFailure),
        ("E000061", .networkFailure)
    ]

    private static let textTable: [(needle: String, code: SVNErrorCode)] = [
        ("authorization failed", .authorizationFailed),
        ("authentication failed", .authorizationFailed),
        ("could not authenticate", .authenticationRequired),
        ("no more credentials", .authenticationRequired),
        ("is not a working copy", .notAWorkingCopy),
        ("run 'svn cleanup'", .workingCopyLocked),
        ("previous operation has not finished", .workingCopyLocked),
        ("remains in conflict", .conflictRemains),
        ("one or more conflicts remain", .conflictRemains),
        ("out of date", .outOfDate),
        ("unable to connect", .networkFailure),
        ("connection refused", .networkFailure),
        ("connection timed out", .networkFailure),
        ("connection reset by peer", .networkFailure),
        ("can't read from connection", .networkFailure),
        ("connection was closed", .networkFailure),
        ("host key verification failed", .hostKeyVerificationFailed),
        ("unsupported working copy format", .workingCopyNeedsUpgrade),
        ("too old", .workingCopyNeedsUpgrade),
        // Only reached when no `E` token is present at all, e.g. a wrapper script
        // that swallowed the code.
        ("attempt to write a readonly database", .permissionDenied),
        ("permission denied", .permissionDenied),
        ("read-only file system", .permissionDenied),
        ("expected fs format", .repositoryNeedsUpgrade),
        ("unsupported repository format", .repositoryNeedsUpgrade)
    ]

    /// Returns nil when the result represents success.
    public static func error(from result: SVNProcessResult) -> SVNError? {
        guard !result.isSuccess else { return nil }
        return error(
            exitCode: result.exitCode,
            standardError: result.standardError,
            standardOutput: result.standardOutput,
            commandLine: result.commandLine
        )
    }

    public static func error(
        exitCode: Int32,
        standardError: String,
        standardOutput: String = "",
        commandLine: String = ""
    ) -> SVNError {
        let haystack = standardError.isEmpty ? standardOutput : standardError
        let lowercased = haystack.lowercased()

        for (token, code) in tokenTable where haystack.contains(token) {
            return makeError(code: code, exitCode: exitCode, output: haystack, svnCode: token, commandLine: commandLine)
        }
        for (needle, code) in textTable where lowercased.contains(needle) {
            return makeError(code: code, exitCode: exitCode, output: haystack, svnCode: firstToken(in: haystack), commandLine: commandLine)
        }
        return makeError(
            code: .commandFailed(exitCode: exitCode),
            exitCode: exitCode,
            output: haystack,
            svnCode: firstToken(in: haystack),
            commandLine: commandLine
        )
    }

    /// Note: free text is not authoritative, but `E…` tokens are stable.
    private static func firstToken(in text: String) -> String? {
        guard let range = text.range(of: #"E\d{6}"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private static func makeError(
        code: SVNErrorCode,
        exitCode: Int32,
        output: String,
        svnCode: String?,
        commandLine: String
    ) -> SVNError {
        SVNError(
            code: code,
            message: userMessage(for: code, output: output, commandLine: commandLine),
            diagnosticOutput: LogRedactor.redact(output),
            svnCode: svnCode,
            exitCode: exitCode
        )
    }

    private static func userMessage(for code: SVNErrorCode, output: String, commandLine: String) -> String {
        switch code {
        case .workingCopyLocked:
            return "工作副本被锁定或上一次操作未完成"
        case .notAWorkingCopy:
            return "目标不是 SVN 工作副本"
        case .workingCopyNeedsUpgrade:
            return "工作副本格式不受支持"
        case .permissionDenied:
            return "工作副本目录或磁盘不可写"
        case .repositoryNeedsUpgrade:
            return "仓库数据格式不受支持"
        case .authenticationRequired:
            return "服务器要求认证"
        case .authorizationFailed:
            return "认证被服务器拒绝"
        case .hostKeyVerificationFailed:
            return "SSH 主机密钥校验失败"
        case .networkFailure:
            return "无法连接仓库服务器"
        case .outOfDate:
            return "工作副本已过期"
        case .conflictRemains:
            return "存在未解决的冲突"
        case .pathNotFound:
            return "路径不存在"
        case .backupFailed:
            return "无法在解决冲突前备份文件，操作已中止"
        case .cancelled:
            return "操作已取消"
        case .timeout:
            return "操作超时"
        case .confirmationRequired:
            return "需要确认后才能执行"
        case .invalidInvocation:
            return "命令参数无效"
        case .xmlParseFailure:
            return "无法解析 svn 输出"
        case .unsupportedVersion:
            return "svn 版本不受支持"
        case .svnNotFound:
            return "找不到 svn 可执行文件"
        case .commandFailed(let exitCode):
            let detail = firstMeaningfulLine(in: output)
            return detail.isEmpty ? "svn 执行失败（退出码 \(exitCode)）" : detail
        case .unknown:
            return "未知错误"
        }
    }

    private static func firstMeaningfulLine(in output: String) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let line = lines.last(where: { $0.lowercased().hasPrefix("svn:") }) ?? lines.last else {
            return ""
        }
        // "svn: E155004: ..." → keep the text after the code for readability.
        if let range = line.range(of: #"^svn:\s*E\d{6}:\s*"#, options: .regularExpression) {
            return String(line[range.upperBound...])
        }
        return line
    }
}
