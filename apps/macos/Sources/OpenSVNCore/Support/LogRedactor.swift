import Foundation

/// Central place where anything leaving the process boundary (logs, diagnostics,
/// error dialogs, crash reports) is scrubbed of credentials.
///
/// Red line R2: no password may appear in argv, logs, or persisted settings.
public enum LogRedactor {
    private static let patterns: [(String, String)] = [
        // scheme://user:password@host  → scheme://***@host
        (#"(?i)\b([a-z][a-z0-9+.\-]*://)([^/\s:@]+)(:[^/\s@]*)?@"#, "$1***@"),
        // --password secret / --password=secret
        (#"(?i)(--password[=\s]+)(\"[^\"]*\"|'[^']*'|\S+)"#, "$1***"),
        // password=secret in URLs / query strings / config dumps
        (#"(?i)\b(password|passwd|passphrase|token|secret|api[_-]?key)=([^\s&;,\"']+)"#, "$1=***"),
        // Authorization headers
        (#"(?i)(authorization:\s*(basic|bearer|digest)\s+)\S+"#, "$1***")
    ]

    private static let compiled: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0.0, options: [])
    }

    /// Scrubs credentials embedded in URLs, argument strings, and headers.
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (index, regex) in compiled.enumerated() {
            let template = patterns[index].1
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    /// Additionally replaces every occurrence of the supplied secrets. Used when
    /// we know the exact password and want a guarantee beyond pattern matching.
    public static func redact(_ text: String, secrets: [String]) -> String {
        var result = redact(text)
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "***")
        }
        return result
    }

    /// Host (and port) of a repository URL, safe to show and log.
    public static func sanitizedURL(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.user = nil
        components.password = nil
        return components.string ?? url
    }
}
