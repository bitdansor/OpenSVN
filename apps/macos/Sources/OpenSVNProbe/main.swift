import Foundation
import OpenSVNCore

/// Classifies a raw `svn` failure the way the app would.
///
/// The S5-5 scenarios under `tests/scenarios/failure/` drive real svn processes
/// and assert on observable state. The *classification* of a failure, however,
/// lives in Swift (`SVNErrorMapper`). This command is the bridge, so a shell
/// scenario can close the loop honestly — real fault, real stderr, real mapping:
///
///     opensvn-probe map-error --exit 1 < stderr.txt
///
/// Output is one `key=value` line per field, because the caller is a shell
/// script and should not need a JSON parser:
///
///     code=SVN-0006
///     severity=needsUserAction
///     svn=E200031
///     message=...
///     remediation=...
///
/// Exit status is 0 whenever the mapping itself succeeded — a non-zero exit
/// here means the probe was misused, not that svn failed.

private let usage = """
usage: opensvn-probe map-error --exit <code> [--stdout <file>] < stderr

Reads svn's stderr from stdin and prints the application error it maps to.
"""

private func failUsage(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("opensvn-probe: \(reason)\n\(usage)\n".utf8))
    exit(2)
}

private func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private func readStdin() -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

private func emit(_ key: String, _ value: String) {
    // A newline inside a value would break the one-line-per-field contract the
    // shell assertions rely on.
    let flattened = value
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    print("\(key)=\(flattened)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "map-error" else { failUsage("unknown command") }

let exitCode = Int32(value(after: "--exit", in: arguments) ?? "1")
    ?? { failUsage("--exit expects an integer") }()

let standardError = readStdin()
let standardOutput: String = value(after: "--stdout", in: arguments)
    .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""

let error = SVNErrorMapper.error(
    exitCode: exitCode,
    standardError: standardError,
    standardOutput: standardOutput
)

emit("code", error.code.identifier)
emit("severity", error.code.severity.rawValue)
emit("svn", error.svnCode ?? "")
emit("message", error.message)
emit("remediation", error.code.remediation ?? "")
