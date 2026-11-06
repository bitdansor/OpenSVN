import Foundation

/// Builds the `svn checkout` argument array. Pure: no filesystem, no subprocess.
public enum CheckoutArguments {
    /// - Parameter storePristines: svn 1.15 "Pristines on Demand". The default
    ///   `true` keeps svn's default behaviour (store pristine copies), so the
    ///   flag is only emitted when the caller opts out. Passing `false` appends
    ///   `--store-pristine=no`, which makes the working copy fetch pristines
    ///   from the repository on demand instead of keeping local copies.
    ///   Before svn 1.15 the flag does not exist and opting in rewrites the
    ///   working copy to format 32, so the service refuses it there.
    ///
    ///   Note the exact token: real svn spells it **singular**
    ///   `--store-pristine=no`. The plural `--store-pristines=no` is rejected
    ///   with `svn: invalid option`, so it must not be used.
    public static func make(
        url: String,
        destination: URL,
        revision: Int64?,
        depth: String,
        storePristines: Bool
    ) -> [String] {
        var args = ["checkout", url, destination.path, "--depth", depth]
        if let revision { args += ["-r", String(revision)] }
        if !storePristines { args.append("--store-pristine=no") }
        return args
    }
}

/// A repository created locally with `svnadmin create`.
public struct LocalRepository: Sendable, Hashable {
    /// Filesystem path of the new repository.
    public var path: URL
    /// `file://` URL that can be passed to `checkout`, `importDirectory`, etc.
    public var url: String
    /// Redacted stdout, for the task detail and diagnostics.
    public var rawOutput: String

    public init(path: URL, url: String, rawOutput: String = "") {
        self.path = path
        self.url = url
        self.rawOutput = rawOutput
    }
}

/// Builds the `svnadmin create` argument array and the resulting `file://` URL.
///
/// `svnadmin` ships beside `svn` (see `DemoWorkspace.adminTool(nextTo:)`) and is
/// a *different binary* from `svn`: it does not accept the client's global
/// `--non-interactive` / `--no-auth-cache` options, so the service runs it with
/// a dedicated runner rather than through `invoke`.
public enum LocalRepositoryArguments {
    public static func create(path: URL) -> [String] {
        ["create", path.standardizedFileURL.path]
    }

    /// Uses `URL(fileURLWithPath:)` rather than string concatenation so spaces
    /// and non-ASCII characters are percent-encoded correctly.
    public static func fileURL(for path: URL) -> String {
        URL(fileURLWithPath: path.standardizedFileURL.path).absoluteString
    }
}
