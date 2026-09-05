import BlocksCore
import AVFoundation
import Foundation
import NaturalLanguage

struct TranslationUserLanguagePreferenceSnapshot: Equatable {
    let nativeLanguage: TranslationLanguageTag
    let focusLanguages: [TranslationLanguageTag]
    let recentlyUsedFocusLanguage: TranslationLanguageTag?
}

struct TranslationTargetResolution: Equatable {
    let detectedSource: TranslationLanguageTag?
    let target: TranslationLanguageTag?
    let usedFallbackDetection: Bool
    let sourceResolution: TranslationSourceResolution
}

struct TranslationResolvedDirection: Equatable {
    let source: TranslationLanguageTag?
    let target: TranslationLanguageTag?
    let sourceResolution: TranslationSourceResolution

    var direction: TranslationLanguageDirection? {
        guard let target else { return nil }
        return TranslationLanguageDirection(
            source: source,
            target: target
        )
    }
}

struct TranslationLanguageMenuSections: Equatable {
    let common: [TranslationLanguageTag]
    let all: [TranslationLanguageTag]
}

enum TranslationSourceResolution: String, Equatable {
    case explicit
    case statistical
    case script
    case languagePairFallback = "language_pair_fallback"
    case unresolved
}

enum TranslationTargetResolver {
    static func resolveDirection(
        text: String,
        explicitSource: TranslationLanguageTag?,
        explicitTarget: TranslationLanguageTag?,
        preferences: TranslationUserLanguagePreferenceSnapshot
    ) -> TranslationResolvedDirection {
        let detected = resolvedSource(
            in: text,
            explicitSource: explicitSource,
            preferences: preferences
        )
        let fallbackTarget = preferences.recentlyUsedFocusLanguage
            .flatMap { recent in
                preferences.focusLanguages.first(where: {
                    isSameLanguage($0, recent)
                })
            }
            ?? preferences.focusLanguages.first

        if let explicitTarget {
            let pairFallback =
                detected.source
                ?? deterministicSource(
                    excluding: explicitTarget,
                    preferences: preferences
                )
            return TranslationResolvedDirection(
                source: pairFallback,
                target: explicitTarget,
                sourceResolution:
                    detected.source != nil
                        ? detected.method
                        : (
                            pairFallback == nil
                                ? .unresolved
                                : .languagePairFallback
                        )
            )
        }

        guard let source = detected.source else {
            let pairFallback = fallbackTarget.flatMap { target in
                deterministicSource(
                    excluding: target,
                    preferences: preferences
                )
            }
            return TranslationResolvedDirection(
                source: pairFallback,
                target: fallbackTarget,
                sourceResolution:
                    pairFallback == nil
                        ? .unresolved
                        : .languagePairFallback
            )
        }
        let target =
            isSameLanguage(source, preferences.nativeLanguage)
                ? fallbackTarget
                : preferences.nativeLanguage
        return TranslationResolvedDirection(
            source: source,
            target: target,
            sourceResolution: detected.method
        )
    }

    static func resolve(
        text: String,
        explicitSource: TranslationLanguageTag?,
        preferences: TranslationUserLanguagePreferenceSnapshot
    ) -> TranslationTargetResolution {
        let resolved = resolveDirection(
            text: text,
            explicitSource: explicitSource,
            explicitTarget: nil,
            preferences: preferences
        )
        return TranslationTargetResolution(
            detectedSource: resolved.source,
            target: resolved.target,
            usedFallbackDetection:
                resolved.sourceResolution != .explicit
                    && resolved.sourceResolution != .statistical,
            sourceResolution: resolved.sourceResolution
        )
    }

    private static func resolvedSource(
        in text: String,
        explicitSource: TranslationLanguageTag?,
        preferences: TranslationUserLanguagePreferenceSnapshot
    ) -> (
        source: TranslationLanguageTag?,
        method: TranslationSourceResolution
    ) {
        if let explicitSource {
            return (explicitSource, .explicit)
        } else if let detected = reliablyDetectedLanguage(in: text) {
            return (detected, .statistical)
        } else if let scriptResolved = scriptResolvedLanguage(
            in: text,
            preferences: preferences
        ) {
            return (scriptResolved, .script)
        }
        return (nil, .unresolved)
    }

    static func reliablyDetectedLanguage(
        in text: String
    ) -> TranslationLanguageTag? {
        let normalized = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalized.count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(normalized)
        guard let language = recognizer.dominantLanguage,
              let confidence = recognizer
                .languageHypotheses(withMaximum: 1)[language],
              confidence >= minimumReliableConfidence(
                forCharacterCount: normalized.count
              ) else {
            return nil
        }
        return TranslationLanguageTag(language.rawValue)
    }

    private static func minimumReliableConfidence(
        forCharacterCount count: Int
    ) -> Double {
        if count < 8 {
            return 0.75
        }
        if count < 20 {
            return 0.55
        }
        return 0.35
    }

    private static func scriptResolvedLanguage(
        in text: String,
        preferences: TranslationUserLanguagePreferenceSnapshot
    ) -> TranslationLanguageTag? {
        let scripts = detectedScripts(in: text)
        guard !scripts.isEmpty else { return nil }
        if let distinctiveLanguage = distinctiveLanguage(
            for: scripts
        ) {
            return distinctiveLanguage
        }
        let candidates = [preferences.nativeLanguage]
            + preferences.focusLanguages
        let matching = candidates.filter {
            !scripts.isDisjoint(with: scriptFamilies(for: $0))
        }
        guard !matching.isEmpty else { return nil }
        if matching.count == 1 {
            return matching[0]
        }
        if matching.contains(where: {
            isSameLanguage($0, preferences.nativeLanguage)
        }) {
            return preferences.nativeLanguage
        }
        return nil
    }

    private static func distinctiveLanguage(
        for scripts: Set<ScriptFamily>
    ) -> TranslationLanguageTag? {
        if scripts.contains(.kana) {
            return TranslationLanguageTag("ja")
        }
        if scripts.contains(.hangul) {
            return TranslationLanguageTag("ko")
        }
        if scripts == [.arabic] {
            return TranslationLanguageTag("ar")
        }
        if scripts == [.devanagari] {
            return TranslationLanguageTag("hi")
        }
        if scripts == [.greek] {
            return TranslationLanguageTag("el")
        }
        if scripts == [.hebrew] {
            return TranslationLanguageTag("he")
        }
        if scripts == [.thai] {
            return TranslationLanguageTag("th")
        }
        return nil
    }

    private static func deterministicSource(
        excluding target: TranslationLanguageTag,
        preferences: TranslationUserLanguagePreferenceSnapshot
    ) -> TranslationLanguageTag? {
        var candidates: [TranslationLanguageTag] = []
        for language in [preferences.nativeLanguage]
            + preferences.focusLanguages
        where !isSameLanguage(language, target)
            && !candidates.contains(where: {
                isSameLanguage($0, language)
            }) {
            candidates.append(language)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private enum ScriptFamily: Hashable {
        case arabic
        case cyrillic
        case devanagari
        case greek
        case han
        case hangul
        case hebrew
        case kana
        case latin
        case thai
    }

    private static func detectedScripts(in text: String) -> Set<ScriptFamily> {
        var result: Set<ScriptFamily> = []
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x0370 ... 0x03FF:
                result.insert(.greek)
            case 0x0400 ... 0x052F:
                result.insert(.cyrillic)
            case 0x0590 ... 0x05FF:
                result.insert(.hebrew)
            case 0x0600 ... 0x06FF, 0x0750 ... 0x077F:
                result.insert(.arabic)
            case 0x0900 ... 0x097F:
                result.insert(.devanagari)
            case 0x0E00 ... 0x0E7F:
                result.insert(.thai)
            case 0x3040 ... 0x30FF, 0x31F0 ... 0x31FF:
                result.insert(.kana)
            case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF,
                 0x20000 ... 0x2FA1F:
                result.insert(.han)
            case 0x1100 ... 0x11FF, 0x3130 ... 0x318F,
                 0xAC00 ... 0xD7AF:
                result.insert(.hangul)
            case 0x0041 ... 0x005A, 0x0061 ... 0x007A,
                 0x00C0 ... 0x024F:
                result.insert(.latin)
            default:
                continue
            }
        }
        return result
    }

    private static func scriptFamilies(
        for language: TranslationLanguageTag
    ) -> Set<ScriptFamily> {
        let base = language.rawValue
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased() ?? language.rawValue.lowercased()
        switch base {
        case "ar":
            return [.arabic]
        case "el":
            return [.greek]
        case "he":
            return [.hebrew]
        case "hi":
            return [.devanagari]
        case "ja":
            return [.kana, .han]
        case "ko":
            return [.hangul]
        case "ru", "uk":
            return [.cyrillic]
        case "th":
            return [.thai]
        case "zh":
            return [.han]
        default:
            return [.latin]
        }
    }

    static func isSameLanguage(
        _ lhs: TranslationLanguageTag,
        _ rhs: TranslationLanguageTag
    ) -> Bool {
        normalizedIdentifier(lhs.rawValue)
            == normalizedIdentifier(rhs.rawValue)
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

enum TranslationUserLanguagePreferences {
    static let nativeLanguageKey =
        "translation.preference.nativeLanguageTag"
    static let focusLanguagesKey =
        "translation.preference.focusLanguageTags"
    static let recentFocusLanguageKey =
        "translation.preference.recentFocusLanguageTag"
    static let migrationVersionKey =
        "translation.preference.languageModelVersion"

    // These keys are read only by the one-time migration. They intentionally
    // remain public to the module so older tests and builds can seed migration
    // fixtures without retaining the old target-selection runtime.
    static let defaultTargetKey = "translation.preference.defaultTargetLanguageTag"
    static let lastTargetKey = "translation.preference.lastTargetLanguageTag"
    static let rememberLastKey = "translation.preference.rememberLastTarget"
    static let commonOptions: [TranslationLanguageTag] = [
        "ar", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he",
        "hi", "hu", "id", "it", "ja", "ko", "ms", "nl", "no", "pl",
        "pt-BR", "pt-PT", "ro", "ru", "sk", "sv", "th", "tr", "uk",
        "vi", "zh-Hans", "zh-Hant",
    ].compactMap { TranslationLanguageTag($0) }

    static func snapshot(
        defaults: UserDefaults = .standard
    ) -> TranslationUserLanguagePreferenceSnapshot {
        migrateIfNeeded(defaults: defaults)
        let native = defaults.string(forKey: nativeLanguageKey)
            .flatMap { TranslationLanguageTag($0) }
            ?? nativeLanguageForCurrentLocale()
        let focusLanguages = normalizedFocusLanguages(
            defaults.stringArray(forKey: focusLanguagesKey)
                ?? [],
            excluding: native
        )
        let recent = defaults.string(forKey: recentFocusLanguageKey)
            .flatMap { TranslationLanguageTag($0) }
            .flatMap { recent in
                focusLanguages.first(where: {
                    TranslationTargetResolver.isSameLanguage($0, recent)
                })
            }
        return TranslationUserLanguagePreferenceSnapshot(
            nativeLanguage: native,
            focusLanguages: focusLanguages,
            recentlyUsedFocusLanguage: recent
        )
    }

    static func preferredTarget(
        defaults: UserDefaults = .standard
    ) -> TranslationLanguageTag {
        let preferences = snapshot(defaults: defaults)
        return preferences.recentlyUsedFocusLanguage
            ?? preferences.focusLanguages.first
            ?? preferences.nativeLanguage
    }

    static func setNativeLanguage(
        _ language: TranslationLanguageTag,
        defaults: UserDefaults = .standard
    ) {
        let current = snapshot(defaults: defaults)
        defaults.set(language.rawValue, forKey: nativeLanguageKey)
        let focus = normalizedFocusLanguages(
            current.focusLanguages.map(\.rawValue),
            excluding: language
        )
        defaults.set(focus.map(\.rawValue), forKey: focusLanguagesKey)
        if let recent = current.recentlyUsedFocusLanguage,
           !focus.contains(where: {
               TranslationTargetResolver.isSameLanguage($0, recent)
           }) {
            defaults.removeObject(forKey: recentFocusLanguageKey)
        }
    }

    static func setFocusLanguages(
        _ languages: [TranslationLanguageTag],
        defaults: UserDefaults = .standard
    ) {
        let native = snapshot(defaults: defaults).nativeLanguage
        let normalized = normalizedFocusLanguages(
            languages.map(\.rawValue),
            excluding: native
        )
        defaults.set(normalized.map(\.rawValue), forKey: focusLanguagesKey)
        if let recent = defaults.string(forKey: recentFocusLanguageKey)
            .flatMap({ TranslationLanguageTag($0) }),
           !normalized.contains(where: {
               TranslationTargetResolver.isSameLanguage($0, recent)
           }) {
            defaults.removeObject(forKey: recentFocusLanguageKey)
        }
    }

    static func rememberFocusLanguage(
        _ target: TranslationLanguageTag,
        defaults: UserDefaults = .standard
    ) {
        let preferences = snapshot(defaults: defaults)
        guard preferences.focusLanguages.contains(where: {
            TranslationTargetResolver.isSameLanguage($0, target)
        }) else {
            return
        }
        defaults.set(target.rawValue, forKey: recentFocusLanguageKey)
    }

    static func localizedName(
        for tag: TranslationLanguageTag,
        locale: Locale = .current
    ) -> String {
        locale.localizedString(forIdentifier: tag.rawValue)
            ?? locale.localizedString(forLanguageCode: tag.rawValue)
            ?? tag.rawValue
    }

    static func sortedOptions(
        _ tags: [TranslationLanguageTag],
        locale: Locale = .current
    ) -> [TranslationLanguageTag] {
        var seen: Set<TranslationLanguageTag> = []
        return tags
            .filter { seen.insert($0).inserted }
            .sorted {
                localizedName(for: $0, locale: locale)
                    .localizedStandardCompare(localizedName(for: $1, locale: locale))
                    == .orderedAscending
            }
    }

    static func menuOptions(
        available: [TranslationLanguageTag],
        current: TranslationLanguageTag?,
        locale: Locale = .current
    ) -> [TranslationLanguageTag] {
        let sections = menuSections(
            available: available,
            current: current,
            locale: locale
        )
        return sections.common + sections.all
    }

    static func menuSections(
        available: [TranslationLanguageTag],
        current: TranslationLanguageTag?,
        preferences: TranslationUserLanguagePreferenceSnapshot? = nil,
        locale: Locale = .current
    ) -> TranslationLanguageMenuSections {
        let preferences = preferences ?? snapshot()
        var candidates: [TranslationLanguageTag] = []
        for language in available + (current.map { [$0] } ?? []) {
            guard !candidates.contains(language) else { continue }
            candidates.append(language)
        }

        var preferred: [TranslationLanguageTag] = [
            preferences.nativeLanguage,
        ]
        if let recent = preferences.recentlyUsedFocusLanguage {
            preferred.append(recent)
        }
        preferred.append(contentsOf: preferences.focusLanguages)

        var common: [TranslationLanguageTag] = []
        for preferredLanguage in preferred {
            guard let availableLanguage = candidates.first(where: {
                TranslationTargetResolver.isSameLanguage(
                    $0,
                    preferredLanguage
                )
            }),
            !common.contains(availableLanguage) else {
                continue
            }
            common.append(availableLanguage)
        }
        let commonSet = Set(common)
        let all = sortedOptions(
            candidates.filter { !commonSet.contains($0) },
            locale: locale
        )
        return TranslationLanguageMenuSections(
            common: common,
            all: all
        )
    }

    static func migrateIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        guard defaults.integer(forKey: migrationVersionKey) < 1 else {
            return
        }

        let legacyDefault = defaults.string(forKey: defaultTargetKey)
            ?? defaults.string(
                forKey: "translation.preference.defaultTargetLanguage"
            )
            ?? defaults.string(
                forKey: "translation.runtime.targetLanguage"
            )
        let native = legacyDefault.flatMap(legacyTag)
            ?? nativeLanguageForCurrentLocale()
        var focus: [TranslationLanguageTag] = []
        if let legacyLast = defaults.string(forKey: lastTargetKey)
            .flatMap(legacyTag),
           !TranslationTargetResolver.isSameLanguage(
               legacyLast,
               native
           ) {
            focus.append(legacyLast)
        }
        if focus.isEmpty {
            focus.append(defaultFocusLanguage(for: native))
        }
        focus = normalizedFocusLanguages(
            focus.map(\.rawValue),
            excluding: native
        )
        defaults.set(native.rawValue, forKey: nativeLanguageKey)
        defaults.set(focus.map(\.rawValue), forKey: focusLanguagesKey)
        if let first = focus.first {
            defaults.set(
                first.rawValue,
                forKey: recentFocusLanguageKey
            )
        }
        defaults.set(1, forKey: migrationVersionKey)
    }

    private static func normalizedFocusLanguages(
        _ values: [String],
        excluding native: TranslationLanguageTag
    ) -> [TranslationLanguageTag] {
        var result: [TranslationLanguageTag] = []
        for value in values {
            guard let tag = legacyTag(value),
                  !TranslationTargetResolver.isSameLanguage(tag, native),
                  !result.contains(where: {
                      TranslationTargetResolver.isSameLanguage($0, tag)
                  }) else {
                continue
            }
            result.append(tag)
        }
        return result
    }

    private static func legacyTag(_ value: String) -> TranslationLanguageTag? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "simplified chinese", "chinese", "zh-hans", "zh_cn", "zh-cn":
            TranslationLanguageTag("zh-Hans")
        case "traditional chinese", "zh-hant", "zh_tw", "zh-tw":
            TranslationLanguageTag("zh-Hant")
        case "english", "en", "en-us":
            TranslationLanguageTag("en")
        case "japanese", "ja", "ja-jp":
            TranslationLanguageTag("ja")
        default:
            TranslationLanguageTag(value)
        }
    }

    private static func nativeLanguageForCurrentLocale() -> TranslationLanguageTag {
        guard let preferred = Locale.preferredLanguages.first else {
            return TranslationLanguageTag("zh-Hans")!
        }
        if preferred.lowercased().hasPrefix("zh-hant") {
            return TranslationLanguageTag("zh-Hant")!
        }
        if preferred.lowercased().hasPrefix("zh") {
            return TranslationLanguageTag("zh-Hans")!
        }
        let base = preferred.split(separator: "-").first.map(String.init)
        return base.flatMap { TranslationLanguageTag($0) }
            ?? TranslationLanguageTag("en")!
    }

    private static func defaultFocusLanguage(
        for native: TranslationLanguageTag
    ) -> TranslationLanguageTag {
        if native.rawValue.lowercased().hasPrefix("zh") {
            return TranslationLanguageTag("en")!
        }
        return TranslationLanguageTag("zh-Hans")!
    }
}

typealias TranslationLanguagePreferences =
    TranslationUserLanguagePreferences

enum TranslationSpeechLanguageResolver {
    static func candidates(
        for language: TranslationLanguageTag
    ) -> [String] {
        let fullTag = language.rawValue
        let baseTag = fullTag.split(separator: "-").first.map(String.init)
        return [fullTag, baseTag]
            .compactMap { $0 }
            .reduce(into: []) { result, candidate in
                guard !result.contains(candidate) else { return }
                result.append(candidate)
            }
    }

    static func voice(
        for language: TranslationLanguageTag
    ) -> AVSpeechSynthesisVoice? {
        candidates(for: language)
            .lazy
            .compactMap(AVSpeechSynthesisVoice.init(language:))
            .first
    }
}
