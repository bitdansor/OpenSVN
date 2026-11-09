import Foundation
import Testing
@testable import OpenSVNCore

/// Guards the property the rest of the localisation cannot state for itself:
/// **every** Chinese string a user can see is resolved through the catalog.
///
/// A translation layer is easy to get 95% right and impossible to trust at 95%:
/// the missing strings are precisely the ones nobody looks at — an alert, an
/// empty state, a diagnostic in a corner. So instead of trusting review, this
/// suite reads the sources and fails when it finds Chinese text that is not
/// wrapped in `L.t` / `L.f` / `L.n`, or is wrapped in a key the catalog does not
/// define.
///
/// The two ways a literal can be legitimate without being translated are both
/// explicit below, never implicit:
///
/// 1. `Exemptions.displayText` — text that reaches the screen but must stay in
///    one language regardless of the setting (a language name in a picker).
/// 2. `Exemptions.dataOnly` — text that never reaches the screen: log lines,
///    demo-fixture content, on-disk names, svn's own vocabulary.
@Suite("Localization coverage")
struct LocalizationCoverageTests {
    @Test("every Chinese literal in the sources goes through the catalog")
    func noUnhandledLiterals() throws {
        var problems: [String] = []

        for file in try Self.swiftSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            for literal in SourceScanner.literals(in: source) {
                guard literal.text.contains(where: Self.isChinese) else { continue }

                if let call = literal.enclosingCall {
                    switch call {
                    case .translate, .format, .plural:
                        // Wrapped: the key itself still has to exist, or the
                        // lookup silently falls back to Chinese at runtime.
                        if LocalizationCatalog.english[literal.text] == nil {
                            problems.append(
                                "\(name):\(literal.line) — \(call.rawValue) key missing from the catalog: \(literal.text)"
                            )
                        }
                        if case .plural = call, !literal.text.contains("%d") {
                            problems.append(
                                "\(name):\(literal.line) — L.n key must use %d (the count is an Int): \(literal.text)"
                            )
                        }
                    case .diagnostic:
                        // A log line: written to a file, never laid out on screen.
                        break
                    }
                    continue
                }

                if Exemptions.displayText.contains(literal.text) { continue }
                if Exemptions.dataOnly[name]?.contains(literal.text) == true { continue }

                problems.append(
                    "\(name):\(literal.line) — not localized: \(literal.text)"
                )
            }
        }

        #expect(problems.isEmpty, "\(problems.count) literal(s) bypass the catalog:\n\(problems.joined(separator: "\n"))")
    }

    @Test("the catalog has no entries the sources no longer use")
    func noOrphanEntries() throws {
        // An entry nothing references is either a typo in the key or a leftover
        // from text that changed — both make the catalog lie about its coverage.
        var used = Set<String>()
        for file in try Self.swiftSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in SourceScanner.literals(in: source) {
                guard let call = literal.enclosingCall, call.isCatalog else { continue }
                used.insert(literal.text)
            }
        }
        let orphans = Set(LocalizationCatalog.english.keys).subtracting(used)
        #expect(orphans.isEmpty, "unused entries: \(orphans.sorted())")
    }

    // MARK: - Helpers

    /// `apps/macos/Sources`, derived from this file's location so the test does
    /// not depend on the working directory SwiftPM happens to use.
    private static func swiftSources() throws -> [URL] {
        let package = URL(filePath: #filePath)
            .deletingLastPathComponent()  // OpenSVNCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
        let sources = package.appending(path: "Sources")
        var files: [URL] = []
        for root in ["OpenSVN", "OpenSVNCore"] {
            let base = sources.appending(path: root)
            let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                // The catalog is a table of keys, not a set of call sites.
                if url.path.contains("/Support/Strings/") { continue }
                files.append(url)
            }
        }
        #expect(!files.isEmpty, "source scan found no files — the test is looking in the wrong place")
        return files.sorted { $0.path < $1.path }
    }

    private static func isChinese(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
    }
}

// MARK: - Exemptions

enum Exemptions {
    /// Shown on screen, deliberately in one language.
    ///
    /// A language picker names each language in that language — `简体中文` reads
    /// the same whether the rest of the window is English or Chinese, and
    /// translating it to "Simplified Chinese" would be worse for the very user
    /// who needs it.
    static let displayText: Set<String> = [
        "简体中文"
    ]

    /// Never reaches the screen, keyed by the file it appears in.
    ///
    /// `DemoWorkspace` builds a repository whose folder names, commit messages
    /// and property values are sample **data**. Translating them would make the
    /// demo differ per language and would put a "translation" into the commit
    /// history the user is meant to read as real history. `DemoWorkspaceSheet`
    /// then lists a couple of those names, which are on-disk paths: they have to
    /// match what the demo actually wrote.
    ///
    /// Scoped per file rather than kept in one global set on purpose. `工作副本`
    /// is also a UI label, so a global set would quietly excuse an unwrapped
    /// copy of it in a view — which is the exact bug this suite exists to catch.
    static let dataOnly: [String: Set<String>] = [
        "DemoWorkspace.swift": [
            "OpenSVN 合并演示",
            "工作副本",
            "初始导入：合并演示",
            "服务器：修改 subtract、multiply、config 与日志级别",
            "服务器：属性评审人设为服务器团队",
            "本地团队",
            "服务器团队",
            "docs/发布说明.md",
            "docs/属性冲突.txt",
            "trunk/docs/发布说明.md",
            "trunk/docs/属性冲突.txt",
        ],
        "DemoWorkspaceSheet.swift": [
            "docs/发布说明.md",
            "docs/属性冲突.txt",
        ],
    ]
}

// MARK: - Scanning

/// Just enough Swift lexing to find string literals, and to say which call each
/// one is an argument of.
///
/// A regex is not sufficient: interpolations nest real string literals
/// (`"a \(x ?? "b") c"`), and a regex that ignores that reports fragments of the
/// outer string as if they were literals of their own.
enum SourceScanner {
    enum Call: String {
        case translate = "L.t"
        case format = "L.f"
        case plural = "L.n"
        /// `AppLog.shared.record(…)`: a diagnostic written to a log file, never
        /// laid out on screen, so it is out of the translation contract.
        case diagnostic = "AppLog.shared.record"

        var isCatalog: Bool { self != .diagnostic }
    }

    struct Literal {
        /// The literal's **runtime value**, with escapes resolved and
        /// interpolations replaced by `%@` — exactly what the catalog uses as a
        /// key.
        ///
        /// Resolving escapes is not cosmetic. The catalog is a Swift dictionary,
        /// so its keys hold a real newline where the source wrote `\n`. Comparing
        /// raw source text against those keys would report every multi-line
        /// template as an orphan while the app translates it perfectly.
        let text: String
        let line: Int
        let enclosingCall: Call?
    }

    static func literals(in source: String) -> [Literal] {
        let characters = Array(source)
        var results: [Literal] = []
        var index = 0
        var line = 1

        func advance(to target: Int) {
            if target > index {
                line += characters[index..<target].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                index = target
            }
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\n" { line += 1; index += 1; continue }

            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                var cursor = index + 2
                while cursor + 1 < characters.count,
                      !(characters[cursor] == "*" && characters[cursor + 1] == "/") {
                    cursor += 1
                }
                advance(to: min(cursor + 2, characters.count))
                continue
            }
            // Multi-line literals are fixture content (the demo repository's
            // files); they are never UI text, so they are stepped over whole.
            if character == "\"", index + 2 < characters.count,
               characters[index + 1] == "\"", characters[index + 2] == "\"" {
                var cursor = index + 3
                while cursor + 2 < characters.count,
                      !(characters[cursor] == "\"" && characters[cursor + 1] == "\""
                        && characters[cursor + 2] == "\"") {
                    cursor += 1
                }
                advance(to: min(cursor + 3, characters.count))
                continue
            }
            if character == "\"" {
                let startLine = line
                let startIndex = index
                var pieces: [String] = []
                var buffer = ""
                index += 1
                while index < characters.count {
                    let current = characters[index]
                    if current == "\\", index + 1 < characters.count {
                        if characters[index + 1] == "(" {
                            var depth = 1
                            index += 2
                            while index < characters.count, depth > 0 {
                                if characters[index] == "\"" {
                                    index += 1
                                    while index < characters.count {
                                        if characters[index] == "\\" { index += 2; continue }
                                        if characters[index] == "\"" { index += 1; break }
                                        index += 1
                                    }
                                    continue
                                }
                                if characters[index] == "(" { depth += 1 }
                                if characters[index] == ")" { depth -= 1 }
                                index += 1
                            }
                            pieces.append(buffer)
                            buffer = ""
                            continue
                        }
                        buffer.append(current)
                        buffer.append(characters[index + 1])
                        index += 2
                        continue
                    }
                    if current == "\"" { index += 1; break }
                    if current == "\n" { break }
                    buffer.append(current)
                    index += 1
                }
                pieces.append(buffer)
                results.append(
                    Literal(
                        text: pieces.map(unescape).joined(separator: "%@"),
                        line: startLine,
                        enclosingCall: call(before: startIndex, in: characters)
                    )
                )
                continue
            }
            index += 1
        }
        return results
    }

    /// Turns the source spelling of a literal into the value it evaluates to.
    ///
    /// Only the escapes that can appear in UI text are handled; anything else is
    /// passed through, which keeps an unknown escape visible instead of silently
    /// swallowing it.
    static func unescape(_ raw: String) -> String {
        let characters = Array(raw)
        var result = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\", index + 1 < characters.count else {
                result.append(characters[index])
                index += 1
                continue
            }
            switch characters[index + 1] {
            case "n": result.append("\n"); index += 2
            case "t": result.append("\t"); index += 2
            case "r": result.append("\r"); index += 2
            case "0": result.append("\0"); index += 2
            case "\\": result.append("\\"); index += 2
            case "\"": result.append("\""); index += 2
            case "'": result.append("'"); index += 2
            case "u" where index + 2 < characters.count && characters[index + 2] == "{":
                var cursor = index + 3
                var hex = ""
                while cursor < characters.count, characters[cursor] != "}" {
                    hex.append(characters[cursor])
                    cursor += 1
                }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    result.append(Character(scalar))
                }
                index = min(cursor + 1, characters.count)
            default:
                result.append(characters[index + 1])
                index += 2
            }
        }
        return result
    }

    /// Names the call a literal is an argument of, by walking back to the
    /// innermost unclosed `(`.
    ///
    /// Looking only one character back is not enough: `record(.warning, "…")`
    /// and any call whose first argument is not the string both put something
    /// between the `(` and the literal. The walk stops at a statement boundary —
    /// a brace, a semicolon, or a newline that does not follow a continuation —
    /// so it can never wander into the previous statement and borrow its call
    /// name.
    ///
    /// One limit is accepted: a literal nested inside an interpolation
    /// (`"a \(f("中文")) c"`) is stepped over whole and never examined. Every
    /// other shape in this codebase is covered.
    private static func call(before start: Int, in characters: [Character]) -> Call? {
        var cursor = start - 1
        var depth = 0
        while cursor >= 0 {
            switch characters[cursor] {
            case ")":
                depth += 1
            case "(":
                if depth == 0 { return call(namedEndingAt: cursor, in: characters) }
                depth -= 1
            case "{", "}", ";":
                if depth == 0 { return nil }
            case "\n":
                if depth == 0 {
                    // A continuation line ends with `,` or `(`; anything else
                    // means the literal belongs to the statement that just ended.
                    var probe = cursor - 1
                    while probe >= 0, characters[probe] == " " || characters[probe] == "\t" {
                        probe -= 1
                    }
                    if probe >= 0, characters[probe] != ",", characters[probe] != "(" { return nil }
                }
            default:
                break
            }
            cursor -= 1
        }
        return nil
    }

    /// Reads the dotted callee immediately before an opening parenthesis.
    private static func call(namedEndingAt paren: Int, in characters: [Character]) -> Call? {
        var cursor = paren - 1
        while cursor >= 0, characters[cursor] == " " || characters[cursor] == "\t" { cursor -= 1 }
        var name = ""
        while cursor >= 0 {
            let character = characters[cursor]
            guard character.isLetter || character.isNumber || character == "_"
                || character == "." || character == "$" else { break }
            name = String(character) + name
            cursor -= 1
        }
        switch name {
        case "L.t": return .translate
        case "L.f": return .format
        case "L.n": return .plural
        case "record", "AppLog.shared.record": return .diagnostic
        default: return nil
        }
    }
}
