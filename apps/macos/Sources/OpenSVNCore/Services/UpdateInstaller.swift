import Foundation

public struct CommandResult: Sendable, Hashable {
    public var status: Int32
    /// stdout and stderr merged. `codesign -d` writes its findings to stderr,
    /// and splitting them here would only make the caller re-join them.
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult
}

/// Runs one executable with an argv array. No shell, for the same reason
/// `SVNProcessRunner` has none: a path with a quote or a space must not be able
/// to become a second command.
public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                // `codesign` output is a few hundred bytes; a pipe is drained by
                // reading to EOF before waiting, so it cannot fill and deadlock.
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    output: String(decoding: data, as: UTF8.self)
                ))
            }
        }
    }
}

public enum UpdateInstallError: Error, LocalizedError, Sendable, Equatable {
    case notAnAppBundle(String)
    case unpackFailed(String)
    case signatureInvalid(String)
    case notDeveloperIDSigned
    case teamIdentifierMismatch(expected: String, found: String)
    case bundleIdentifierMismatch(expected: String, found: String?)
    case versionMismatch(expected: String, found: String?)
    case destinationNotWritable(String)
    case helperLaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAnAppBundle(let path):
            return L.f("更新包里没有找到应用（%@）。", String(describing: path))
        case .unpackFailed(let detail):
            return L.f("无法解开更新包：%@", String(describing: detail))
        case .signatureInvalid(let detail):
            return L.f("更新包的代码签名无效：%@", String(describing: detail))
        case .notDeveloperIDSigned:
            return L.t("当前应用是这个 Developer ID 团队签名的，但更新包没有团队标识，已拒绝安装。")
        case .teamIdentifierMismatch(let expected, let found):
            return L.f("更新包的签名团队是 %@，与当前应用的 %@ 不一致，已拒绝安装。", String(describing: found), String(describing: expected))
        case .bundleIdentifierMismatch(let expected, let found):
            return L.f("更新包的标识是 %@，不是 %@，已拒绝安装。", String(describing: found ?? L.t("（缺失）")), String(describing: expected))
        case .versionMismatch(let expected, let found):
            return L.f("更新包版本是 %@，与发布信息里的 %@ 不一致，已拒绝安装。", String(describing: found ?? L.t("（缺失）")), String(describing: expected))
        case .destinationNotWritable(let path):
            return L.f("没有权限替换 %@。请把它移到可写的位置，或手动下载安装。", String(describing: path))
        case .helperLaunchFailed(let detail):
            return L.f("无法启动安装助手：%@", String(describing: detail))
        }
    }
}

/// Verifies a staged update, then swaps it in after the app exits.
///
/// GitHub is treated as transport, not as authority: anyone who can publish to
/// the release page can replace the bytes. Authenticity comes from one of two
/// anchors — a release manifest signed by a key this build trusts (free, and the
/// default for an open-source project), or a Developer ID signature whose team
/// equals the running app's (needs a certificate that costs money every year).
/// `verify(stagedBundle:version:team:)` takes the team as optional for exactly
/// that reason; `nil` means "identity was established by the signed manifest".
/// Integrity and identity are still both required, and neither check has an
/// override flag.
public struct UpdateInstaller: Sendable {
    public static let bundleIdentifier = "cn.opensvn.app"

    public var runner: any CommandRunning
    public var bundleIdentifier: String

    public init(
        runner: any CommandRunning = SystemCommandRunner(),
        bundleIdentifier: String = UpdateInstaller.bundleIdentifier
    ) {
        self.runner = runner
        self.bundleIdentifier = bundleIdentifier
    }

    // MARK: - Identity

    /// The signing team of a bundle, or `nil` when it is ad-hoc or unsigned.
    ///
    /// `nil` is not an error here: the caller needs to distinguish "this build
    /// cannot prove anyone's identity" from "the download is wrong". The first
    /// is a normal state for a development build.
    public func teamIdentifier(of bundle: URL) async throws -> String? {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "--verbose=4", bundle.path]
        )
        for line in result.output.split(separator: "\n") {
            guard let range = line.range(of: "TeamIdentifier=") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != "not set" else { return nil }
            return value
        }
        return nil
    }

    /// Signature valid, and the staged bundle is the version the release
    /// announced.
    ///
    /// `team` is the *expected* Developer ID team, which is `nil` when the
    /// running build is ad-hoc. In that case identity was established by the
    /// signed release manifest instead, and there is no team to compare against
    /// — requiring one would refuse every update of an unsigned build, which is
    /// the build most users of a free project will have.
    public func verify(stagedBundle: URL, version: AppVersion, team: String?) async throws {
        guard stagedBundle.pathExtension == "app" else {
            throw UpdateInstallError.notAnAppBundle(stagedBundle.path)
        }

        let check = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", stagedBundle.path]
        )
        guard check.status == 0 else {
            throw UpdateInstallError.signatureInvalid(check.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let team {
            guard let foundTeam = try await teamIdentifier(of: stagedBundle) else {
                throw UpdateInstallError.notDeveloperIDSigned
            }
            guard foundTeam == team else {
                throw UpdateInstallError.teamIdentifierMismatch(expected: team, found: foundTeam)
            }
        }

        let info = Bundle(url: stagedBundle)?.infoDictionary
        let identifier = info?["CFBundleIdentifier"] as? String
        guard identifier == bundleIdentifier else {
            throw UpdateInstallError.bundleIdentifierMismatch(expected: bundleIdentifier, found: identifier)
        }
        let rawVersion = info?["CFBundleShortVersionString"] as? String
        guard let found = rawVersion.flatMap(AppVersion.init), found == version else {
            throw UpdateInstallError.versionMismatch(expected: version.description, found: rawVersion)
        }
    }

    // MARK: - Unpack

    /// Expands the archive into `directory` and returns the single `.app` it
    /// contains.
    ///
    /// Exactly one: an archive holding two bundles has no defensible answer to
    /// "which one is the app", and picking the first would be a guess.
    public func unpack(archive: URL, into directory: URL) async throws -> URL {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: directory.path) {
                try manager.removeItem(at: directory)
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw UpdateInstallError.unpackFailed(error.localizedDescription)
        }

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-xk", archive.path, directory.path]
        )
        guard result.status == 0 else {
            throw UpdateInstallError.unpackFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let contents: [URL]
        do {
            contents = try manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw UpdateInstallError.unpackFailed(error.localizedDescription)
        }
        let bundles = contents.filter { $0.pathExtension == "app" }
        guard bundles.count == 1, let bundle = bundles.first else {
            throw UpdateInstallError.notAnAppBundle(directory.path)
        }
        return bundle
    }

    // MARK: - Install

    /// Writes the helper that does the swap, launches it, and returns its path.
    ///
    /// The app cannot replace its own bundle while it is running, so the work is
    /// handed to a shell script that waits for this process to exit. The caller
    /// terminates the app immediately after this returns.
    public func install(
        stagedBundle: URL,
        destination: URL,
        helper: URL,
        relaunch: Bool
    ) throws -> URL {
        try writeHelper(
            stagedBundle: stagedBundle,
            destination: destination,
            helper: helper,
            relaunch: relaunch
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateInstallError.helperLaunchFailed(error.localizedDescription)
        }
        return helper
    }

    /// Writes (but does not run) the swap script. Split from `install` so the
    /// generated text can be asserted without spawning anything that would try
    /// to replace a bundle.
    @discardableResult
    public func writeHelper(
        stagedBundle: URL,
        destination: URL,
        helper: URL,
        relaunch: Bool
    ) throws -> String {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard manager.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError.destinationNotWritable(parent.path)
        }

        let script = Self.helperScript(
            pid: ProcessInfo.processInfo.processIdentifier,
            source: stagedBundle,
            destination: destination,
            backup: destination.appendingPathExtension("previous"),
            relaunch: relaunch
        )
        do {
            try manager.createDirectory(
                at: helper.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        } catch {
            throw UpdateInstallError.helperLaunchFailed(error.localizedDescription)
        }
        return script
    }

    /// The swap, as text, so it can be asserted without replacing anything.
    ///
    /// Order matters: the staged copy is expanded to `<dest>.new` first, the old
    /// bundle is moved aside rather than deleted, and a failed final move puts
    /// the old one back. `xattr -dr com.apple.quarantine` runs before the
    /// relaunch: a helper script does not inherit LaunchServices' download
    /// provenance, but the archive may have been fetched by something that did.
    public static func helperScript(
        pid: Int32,
        source: URL,
        destination: URL,
        backup: URL,
        relaunch: Bool
    ) -> String {
        let lines = [
            "#!/bin/sh",
            "# Written by OpenSVN immediately before it quits. Not a general-purpose script.",
            "set -u",
            "pid=\(pid)",
            "src=\(quote(source.path))",
            "dst=\(quote(destination.path))",
            "backup=\(quote(backup.path))",
            "relaunch=\(relaunch ? 1 : 0)",
            "",
            "# The backup path is built by the installer and must stay a sibling;",
            "# refusing anything else keeps a bad argument from becoming an `rm -rf`.",
            "case \"$backup\" in",
            "  *.previous) : ;;",
            "  *) exit 5 ;;",
            "esac",
            "",
            "# Wait for this process to exit: 900 × 0.2s = three minutes.",
            "i=0",
            "while kill -0 \"$pid\" 2>/dev/null; do",
            "  i=$((i+1))",
            "  if [ \"$i\" -gt 900 ]; then exit 1; fi",
            "  /bin/sleep 0.2",
            "done",
            "",
            "/bin/rm -rf \"$dst.new\"",
            "/usr/bin/ditto \"$src\" \"$dst.new\" || exit 2",
            "/bin/rm -rf \"$backup\"",
            "if [ -e \"$dst\" ]; then",
            "  /bin/mv \"$dst\" \"$backup\" || { /bin/rm -rf \"$dst.new\"; exit 3; }",
            "fi",
            "if ! /bin/mv \"$dst.new\" \"$dst\"; then",
            "  if [ -e \"$backup\" ]; then /bin/mv \"$backup\" \"$dst\"; fi",
            "  exit 4",
            "fi",
            "/usr/bin/xattr -dr com.apple.quarantine \"$dst\" >/dev/null 2>&1",
            "if [ \"$relaunch\" -eq 1 ]; then /usr/bin/open \"$dst\"; fi",
            "/bin/rm -rf \"$backup\"",
            "exit 0"
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Single-quoted for the shell, with embedded quotes handled the only way
    /// POSIX allows: close, escape, reopen.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Locations

    /// `~/Library/Application Support/OpenSVN/Updates`
    public static func updatesDirectory(
        supportDirectory: URL? = nil
    ) -> URL {
        let base = supportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("OpenSVN/Updates", isDirectory: true)
    }

    public static func stagingDirectory(for version: AppVersion, in updates: URL) -> URL {
        updates.appendingPathComponent(version.description, isDirectory: true)
    }
}
