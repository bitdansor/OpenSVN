import Foundation

// Connection settings live in the core, not in `AppSettings`, on purpose.
// `AppSettings` is owned by `AppState` and pushed into already-open sessions;
// certificate trust has to be readable by the process launcher itself, before
// any session exists, and the "connect anyway" decision is consumed once and
// then discarded. A self-contained store with its own `UserDefaults` keys keeps
// that read path independent of the observation graph.
//
// Nothing here touches the network, AppKit, or a real `~/.subversion` by
// default: every filesystem root is injectable so the whole type is unit
// testable with Foundation alone.

// MARK: - Certificate trust

/// One kind of TLS certificate failure svn can report for an HTTPS server.
///
/// The raw values are the exact tokens accepted by
/// `--trust-server-cert-failures`. Keeping them as an enum means an unknown
/// token read back from disk is dropped instead of being handed to svn.
public enum ServerCertificateFailure: String, Codable, Sendable, CaseIterable, Hashable {
    case unknownCA = "unknown-ca"
    case cnMismatch = "cn-mismatch"
    case expired
    case notYetValid = "not-yet-valid"
    case other
}

/// How the app reacts when svn reports an HTTPS server-certificate problem.
///
/// The default (`.strict`) appends no trust flags at all: with
/// `--non-interactive` svn cannot prompt, so it simply fails the operation.
/// Every other case is an explicit widening of that trust, never a default.
///
/// `--trust-server-cert` is deprecated (svn 1.15 documents it as equivalent to
/// `--trust-server-cert-failures=unknown-ca`) and may print a warning to stderr,
/// which this project uses for error classification. It is therefore never
/// emitted; both widened cases name every failure explicitly via
/// `--trust-server-cert-failures`.
public enum CertificateTrustPolicy: Sendable, Equatable {
    /// Validate certificates normally; fail on a bad certificate.
    case strict
    /// Accept only the listed failure kinds via `--trust-server-cert-failures`.
    case specifiedFailures(Set<ServerCertificateFailure>)
    /// Accept all five failure kinds via the full `--trust-server-cert-failures`
    /// list. Highest risk; must be reachable only through an explicit choice.
    case trustAllCertificates
}

/// Settings validation errors surfaced in the UI.
public enum ConnectionSettingsError: Error, Sendable, LocalizedError, Equatable {
    case invalidProxyPort(Int)
    case unsafeValue(String)
    case serversFileUnreadable
    case serversFileUnwritable

    public var errorDescription: String? {
        switch self {
        case .invalidProxyPort(let port):
            return L.f("代理端口无效：%@（应为 1–65535）", String(describing: port))
        case .unsafeValue(let value):
            return L.f("配置值包含不允许的字符：%@", String(describing: value))
        case .serversFileUnreadable:
            return L.t("无法读取 servers 配置文件")
        case .serversFileUnwritable:
            return L.t("无法写入 servers 配置文件")
        }
    }
}

// MARK: - Proxy / servers file

/// The common proxy fields of `~/.subversion/servers`.
///
/// `http-proxy-password` is deliberately absent: writing a cleartext password
/// into a shared, world-readable config file would undo the Keychain guarantee.
public struct ProxySettings: Sendable, Equatable {
    public var host: String
    public var port: Int?
    public var username: String?
    public var exceptions: String?

    public init(
        host: String = "",
        port: Int? = nil,
        username: String? = nil,
        exceptions: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.exceptions = exceptions
    }

    /// Sanitises user input at the boundary.
    ///
    /// The only injection that matters here is a newline: it would create a new
    /// line in the INI-style file (and therefore a new key or section). Control
    /// characters are rejected and the port is range-checked.
    public func validated() throws -> ProxySettings {
        func clean(_ value: String?) throws -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.rangeOfCharacter(from: CharacterSet.controlCharacters) == nil else {
                throw ConnectionSettingsError.unsafeValue(String(trimmed.prefix(40)))
            }
            return trimmed.isEmpty ? nil : trimmed
        }

        let cleanHost = try clean(host) ?? ""
        let cleanUsername = try clean(username)
        let cleanExceptions = try clean(exceptions)
        if let port, !(1...65535).contains(port) {
            throw ConnectionSettingsError.invalidProxyPort(port)
        }
        return ProxySettings(
            host: cleanHost,
            port: port,
            username: cleanUsername,
            exceptions: cleanExceptions
        )
    }
}

/// A read-only view of `~/.subversion/servers`.
public struct ServersConfig: Sendable, Equatable {
    /// Active `key = value` lines found in the `[global]` section.
    public var globalEntries: [String: String]
    /// Active `key = value` lines found in the `[groups]` section (read-only).
    public var groupEntries: [String: String]
    /// The original file text. Used only to preserve unrelated lines when
    /// writing; never displayed and never logged (it can contain a cleartext
    /// `http-proxy-password`).
    public var rawText: String
    public var fileExists: Bool

    public init(
        globalEntries: [String: String] = [:],
        groupEntries: [String: String] = [:],
        rawText: String = "",
        fileExists: Bool = false
    ) {
        self.globalEntries = globalEntries
        self.groupEntries = groupEntries
        self.rawText = rawText
        self.fileExists = fileExists
    }

    /// Keys in `[global]` related to authentication and TLS.
    ///
    /// Subversion's SASL (svnserve / `svn://`) is configured by the system SASL
    /// library and SSH, not by this file — so there is nothing here to write.
    /// These entries are displayed read-only and are never rewritten.
    public static let authenticationKeys: Set<String> = [
        "http-auth-types",
        "ssl-authority-files",
        "ssl-trust-default-ca",
        "ssl-client-cert-file",
        "ssl-client-cert-password",
        "ssl-pkcs11-provider"
    ]

    public var authenticationEntries: [String: String] {
        globalEntries.filter { Self.authenticationKeys.contains($0.key) }
    }

    /// Keys whose cleartext value must never leave the parser.
    /// `writeProxySettings` leaves these lines untouched.
    public static let sensitiveKeys: Set<String> = [
        "http-proxy-password",
        "ssl-client-cert-password"
    ]

    /// Read-only entries for the UI. Secrets are always redacted.
    public var displayEntries: [String: String] {
        var result = authenticationEntries
        for key in Self.sensitiveKeys where globalEntries[key] != nil {
            result[key] = "••••••"
        }
        return result
    }

    /// The four proxy fields reconstructed from the parsed file.
    public var proxy: ProxySettings {
        ProxySettings(
            host: globalEntries["http-proxy-host"] ?? "",
            port: globalEntries["http-proxy-port"].flatMap { Int($0) },
            username: globalEntries["http-proxy-username"],
            exceptions: globalEntries["http-proxy-exceptions"]
        )
    }

    /// Parses INI-style text, collecting active `key = value` lines from the
    /// `[global]` and `[groups]` sections. Commented-out lines are ignored;
    /// secret values are redacted in memory and never written to settings or logs.
    public static func parse(_ text: String, fileExists: Bool) -> ServersConfig {
        var global: [String: String] = [:]
        var groups: [String: String] = [:]
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]"), line.count >= 2 {
                section = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = Self.sensitiveKeys.contains(key) ? "••••••" : rawValue
            switch section {
            case "global": global[key] = value
            case "groups": groups[key] = value
            default: break
            }
        }
        return ServersConfig(
            globalEntries: global,
            groupEntries: groups,
            rawText: text,
            fileExists: fileExists
        )
    }
}

// MARK: - Store

/// Reads/writes connection settings, produces svn global arguments, and edits
/// (with a backup) the proxy fields of `~/.subversion/servers`.
///
/// Deliberately independent of `AppState`: the service launcher can instantiate
/// `SVNConnectionSettingsStore()` and call
/// `resolveSVNTrustArguments(svnVersion:)` without any observation graph or
/// open session.
public final class SVNConnectionSettingsStore: @unchecked Sendable {
    // Dedicated keys. These are intentionally separate from `AppSettings`' keys
    // so that a bad value here can never disturb unrelated preferences.
    public static let trustModeKey = "cn.opensvn.connection.trustMode"
    public static let trustFailuresKey = "cn.opensvn.connection.trustFailures"
    public static let oneShotModeKey = "cn.opensvn.connection.oneShotTrustMode"
    public static let oneShotFailuresKey = "cn.opensvn.connection.oneShotTrustFailures"

    /// `~/.subversion`, overridable for tests.
    public static var defaultSubversionDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".subversion", isDirectory: true)
    }

    private let defaults: UserDefaults
    private let subversionDirectory: URL
    /// Serialises the read-then-delete of the one-shot flag.
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        subversionDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.subversionDirectory = subversionDirectory ?? Self.defaultSubversionDirectory
    }

    public var serversFileURL: URL {
        subversionDirectory.appendingPathComponent("servers")
    }

    // MARK: Persistent certificate policy

    /// The standing policy used when no one-shot request is pending.
    public var persistentPolicy: CertificateTrustPolicy {
        get {
            Self.decode(
                modeKey: Self.trustModeKey,
                failuresKey: Self.trustFailuresKey,
                from: defaults
            )
        }
        set {
            Self.encode(
                newValue,
                modeKey: Self.trustModeKey,
                failuresKey: Self.trustFailuresKey,
                in: defaults
            )
        }
    }

    /// True when a "connect anyway" request is waiting to be consumed.
    public var hasPendingOneShotTrust: Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults.string(forKey: Self.oneShotModeKey) != nil
    }

    /// Arms a one-shot trust widening for the very next svn operation.
    public func armOneShotTrust(_ policy: CertificateTrustPolicy) {
        lock.lock(); defer { lock.unlock() }
        Self.encode(
            policy,
            modeKey: Self.oneShotModeKey,
            failuresKey: Self.oneShotFailuresKey,
            in: defaults
        )
    }

    /// Reads and clears the one-shot request. Returns nil when none is pending.
    public func consumeOneShotTrust() -> CertificateTrustPolicy? {
        lock.lock(); defer { lock.unlock() }
        guard defaults.string(forKey: Self.oneShotModeKey) != nil else { return nil }
        let policy = Self.decode(
            modeKey: Self.oneShotModeKey,
            failuresKey: Self.oneShotFailuresKey,
            from: defaults
        )
        defaults.removeObject(forKey: Self.oneShotModeKey)
        defaults.removeObject(forKey: Self.oneShotFailuresKey)
        return policy
    }

    /// `--trust-server-cert-failures` exists in svn 1.9, but the project's
    /// verified baseline is 1.14.x (`specifications/compatibility.md`). Never
    /// send the flag to an older build: it fails closed to strict validation.
    public static let trustFailuresMinimumVersion = SVNVersion(major: 1, minor: 14, patch: 0)

    /// The entry point for the service launcher. A one-shot request wins over
    /// the standing policy and is consumed exactly once. `svnVersion` comes
    /// from `SVNInstallation.version`; the version gate is mandatory so an
    /// older svn can never silently receive the flag.
    public func resolveSVNTrustArguments(svnVersion: SVNVersion) -> [String] {
        let policy = consumeOneShotTrust() ?? persistentPolicy
        return Self.svnArguments(for: policy, svnVersion: svnVersion)
    }

    /// Pure argument generation. Safe to call with any policy: an empty failure
    /// set degrades to `.strict` rather than emitting a malformed flag.
    ///
    /// The flag is a svn *global* option and only has effect with
    /// `--non-interactive`. svn accepts global options both before and after the
    /// subcommand, but this project uses `--` to protect paths starting with
    /// `-`; callers must place the returned options before the subcommand and
    /// before any `--`. `SVNService.runOnce` prefixes all global options.
    public static func svnArguments(
        for policy: CertificateTrustPolicy,
        svnVersion: SVNVersion
    ) -> [String] {
        guard svnVersion >= trustFailuresMinimumVersion else { return [] }
        switch policy {
        case .strict:
            return []
        case .specifiedFailures(let failures):
            let valid = failures.intersection(Set(ServerCertificateFailure.allCases))
            guard !valid.isEmpty else { return [] }
            return ["--trust-server-cert-failures", csv(for: valid)]
        case .trustAllCertificates:
            return [
                "--trust-server-cert-failures",
                csv(for: Set(ServerCertificateFailure.allCases))
            ]
        }
    }

    // MARK: Persistence encoding

    static func parseFailures(_ csv: String) -> Set<ServerCertificateFailure> {
        var result: Set<ServerCertificateFailure> = []
        for token in csv.split(separator: ",") {
            let value = token.trimmingCharacters(in: .whitespaces).lowercased()
            if let failure = ServerCertificateFailure(rawValue: value) {
                result.insert(failure)
            }
        }
        return result
    }

    static func csv(for failures: Set<ServerCertificateFailure>) -> String {
        ServerCertificateFailure.allCases
            .filter { failures.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private static func encode(
        _ policy: CertificateTrustPolicy,
        modeKey: String,
        failuresKey: String,
        in defaults: UserDefaults
    ) {
        switch policy {
        case .strict:
            defaults.set("strict", forKey: modeKey)
            defaults.removeObject(forKey: failuresKey)
        case .specifiedFailures(let failures):
            let valid = failures.intersection(Set(ServerCertificateFailure.allCases))
            if valid.isEmpty {
                defaults.set("strict", forKey: modeKey)
                defaults.removeObject(forKey: failuresKey)
            } else {
                defaults.set("specified", forKey: modeKey)
                defaults.set(csv(for: valid), forKey: failuresKey)
            }
        case .trustAllCertificates:
            defaults.set("all", forKey: modeKey)
            defaults.removeObject(forKey: failuresKey)
        }
    }

    /// Corrupt or unknown values fail closed to `.strict`.
    private static func decode(
        modeKey: String,
        failuresKey: String,
        from defaults: UserDefaults
    ) -> CertificateTrustPolicy {
        guard let mode = defaults.string(forKey: modeKey) else { return .strict }
        switch mode {
        case "all":
            return .trustAllCertificates
        case "specified":
            let parsed = parseFailures(defaults.string(forKey: failuresKey) ?? "")
            return parsed.isEmpty ? .strict : .specifiedFailures(parsed)
        default:
            return .strict
        }
    }

    // MARK: servers file (read)

    public func readServersConfig() throws -> ServersConfig {
        let url = serversFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ServersConfig()
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return ServersConfig.parse(text, fileExists: true)
    }

    // MARK: servers file (backup + write)

    /// Copies the current `servers` file to a timestamped sibling before any
    /// modification. Returns nil only when the file did not exist (a new file
    /// needs no backup). Throws if the existing file cannot be read.
    @discardableResult
    public func backupServersFile() throws -> URL? {
        let url = serversFileURL
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            throw ConnectionSettingsError.serversFileUnreadable
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(8)
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("servers.opensvn-backup-\(stamp)-\(suffix)")
        do {
            try data.write(to: backup, options: .atomic)
        } catch {
            throw ConnectionSettingsError.serversFileUnwritable
        }
        return backup
    }

    /// Validates, backs up the existing file, then rewrites only the four proxy
    /// keys inside `[global]`, preserving every other line, comment and section.
    /// Returns the backup URL so the UI can tell the user where it went.
    @discardableResult
    public func writeProxySettings(_ proxy: ProxySettings) throws -> URL? {
        let validated = try proxy.validated()
        let url = serversFileURL
        let manager = FileManager.default
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let backup = try backupServersFile()

        do {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let updated = try Self.applying(proxy: validated, to: existing)
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ConnectionSettingsError.serversFileUnwritable
        }
        return backup
    }

    /// Pure text transform: update/add the four proxy keys in `[global]`.
    /// A disabled (empty) value is written as a commented-out line so the key
    /// stays visible for the user instead of silently disappearing.
    static func applying(proxy: ProxySettings, to text: String) throws -> String {
        let validated = try proxy.validated()
        let desired: [(String, String?)] = [
            ("http-proxy-host", validated.host.isEmpty ? nil : validated.host),
            ("http-proxy-port", validated.port.map { String($0) }),
            ("http-proxy-username", validated.username),
            ("http-proxy-exceptions", validated.exceptions)
        ]

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func sectionName(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 else { return nil }
            return String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }
        func rendered(key: String, value: String?) -> String {
            guard let value, !value.isEmpty else { return "# \(key) = " }
            return "\(key) = \(value)"
        }
        func index(ofKey key: String, in range: Range<Int>) -> Int? {
            for index in range where index < lines.count {
                var trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                    trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                guard trimmed.hasPrefix(key) else { continue }
                let rest = trimmed.dropFirst(key.count)
                if rest.isEmpty || rest.first == "=" || rest.first?.isWhitespace == true {
                    return index
                }
            }
            return nil
        }

        var globalStart: Int?
        var globalEnd = lines.count
        for (index, line) in lines.enumerated() {
            guard let name = sectionName(line) else { continue }
            if name == "global" {
                globalStart = index
                globalEnd = lines.count
                for following in (index + 1)..<lines.count where sectionName(lines[following]) != nil {
                    globalEnd = following
                    break
                }
                break
            }
        }

        guard let start = globalStart else {
            let header = ["[global]"] + desired.map { rendered(key: $0.0, value: $0.1) }
            return (header + lines).joined(separator: "\n")
        }

        var insertAt = globalEnd
        if insertAt == lines.count, lines.last?.isEmpty == true { insertAt -= 1 }
        for (key, value) in desired {
            if let existing = index(ofKey: key, in: (start + 1)..<globalEnd) {
                lines[existing] = rendered(key: key, value: value)
            } else {
                lines.insert(rendered(key: key, value: value), at: insertAt)
                insertAt += 1
            }
        }
        return lines.joined(separator: "\n")
    }
}
