import Foundation

/// A parsed `svn --version --quiet` value, e.g. `1.14.5`.
public struct SVNVersion: Sendable, Hashable, Comparable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts both `1.14.5` and the verbose `svn, version 1.14.5 (r1886195)`.
    public init?(_ string: String) {
        guard let range = string.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
            return nil
        }
        let parts = string[range].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.major = parts[0]
        self.minor = parts[1]
        self.patch = parts[2]
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SVNVersion, rhs: SVNVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Where the `svn` binary came from. Shown in Settings and diagnostics, because
/// "which svn is this app actually using" is a recurring support question.
public enum SVNInstallationSource: String, Sendable, Codable, Hashable {
    case explicit
    case bundled
    case searchPath
    case wellKnownLocation

    public var displayName: String {
        switch self {
        case .explicit: return "手动指定"
        case .bundled: return "应用内置"
        case .searchPath: return "PATH 探测"
        case .wellKnownLocation: return "常见安装位置"
        }
    }
}

public struct SVNInstallation: Sendable, Hashable {
    public var executableURL: URL
    public var version: SVNVersion
    public var source: SVNInstallationSource
    public var rawVersionOutput: String

    public init(
        executableURL: URL,
        version: SVNVersion,
        source: SVNInstallationSource,
        rawVersionOutput: String = ""
    ) {
        self.executableURL = executableURL
        self.version = version
        self.source = source
        self.rawVersionOutput = rawVersionOutput
    }
}

/// Resolves which `svn` executable to use.
///
/// Order: explicit setting → bundled runtime → `PATH` →
/// well-known locations → a hard error. Silently falling back to the user's
/// shell environment is explicitly not allowed: a GUI app started from Finder
/// does not inherit Homebrew's `PATH`.
public struct SVNDiscovery: Sendable {
    /// User-configured path from Settings. When set, it is the only candidate.
    public var explicitExecutablePath: String?
    /// Bundled runtime candidates, in priority order (e.g. `OpenSVN.app/Contents/Resources/svn/bin/svn`).
    public var bundledCandidates: [URL]
    public var environment: [String: String]
    public var minimumVersion: SVNVersion
    public var maximumExclusiveVersion: SVNVersion
    public var probeTimeout: TimeInterval

    /// Minimum supported version. 1.10 is required because
    /// `--password-from-stdin` (the only way to pass a password without putting
    /// it in argv) first appeared there. See specifications/compatibility.md.
    public static let defaultMinimumVersion = SVNVersion(major: 1, minor: 10, patch: 0)

    public init(
        explicitExecutablePath: String? = nil,
        bundledCandidates: [URL] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        minimumVersion: SVNVersion = SVNVersion(major: 1, minor: 10, patch: 0),
        maximumExclusiveVersion: SVNVersion = SVNVersion(major: 2, minor: 0, patch: 0),
        probeTimeout: TimeInterval = 15
    ) {
        self.explicitExecutablePath = explicitExecutablePath
        self.bundledCandidates = bundledCandidates
        self.environment = environment
        self.minimumVersion = minimumVersion
        self.maximumExclusiveVersion = maximumExclusiveVersion
        self.probeTimeout = probeTimeout
    }

    public struct Candidate: Sendable, Hashable {
        public var path: String
        public var source: SVNInstallationSource

        public init(path: String, source: SVNInstallationSource) {
            self.path = path
            self.source = source
        }
    }

    /// Deterministic, side-effect-free candidate list. Exposed for tests and for
    /// the "why wasn't my svn found" diagnostic in Settings.
    public func candidates() -> [Candidate] {
        if let explicitExecutablePath, !explicitExecutablePath.isEmpty {
            let expanded = (explicitExecutablePath as NSString).expandingTildeInPath
            return [Candidate(path: expanded, source: .explicit)]
        }

        var seen = Set<String>()
        var result: [Candidate] = []

        func append(_ path: String, _ source: SVNInstallationSource) {
            guard !path.isEmpty else { return }
            let expanded = (path as NSString).expandingTildeInPath
            guard seen.insert(expanded).inserted else { return }
            result.append(Candidate(path: expanded, source: source))
        }

        for url in bundledCandidates {
            append(url.path, .bundled)
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            append("\(directory)/svn", .searchPath)
        }
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            append("\(directory)/svn", .wellKnownLocation)
        }
        return result
    }

    public func resolve() async throws -> SVNInstallation {
        let candidates = candidates()
        var searched: [String] = []
        var bestFailure: SVNError?

        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate.path)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                searched.append(candidate.path)
                continue
            }
            do {
                let installation = try await probe(url: url, source: candidate.source)
                return installation
            } catch let error as SVNError {
                searched.append(candidate.path)
                // An explicit path is a user decision: never fall through.
                if candidate.source == .explicit { throw error }
                if bestFailure == nil { bestFailure = error }
            } catch {
                searched.append(candidate.path)
                if candidate.source == .explicit {
                    throw SVNError(
                        code: .svnNotFound,
                        message: "指定的 svn 无法运行：\(candidate.path)",
                        diagnosticOutput: error.localizedDescription
                    )
                }
            }
        }

        if let bestFailure, case .unsupportedVersion = bestFailure.code {
            throw bestFailure
        }
        throw SVNError(
            code: .svnNotFound,
            message: "未找到可用的 svn 可执行文件",
            diagnosticOutput: searched.isEmpty ? "未检查任何候选路径" : "已检查：\n" + searched.joined(separator: "\n")
        )
    }

    /// Runs `svn --version --quiet` and validates the version range.
    public func probe(url: URL, source: SVNInstallationSource) async throws -> SVNInstallation {
        let runner = SVNProcessRunner(
            executableURL: url,
            environment: environment,
            defaultTimeout: probeTimeout
        )
        let result = try await runner.run(
            SVNInvocation(executableURL: url, arguments: ["--version", "--quiet"])
        )
        guard result.isSuccess else {
            throw SVNErrorMapper.error(from: result)
                ?? SVNError(code: .svnNotFound, message: "svn 探测失败：\(url.path)")
        }
        guard let version = SVNVersion(result.standardOutput) else {
            throw SVNError(
                code: .unsupportedVersion(found: result.standardOutput, minimum: minimumVersion.description),
                message: "无法识别 svn 版本：\(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))",
                diagnosticOutput: result.standardError
            )
        }
        guard version >= minimumVersion, version < maximumExclusiveVersion else {
            throw SVNError(
                code: .unsupportedVersion(found: version.description, minimum: minimumVersion.description),
                message: "svn \(version) 不在支持区间（>= \(minimumVersion), < \(maximumExclusiveVersion)）",
                diagnosticOutput: result.standardOutput
            )
        }
        return SVNInstallation(
            executableURL: url,
            version: version,
            source: source,
            rawVersionOutput: result.standardOutput
        )
    }
}
