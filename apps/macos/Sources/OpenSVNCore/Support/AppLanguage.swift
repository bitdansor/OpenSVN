import Foundation

/// What the user chose in Settings.
///
/// `system` is the default and means "follow macOS": the interface language is
/// re-resolved from the system's preferred languages on every launch, so a user
/// who switches macOS to English gets an English OpenSVN without touching the
/// app. The two explicit cases pin one language regardless of the system.
public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    /// The language this preference asks for, or `nil` when it defers to the
    /// system.
    public var explicitLanguage: InterfaceLanguage? {
        switch self {
        case .system: nil
        case .chinese: .chinese
        case .english: .english
        }
    }
}

/// The language the interface is actually drawn in. Only these two exist;
/// `AppLanguage.system` is a preference, not a rendering target.
public enum InterfaceLanguage: String, CaseIterable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"

    /// The language tag, for anything that takes a `Locale`.
    public var localeIdentifier: String { rawValue }

    /// A locale that reads dates the way the interface is written, while keeping
    /// the user's regional conventions — first day of week, 24-hour clock,
    /// decimal separator — from `Locale.current`.
    ///
    /// Replacing the locale wholesale with `en` would drop those: a European
    /// reader who switched the interface to English would find their 24-hour
    /// clock replaced by AM/PM. Pairing the interface language with the system's
    /// region keeps the screen in one language without arguing with the system's
    /// conventions — `en_DE` is English month names on a 24-hour clock, which is
    /// what that reader asked for.
    public var locale: Locale {
        guard let region = Locale.current.region?.identifier, !region.isEmpty else {
            return Locale(identifier: localeIdentifier)
        }
        return Locale(identifier: "\(localeIdentifier)_\(region)")
    }
}

/// Turns a preference plus the system's preferred languages into the language
/// the interface should use.
///
/// Deliberately a pure function: the launch path, the Settings pane and the
/// tests all need to agree on this rule, and the tests cannot read the real
/// system preferences.
public enum LanguageResolver {
    /// Resolves the interface language.
    ///
    /// - Parameters:
    ///   - preference: what the user chose.
    ///   - preferredLanguages: `Locale.preferredLanguages` in production.
    ///
    /// Any Chinese variant (`zh-Hans`, `zh-Hant`, `zh_CN`, bare `zh`) selects
    /// the Chinese interface: the app ships one Chinese translation, and a
    /// Traditional-Chinese reader is better served by it than by English.
    /// Everything else selects English, including a list that is empty or whose
    /// first entry is malformed — English is the safer default for a non-Chinese
    /// system, and it is also the language of the source comments and the
    /// upstream svn output the app surfaces.
    public static func resolve(
        preference: AppLanguage,
        preferredLanguages: [String]
    ) -> InterfaceLanguage {
        if let explicit = preference.explicitLanguage {
            return explicit
        }
        return language(forPreferredTag: preferredLanguages.first)
    }

    /// Classifies a single BCP-47-ish tag. Separated out so the rule can be
    /// pinned by tests without inventing a whole preference list.
    public static func language(forPreferredTag tag: String?) -> InterfaceLanguage {
        guard let tag, !tag.isEmpty else { return .english }
        // `zh-Hans`, `zh_Hant_TW`, `zh` all reduce to `zh`. The split is on both
        // separators because `Locale.preferredLanguages` uses `-` while the
        // legacy `AppleLanguages` defaults sometimes carry `_`.
        let primary = tag
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)?
            .lowercased()
        return primary == "zh" ? .chinese : .english
    }
}

/// Where the choice is stored.
///
/// The read and write live here rather than in `AppSettings` so the key has one
/// definition and the migration rule (an unknown value means "follow the
/// system") is testable without an app target.
public enum LanguagePreference {
    public static let defaultsKey = "cn.opensvn.language"

    public static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        // An unrecognised value — a hand-edited plist, or a language an older
        // build wrote — falls back to following the system. Guessing a specific
        // language from a corrupt key would be worse than asking macOS.
        defaults.string(forKey: defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    public static func save(_ language: AppLanguage, to defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
    }
}
