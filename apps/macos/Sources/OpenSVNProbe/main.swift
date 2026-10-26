import Foundation
import OpenSVNCore

/// Classifies a raw `svn` failure the way the app would.
///
/// The classification of a failure lives in Swift (`SVNErrorMapper`), which a
/// shell script cannot reach. This command is the bridge: feed it a real stderr
/// capture and it prints the identifier the app would show, so a fault can be
/// checked end to end without a GUI.
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
       opensvn-probe discover --app <OpenSVN.app> [--path <PATH>]

map-error  Reads svn's stderr from stdin and prints the application error it maps to.
demo       Builds the local "try a three-way merge" sample and prints its paths.
discover   Resolves svn the way the app does at launch, for a given .app and PATH.
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

/// Resolves `svn` the way the app does at launch.
///
/// S6-6 asks whether the bundle works on a machine with no Subversion installed.
/// A GUI cannot be asked that question non-interactively, but the *decision* the
/// app makes at launch can be: given an empty PATH, which candidate wins? This
/// command answers it with the production discovery code and the production
/// candidate list, so the claim "the app does not need a host svn" is checked
/// rather than asserted.
///
///     opensvn-probe discover --app build/OpenSVN.app --path /nonexistent
///     source=bundled
///     path=/.../OpenSVN.app/Contents/Resources/svn/bin/svn
///     version=1.14.5
private func runDiscover(_ arguments: [String]) async throws {
    guard let appPath = value(after: "--app", in: arguments) else {
        failUsage("discover requires --app <OpenSVN.app>")
    }
    let appURL = URL(fileURLWithPath: (appPath as NSString).expandingTildeInPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: appURL.path) else {
        fail("no app bundle at \(appURL.path)")
    }

    // An explicitly empty PATH is the interesting case: the app must not depend
    // on finding svn in the environment, because a Finder launch never has
    // Homebrew on PATH.
    let searchPath = value(after: "--path", in: arguments) ?? "/usr/bin:/bin"

    let discovery = SVNDiscovery(
        bundledCandidates: SVNServiceFactory.bundledCandidateURLs(appBundleURL: appURL),
        environment: ["PATH": searchPath],
        probeTimeout: 30
    )

    do {
        let installation = try await discovery.resolve()
        emit("source", installation.source.rawValue)
        emit("path", installation.executableURL.path)
        emit("version", installation.version.description)
        emit("searched", discovery.candidates().map(\.path).joined(separator: ":"))
    } catch let error as SVNError {
        emit("source", "none")
        emit("error", error.message)
        emit("searched", error.diagnosticOutput ?? "")
        exit(1)
    }
}

private func resolveTool(_ flag: String, in arguments: [String], name: String) throws -> URL {    if let explicit = value(after: flag, in: arguments) {
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

case "discover":
    try await runDiscover(arguments)

default:
    failUsage("unknown command")
}
