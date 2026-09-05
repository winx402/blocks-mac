import Combine
import Foundation

enum BlocksFeature: String, CaseIterable, Sendable {
    case screenshot
    case clipboard
}

enum SettingsAttentionTarget: String, Sendable {
    case screenshotTag = "settings.screenshot.tag"
}

struct SettingsAttentionRequest: Equatable, Sendable {
    let target: SettingsAttentionTarget
    let token: UUID

    init(target: SettingsAttentionTarget, token: UUID = UUID()) {
        self.target = target
        self.token = token
    }
}

struct FeatureAvailabilitySnapshot: Equatable, Sendable {
    let screenshotEnabled: Bool
    let clipboardEnabled: Bool

    func isEnabled(_ feature: BlocksFeature) -> Bool {
        switch feature {
        case .screenshot: screenshotEnabled
        case .clipboard: clipboardEnabled
        }
    }
}

@MainActor
final class FeatureAvailabilityStore: ObservableObject {
    private enum Keys {
        static let screenshotEnabled = "feature.screenshot.enabled"
        static let clipboardEnabled = "feature.clipboard.enabled"
    }

    @Published private(set) var screenshotEnabled: Bool
    @Published private(set) var clipboardEnabled: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        screenshotEnabled = defaults.object(forKey: Keys.screenshotEnabled) as? Bool ?? true
        clipboardEnabled = defaults.object(forKey: Keys.clipboardEnabled) as? Bool ?? true
    }

    var snapshot: FeatureAvailabilitySnapshot {
        FeatureAvailabilitySnapshot(
            screenshotEnabled: screenshotEnabled,
            clipboardEnabled: clipboardEnabled
        )
    }

    func setScreenshotEnabled(_ enabled: Bool) {
        guard screenshotEnabled != enabled else { return }
        screenshotEnabled = enabled
        defaults.set(enabled, forKey: Keys.screenshotEnabled)
    }

    func setClipboardEnabled(_ enabled: Bool) {
        guard clipboardEnabled != enabled else { return }
        clipboardEnabled = enabled
        defaults.set(enabled, forKey: Keys.clipboardEnabled)
    }
}
