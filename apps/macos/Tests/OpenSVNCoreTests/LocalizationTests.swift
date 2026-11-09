import Foundation
import Testing
@testable import OpenSVNCore

// MARK: - Resolving the preference

@Suite("Interface language")
struct LanguageResolverTests {
    @Test("system preference follows a Chinese Mac")
    func systemPrefersChinese() {
        for tag in ["zh-Hans", "zh-Hans-CN", "zh-Hant-TW", "zh", "zh_CN", "ZH-hans"] {
            #expect(
                LanguageResolver.resolve(preference: .system, preferredLanguages: [tag]) == .chinese,
                "expected \(tag) to select Chinese"
            )
        }
    }

    @Test("system preference follows an English Mac")
    func systemPrefersEnglish() {
        for tag in ["en", "en-US", "en-GB", "de-DE", "ja-JP", "fr"] {
            #expect(
                LanguageResolver.resolve(preference: .system, preferredLanguages: [tag]) == .english,
                "expected \(tag) to select English"
            )
        }
    }

    @Test("an empty or malformed list falls back to English")
    func emptyListFallsBack() {
        #expect(LanguageResolver.resolve(preference: .system, preferredLanguages: []) == .english)
        #expect(LanguageResolver.resolve(preference: .system, preferredLanguages: [""]) == .english)
        #expect(LanguageResolver.language(forPreferredTag: nil) == .english)
    }

    @Test("a prefix that merely starts with zh is not Chinese")
    func noPrefixMatching() {
        // "zho" is the ISO 639-2 code for Chinese but not a BCP-47 language
        // subtag this app claims to understand; treating it as Chinese would
        // make the rule "starts with zh", which is a different rule.
        #expect(LanguageResolver.language(forPreferredTag: "zho") == .english)
        #expect(LanguageResolver.language(forPreferredTag: "zhx-Latn") == .english)
    }

    @Test("an explicit choice overrides the system")
    func explicitWins() {
        #expect(
            LanguageResolver.resolve(preference: .english, preferredLanguages: ["zh-Hans-CN"]) == .english
        )
        #expect(
            LanguageResolver.resolve(preference: .chinese, preferredLanguages: ["en-US"]) == .chinese
        )
    }

    @Test("the second preferred language does not win")
    func onlyFirstTagCounts() {
        #expect(
            LanguageResolver.resolve(preference: .system, preferredLanguages: ["en-US", "zh-Hans"]) == .english
        )
    }
}

// MARK: - The lookup itself

@Suite("Localization lookup", .serialized)
struct LocalizationLookupTests {
    /// Every test that flips the global language restores it; the process-wide
    /// state is only safe because the suite never runs these bodies in parallel.
    private func withLanguage(_ language: InterfaceLanguage, _ body: () -> Void) {
        let previous = Localization.language
        Localization.setLanguage(language)
        defer { Localization.setLanguage(previous) }
        body()
    }

    @Test("Chinese returns the source text unchanged")
    func chineseIsIdentity() {
        withLanguage(.chinese) {
            #expect(L.t("添加工作副本") == "添加工作副本")
            #expect(L.t("this key does not exist") == "this key does not exist")
        }
    }

    @Test("English returns the catalog entry")
    func englishTranslates() {
        withLanguage(.english) {
            #expect(L.t("添加工作副本") == "Add Working Copy")
            #expect(L.t("工作副本") == "Working copies")
        }
    }

    @Test("a missing entry degrades to Chinese instead of breaking")
    func missingEntryFallsBack() {
        withLanguage(.english) {
            #expect(L.t("这个词条不存在") == "这个词条不存在")
        }
    }

    @Test("format arguments are substituted in order")
    func formatSubstitution() {
        withLanguage(.english) {
            #expect(L.f("操作超时（%@ 秒）", "5") == "Operation timed out (5 s)")
            #expect(
                L.f("锁由 %@ 持有", "alex") == "Locked by alex"
            )
        }
    }

    @Test("plurals pick the right English form")
    func pluralForms() {
        withLanguage(.english) {
            #expect(L.n("已解决 %d 个冲突", 1) == "Resolved 1 conflict")
            #expect(L.n("已解决 %d 个冲突", 0) == "Resolved 0 conflicts")
            #expect(L.n("已解决 %d 个冲突", 4) == "Resolved 4 conflicts")
        }
    }

    @Test("plurals keep the Chinese template as one form")
    func pluralInChinese() {
        withLanguage(.chinese) {
            #expect(L.n("已解决 %d 个冲突", 1) == "已解决 1 个冲突")
            #expect(L.n("已解决 %d 个冲突", 3) == "已解决 3 个冲突")
        }
    }

    @Test("an entry with one form needs no separator")
    func singleFormPlural() {
        withLanguage(.english) {
            // "%d more" has no noun to inflect, so the English entry carries a
            // single form. `n` must use it rather than print the separator.
            #expect(L.n("… 其余 %d 个", 5) == "… 5 more")
            #expect(L.n("… 其余 %d 个", 1) == "… 1 more")
        }
    }

    @Test("a count is always substituted as an integer")
    func pluralSubstitutesInteger() {
        // `n` passes the count as an `Int`, so an entry written with `%@` would
        // read the integer as an object pointer and crash. Every key reached
        // through `n` therefore has to use `%d`; the coverage test enforces it at
        // the call sites, and this pins the behaviour.
        withLanguage(.english) {
            #expect(L.n("第 %d 次尝试", 2) == "Attempt 2")
        }
    }

    @Test("applying a preference updates the active language")
    func applyPreference() {
        let previous = Localization.language
        defer { Localization.setLanguage(previous) }
        #expect(Localization.apply(.system, preferredLanguages: ["zh-Hant"]) == .chinese)
        #expect(Localization.language == .chinese)
        #expect(Localization.apply(.english, preferredLanguages: ["zh-Hant"]) == .english)
        #expect(Localization.language == .english)
    }

    @Test("the launch path resolves the system list before any view reads a string")
    func launchPathResolvesBeforeFirstLookup() {
        // What `AppState.init` does, in the order it does it: apply the stored
        // preference against the system list, then build views that call `t`.
        // A resolution that happened after the first lookup would paint one
        // frame — or one whole window — in the wrong language.
        let previous = Localization.language
        defer { Localization.setLanguage(previous) }

        #expect(Localization.apply(.system, preferredLanguages: ["en-US", "zh-Hans-CN"]) == .english)
        #expect(L.t("更新") == "Update")

        #expect(Localization.apply(.system, preferredLanguages: ["zh-Hans-CN", "en-US"]) == .chinese)
        #expect(L.t("更新") == "更新")
    }

    @Test("dates are read in the interface language, not the system's")
    func dateFormattingFollowsInterface() {
        // A date written in the system's language beside a translated label is
        // the seam a reader notices first: "3 分钟前" inside an English window.
        let date = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14
        let english = date.formatted(.dateTime.month(.wide).locale(InterfaceLanguage.english.locale))
        let chinese = date.formatted(.dateTime.month(.wide).locale(InterfaceLanguage.chinese.locale))
        #expect(english == "November")
        #expect(chinese == "十一月")
    }
}

// MARK: - Catalog integrity

@Suite("Localization catalog")
struct LocalizationCatalogTests {
    private var catalog: [String: String] { LocalizationCatalog.english }

    @Test("no key is defined twice")
    func noDuplicateKeys() {
        #expect(
            catalog.count == LocalizationCatalog.declaredEntryCount,
            "a chunk defines the same Chinese source text twice; the later one is silently dropped"
        )
    }

    @Test("every entry has a non-empty translation")
    func noEmptyValues() {
        let empty = catalog.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #expect(empty.isEmpty, "empty translations: \(empty.keys.sorted())")
    }

    @Test("English contains no Chinese")
    func englishHasNoChinese() {
        // No entry may keep its Chinese. The one string that does — the language
        // name `简体中文` in the picker — is not a catalog entry at all: it is
        // written in the interface as-is, because a language is named in itself.
        let offenders = catalog.filter { $0.value.contains(where: Self.isChinese) }
        #expect(
            offenders.isEmpty,
            "untranslated values: \(offenders.map { "\($0.key) -> \($0.value)" }.sorted())"
        )
    }

    @Test("format specifiers match between source and translation")
    func specifiersAgree() {
        var mismatches: [String] = []
        for (key, value) in catalog {
            let source = Self.specifiers(in: key)
            let forms = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            for form in forms where Self.specifiers(in: form) != source {
                mismatches.append("\(key) → \(value) (expected \(source), found \(Self.specifiers(in: form)))")
            }
        }
        #expect(mismatches.isEmpty, "specifier mismatches: \(mismatches.sorted())")
    }

    @Test("plural entries are either one form or two, never more")
    func pluralEntryShape() {
        // `%d` entries are read through `n`, which splits on `|`. One form is
        // legitimate — English that sidesteps the noun ("%d more") needs no
        // split — but three would mean a stray separator reached the text.
        var problems: [String] = []
        for (key, value) in catalog where key.contains("%d") {
            let forms = value.split(separator: "|", omittingEmptySubsequences: false)
            if forms.count > 2 { problems.append("\(key) → \(value)") }
        }
        #expect(problems.isEmpty, "plural entries with too many forms: \(problems.sorted())")
    }

    private static func isChinese(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
    }

    /// `%@`, `%d` and `%.1f` in order; `%%` is a literal percent and is not one.
    private static func specifiers(in text: String) -> [String] {
        var found: [String] = []
        var characters = Array(text)
        var index = 0
        while index < characters.count - 1 {
            if characters[index] == "%" {
                let next = characters[index + 1]
                if next == "%" {
                    index += 2
                    continue
                }
                var specifier = "%"
                var cursor = index + 1
                while cursor < characters.count, ".0123456789".contains(characters[cursor]) {
                    specifier.append(characters[cursor])
                    cursor += 1
                }
                if cursor < characters.count {
                    specifier.append(characters[cursor])
                    found.append(specifier)
                    index = cursor + 1
                    continue
                }
            }
            index += 1
        }
        return found
    }
}

// MARK: - Persisting the choice

@Suite("Language preference")
struct LanguagePreferenceTests {
    private func defaults() -> UserDefaults {
        // A private suite per test: `UserDefaults(suiteName:)` is cheap and keeps
        // the tests from touching the real preference domain.
        UserDefaults(suiteName: "cn.opensvn.tests.language.\(UUID().uuidString)")!
    }

    @Test("a fresh install follows the system")
    func defaultIsSystem() {
        #expect(LanguagePreference.load(from: defaults()) == .system)
    }

    @Test("an explicit choice round-trips")
    func explicitChoiceRoundTrips() {
        for language in AppLanguage.allCases {
            let store = defaults()
            LanguagePreference.save(language, to: store)
            #expect(LanguagePreference.load(from: store) == language)
        }
    }

    @Test("an unrecognised stored value falls back to following the system")
    func unknownValueFallsBack() {
        let store = defaults()
        store.set("klingon", forKey: LanguagePreference.defaultsKey)
        #expect(LanguagePreference.load(from: store) == .system)
    }

    @Test("the stored value is the raw tag, not the case name")
    func storesRawValue() {
        let store = defaults()
        LanguagePreference.save(.chinese, to: store)
        #expect(store.string(forKey: LanguagePreference.defaultsKey) == "zh-Hans")
        LanguagePreference.save(.english, to: store)
        #expect(store.string(forKey: LanguagePreference.defaultsKey) == "en")
    }
}
