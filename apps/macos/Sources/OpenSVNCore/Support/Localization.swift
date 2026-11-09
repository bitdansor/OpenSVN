import Foundation

/// The app's single translation point.
///
/// ## Why the Chinese text is the key
///
/// Entries are addressed by their Chinese source text, not by an invented
/// identifier. Three reasons decided this:
///
/// 1. The app was written in Chinese. There are ~1300 user-visible literals; a
///    symbolic key per literal would be a second vocabulary to maintain, and
///    every call site would read `L.t("changes.toolbar.revert")` — a lookup in a
///    file, then a lookup in Settings, to learn what a button says.
/// 2. A missing translation degrades instead of breaking. `t` returns the Chinese
///    source, so an untranslated string shows Chinese rather than `changes.toolbar.revert`.
/// 3. It is the same contract `NSLocalizedString` has (source text as key), so it
///    is familiar ground for anyone who has localised a Cocoa app.
///
/// The cost is that editing the Chinese source text silently orphans its English
/// entry. `LocalizationCoverageTests` closes that hole: it scans the sources and
/// fails when a literal has no entry.
///
/// ## Why not `.strings` + `Bundle`
///
/// A language switch has to take effect immediately, without relaunching. A
/// `.strings` table is resolved through a bundle whose language is fixed when
/// `Bundle.main` is created, so switching means loading a second `.lproj` bundle
/// by hand and hoping every call site goes through the indirection. This app is
/// also assembled by a shell script rather than Xcode's copy-resources phase, so
/// a resource bundle would have to be taught to the builder as well. A plain
/// dictionary has no bundle, no startup I/O, and can be unit-tested.
///
/// ## Concurrency
///
/// `language` is read from every layer — Core services build status text on
/// their own executors, views read it on the main actor. It is therefore
/// lock-protected rather than actor-isolated.
public enum Localization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: InterfaceLanguage = .chinese

    /// The language the interface is drawn in right now.
    public static var language: InterfaceLanguage {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public static func setLanguage(_ language: InterfaceLanguage) {
        lock.lock()
        current = language
        lock.unlock()
    }

    /// The locale to format dates and numbers with, so a value rendered beside a
    /// translated label is not written in the other language.
    public static var locale: Locale { language.locale }

    /// Applies a preference, resolving `system` against the running system.
    @discardableResult
    public static func apply(
        _ preference: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> InterfaceLanguage {
        let resolved = LanguageResolver.resolve(
            preference: preference,
            preferredLanguages: preferredLanguages
        )
        setLanguage(resolved)
        return resolved
    }

    /// Returns the English text for a Chinese source string, or `nil` when the
    /// catalog has no entry. Exposed for the coverage tests; callers that want
    /// display text use `t`.
    public static func translation(for source: String) -> String? {
        LocalizationCatalog.english[source]
    }

    /// Translates a plain string. Falls back to the Chinese source.
    public static func t(_ source: String) -> String {
        guard language == .english else { return source }
        return LocalizationCatalog.english[source] ?? source
    }

    /// Translates a string that carries `String(format:)` specifiers and
    /// substitutes the arguments.
    ///
    /// Swift interpolation in the UI reads naturally but cannot be a dictionary
    /// key: `"还有 \(n) 项"` is already a `String` by the time a lookup could
    /// happen, and its value changes with `n`. Call sites therefore spell the
    /// template out — `L.f("还有 %d 项", n)` — and the English entry spells the
    /// same specifiers in the order English needs them. A test asserts the
    /// specifier sequence of key and translation agree, which is the failure mode
    /// that would otherwise ship as a crash or a garbled string.
    public static func f(_ source: String, _ arguments: CVarArg...) -> String {
        String(format: translatedTemplate(source), arguments: arguments)
    }

    /// Plural-aware variant of `f` for a single integer count.
    ///
    /// English entries may carry two forms separated by `|`:
    /// `"已解决 %d 个冲突": "Resolved %d conflict|Resolved %d conflicts"`.
    /// Chinese has no such split, so the template is used verbatim there.
    public static func n(_ source: String, _ count: Int) -> String {
        guard language == .english,
              let entry = LocalizationCatalog.english[source] else {
            return String(format: source, count)
        }
        let forms = entry.split(separator: "|", omittingEmptySubsequences: false)
        let chosen: Substring
        switch forms.count {
        case 0: chosen = Substring(entry)
        case 1: chosen = forms[0]
        default: chosen = count == 1 ? forms[0] : forms[1]
        }
        return String(format: String(chosen), count)
    }

    private static func translatedTemplate(_ source: String) -> String {
        guard language == .english else { return source }
        return LocalizationCatalog.english[source] ?? source
    }
}

/// Terse alias for the call sites. `L.t("…")` appears ~1300 times; the extra six
/// characters of `Localization.` add nothing at any of them.
public typealias L = Localization
