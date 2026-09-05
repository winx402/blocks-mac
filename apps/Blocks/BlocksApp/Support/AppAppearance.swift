import AppKit
import Combine
import Foundation

enum AppAppearancePreference: String, CaseIterable, Identifiable {
    static let defaultsKey = "app.appearance"

    case system
    case light
    case dark

    var id: String { rawValue }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system:
            nil
        case .light:
            .aqua
        case .dark:
            .darkAqua
        }
    }

    var displayName: String {
        switch self {
        case .system:
            L10n.string("settings.appearance.system")
        case .light:
            L10n.string("settings.appearance.light")
        case .dark:
            L10n.string("settings.appearance.dark")
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            "circle.lefthalf.filled"
        case .light:
            "sun.max"
        case .dark:
            "moon"
        }
    }
}

@MainActor
final class AppAppearanceStore: ObservableObject {
    typealias AppearanceApplier = @MainActor (NSAppearance?) -> Void

    @Published private(set) var preference: AppAppearancePreference

    private let defaults: UserDefaults
    private let appearanceApplier: AppearanceApplier

    init(
        defaults: UserDefaults = .standard,
        appearanceApplier: @escaping AppearanceApplier = { appearance in
            NSApplication.shared.appearance = appearance
        }
    ) {
        self.defaults = defaults
        self.appearanceApplier = appearanceApplier

        if let rawValue = defaults.string(forKey: AppAppearancePreference.defaultsKey),
           let storedPreference = AppAppearancePreference(rawValue: rawValue) {
            preference = storedPreference
        } else {
            preference = .system
            if defaults.object(forKey: AppAppearancePreference.defaultsKey) != nil {
                defaults.set(AppAppearancePreference.system.rawValue, forKey: AppAppearancePreference.defaultsKey)
            }
        }

        apply(preference)
    }

    func setPreference(_ preference: AppAppearancePreference) {
        guard self.preference != preference else {
            apply(preference)
            return
        }

        self.preference = preference
        defaults.set(preference.rawValue, forKey: AppAppearancePreference.defaultsKey)
        apply(preference)
    }

    private func apply(_ preference: AppAppearancePreference) {
        let appearance = preference.appearanceName.flatMap(NSAppearance.init(named:))
        appearanceApplier(appearance)
    }
}
