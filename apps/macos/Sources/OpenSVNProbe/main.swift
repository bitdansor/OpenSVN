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
       opensvn-probe demo [--path <dir>] [--svn <path>] [--svnadmin <path>]

map-error  Reads svn's stderr from stdin and prints the application error it maps to.
demo       Builds the local "try a three-way merge" sample and prints its paths.
"""

private func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("opensvn-probe: \(reason)\n".utf8))
    exit(1)
}

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

/// The demo command exists so the shell entry point
/// (`scripts/create-conflict-demo.sh`) and the in-app button share one definition
/// of what the sample contains. Two copies of 200 lines of sample files would
/// drift, and the drift would show up as a guide that promises regions the data
/// does not have.
private func runDemo(_ arguments: [String]) async throws {
    let svn = try resolveTool("--svn", in: arguments, name: "svn")
    let svnadmin = try resolveTool("--svnadmin", in: arguments, name: "svnadmin")
    let root = value(after: "--path", in: arguments)
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        ?? DemoWorkspace.defaultRoot

    let workspace = DemoWorkspace(root: root, svn: svn, svnadmin: svnadmin)
    do {
        let result = try await workspace.build()
        print("working_copy=\(result.workingCopy.path)")
        print("repository=\(result.repository.path)")
    } catch let error as SVNError {
        fail(error.message)
    }
}

private func resolveTool(_ flag: String, in arguments: [String], name: String) throws -> URL {
    if let explicit = value(after: flag, in: arguments) {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
    }
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        .map { "\($0)/\(name)" }
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        return URL(fileURLWithPath: found)
    }
    failUsage("找不到 \(name)；用 \(flag) 指定它的路径")
}

switch arguments.first {
case "map-error":
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

case "demo":
    try await runDemo(arguments)

default:
    failUsage("unknown command")
}
