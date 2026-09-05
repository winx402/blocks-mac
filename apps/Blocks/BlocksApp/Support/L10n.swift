import Foundation

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            L10n.string("settings.language.followSystem")
        case .zhHans:
            "简体中文"
        case .english:
            "English"
        case .japanese:
            "日本語"
        }
    }
}

struct AppLanguageSessionSnapshot: Equatable {
    static let preferenceKey = "app.language"

    let preference: AppLanguagePreference

    init(defaults: UserDefaults = .standard) {
        preference = AppLanguagePreference(
            rawValue: defaults.string(forKey: Self.preferenceKey) ?? ""
        ) ?? .system
    }

    func localizationBundle(in mainBundle: Bundle) -> Bundle {
        guard preference != .system,
              let path = mainBundle.path(
                  forResource: preference.rawValue,
                  ofType: "lproj"
              ),
              let bundle = Bundle(path: path) else {
            return mainBundle
        }
        return bundle
    }
}

enum L10n {
    // The language picker explicitly promises that the change takes effect on
    // the next launch. Capturing the preference once keeps AppKit surfaces,
    // SwiftUI content and window titles in the same language for this session.
    private static let session = AppLanguageSessionSnapshot()
    private static let localizationBundle = session.localizationBundle(in: .main)

    static func string(_ key: String) -> String {
        let bundle = localizationBundle
        let standard = bundle.localizedString(forKey: key, value: key, table: nil)
        guard standard == key else { return standard }
        for table in ["ScreenshotLocalizable", "TranslationLocalizable"] {
            let localized = bundle.localizedString(forKey: key, value: key, table: table)
            if localized != key {
                return localized
            }
        }
        return key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let format = string(key)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
