import AppKit
import Carbon.HIToolbox
import Foundation
import BlocksCore

@MainActor
enum Step5OneShotMigration {
    private static let completedKey = "step5.oneShotMigration.v0.completed"
    private static let oldPrivacyExcludedBundleIDsKey = "clipboard.policy.excludedBundleIDs"
    private static let privacyExcludedBundleIDsMigrationKey = "privacy.policy.migratedExcludedBundleIDs.v1"
    private static let oldClipboardBottomSizeKey = "floatingPanel.clipboard.bottom.size"
    private static let currentClipboardBottomHeightKey = "floatingPanel.clipboard.bottom.height"
    private static let oldClipboardRetentionDaysKey = "clipboard.policy.retentionDays"
    private static let currentClipboardRetentionKey = "clipboard.policy.retention"
    private static let clipboardRetentionMigrationKey = "clipboard.policy.retention.migratedTypedPolicy.v1"
    private static let shortcutGlobalModifierKey = "shortcut.globalModifier"
    private static let oldGlobalModifierMigrationKey = "shortcut.globalModifier.migratedControlOptionDefault.v2"
    private static let oldCustomBindingMigrationKey = "shortcut.customBinding.migratedControlOptionDefault.v2"
    private static let defaultGlobalModifierPreset: ShortcutModifierPreset = .controlOption

    static func run(defaults: UserDefaults = .standard) {
        migrateLegacyPrivacyExclusions(defaults: defaults)
        migrateClipboardRetentionPolicy(defaults: defaults)

        guard !defaults.bool(forKey: completedKey) else {
            return
        }
        migrateClipboardBottomHeight(defaults: defaults)
        migrateShortcutDefaults(defaults: defaults)
        defaults.removeObject(forKey: oldGlobalModifierMigrationKey)
        defaults.removeObject(forKey: oldCustomBindingMigrationKey)
        defaults.set(true, forKey: completedKey)
    }

    private static func migrateClipboardRetentionPolicy(defaults: UserDefaults) {
        guard !defaults.bool(forKey: clipboardRetentionMigrationKey) else {
            return
        }
        defer {
            defaults.removeObject(forKey: oldClipboardRetentionDaysKey)
            defaults.set(true, forKey: clipboardRetentionMigrationKey)
        }
        guard defaults.object(forKey: currentClipboardRetentionKey) == nil,
              defaults.object(forKey: oldClipboardRetentionDaysKey) != nil else {
            return
        }

        let policy: ClipboardRetentionPolicy
        switch defaults.integer(forKey: oldClipboardRetentionDaysKey) {
        case 7:
            policy = .days7
        case 90:
            policy = .days90
        case 3650:
            policy = .forever
        case 30:
            policy = .days30
        default:
            policy = .days30
        }
        defaults.set(policy.rawValue, forKey: currentClipboardRetentionKey)
    }

    private static func migrateLegacyPrivacyExclusions(defaults: UserDefaults) {
        guard !defaults.bool(forKey: privacyExcludedBundleIDsMigrationKey) else {
            return
        }

        let legacyBundleIDs = legacyExcludedBundleIDs(defaults: defaults)
        guard !legacyBundleIDs.isEmpty else {
            defaults.set(true, forKey: privacyExcludedBundleIDsMigrationKey)
            defaults.removeObject(forKey: oldPrivacyExcludedBundleIDsKey)
            return
        }

        do {
            let repository = try PrivacyPolicyRepository(database: AppDatabase.open())
            _ = try repository.migrateLegacyRestrictedBundleIDs(legacyBundleIDs)
            defaults.set(true, forKey: privacyExcludedBundleIDsMigrationKey)
            defaults.removeObject(forKey: oldPrivacyExcludedBundleIDsKey)
        } catch {
            defaults.removeObject(forKey: privacyExcludedBundleIDsMigrationKey)
        }
    }

    private static func legacyExcludedBundleIDs(defaults: UserDefaults) -> [String] {
        if let values = defaults.array(forKey: oldPrivacyExcludedBundleIDsKey) as? [String] {
            return normalizedBundleIDs(values)
        }
        if let value = defaults.string(forKey: oldPrivacyExcludedBundleIDsKey) {
            return normalizedBundleIDs(
                value
                    .split { $0 == "," || $0 == "\n" || $0 == ";" }
                    .map(String.init)
            )
        }
        return []
    }

    private static func normalizedBundleIDs(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .reduce(into: [String]()) { result, bundleID in
                if result.last != bundleID {
                    result.append(bundleID)
                }
            }
    }

    private static func migrateClipboardBottomHeight(defaults: UserDefaults) {
        if defaults.object(forKey: currentClipboardBottomHeightKey) == nil,
           let values = defaults.array(forKey: oldClipboardBottomSizeKey) as? [Double],
           values.count == 2 {
            defaults.set(values[1], forKey: currentClipboardBottomHeightKey)
        }
        defaults.removeObject(forKey: oldClipboardBottomSizeKey)
    }

    private static func migrateShortcutDefaults(defaults: UserDefaults) {
        if defaults.string(forKey: shortcutGlobalModifierKey) == nil ||
            defaults.string(forKey: shortcutGlobalModifierKey) == ShortcutModifierPreset.option.rawValue {
            defaults.set(defaultGlobalModifierPreset.rawValue, forKey: shortcutGlobalModifierKey)
        }

        for command in ShortcutCommand.allCases {
            rewriteOptionOnlyDefaultBinding(command: command, defaults: defaults)
        }
    }

    private static func rewriteOptionOnlyDefaultBinding(command: ShortcutCommand, defaults: UserDefaults) {
        let key = "shortcut.binding.\(command.rawValue)"
        guard
            let rawValue = defaults.string(forKey: key),
            let data = rawValue.data(using: .utf8),
            var binding = try? JSONDecoder().decode(ShortcutBinding.self, from: data),
            binding.command == command,
            binding.keyCode == command.defaultBinding.keyCode,
            binding.keyLabel.caseInsensitiveCompare(command.defaultBinding.keyLabel) == .orderedSame,
            binding.modifierFlags == NSEvent.ModifierFlags.option
        else {
            return
        }

        binding = binding.replacingModifierFlags(defaultGlobalModifierPreset.modifierFlags)
        if let data = try? JSONEncoder().encode(binding),
           let rawValue = String(data: data, encoding: .utf8) {
            defaults.set(rawValue, forKey: key)
        }
    }
}
