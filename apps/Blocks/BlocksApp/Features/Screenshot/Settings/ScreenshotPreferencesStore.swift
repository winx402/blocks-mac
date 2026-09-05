import BlocksScreenshotCore
import Combine
import Foundation

enum ScreenshotToolZone: String, Hashable {
    case quick
    case expanded
    case hidden
}
@MainActor
final class ScreenshotPreferencesStore: ObservableObject {
    static let storageKey = "screenshot.preferences.v19"
    private static let legacyV18StorageKey = "screenshot.preferences.v18"
    private static let legacyV17StorageKey = "screenshot.preferences.v17"
    private static let legacyV16StorageKey = "screenshot.preferences.v16"
    private static let legacyV15StorageKey = "screenshot.preferences.v15"
    private static let legacyV14StorageKey = "screenshot.preferences.v14"
    private static let legacyV13StorageKey = "screenshot.preferences.v13"
    private static var didScheduleStandardAssetCleanup = false

    @Published private(set) var preferences: ScreenshotPreferences
    let watermarkAssetStore: ScreenshotWatermarkAssetStore

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let commandTools = Set(ScreenshotPreferences.commandToolIDs)

    var isAutomaticHistoryOCREnabled: Bool {
        preferences.automaticallyRecognizesHistory
    }

    init(
        userDefaults: UserDefaults = .standard,
        watermarkAssetStore: ScreenshotWatermarkAssetStore = ScreenshotWatermarkAssetStore()
    ) {
        self.userDefaults = userDefaults
        self.watermarkAssetStore = watermarkAssetStore
        if let data = userDefaults.data(forKey: Self.storageKey),
           let decoded = try? decoder.decode(ScreenshotPreferences.self, from: data),
           decoded.version == ScreenshotPreferences.currentVersion {
            preferences = Self.normalized(decoded)
        } else if let data = userDefaults.data(forKey: Self.legacyV18StorageKey),
                  let migrated = try? decoder.decode(ScreenshotPreferences.self, from: data) {
            preferences = Self.normalized(migrated)
            persistMigration(removing: Self.legacyV18StorageKey)
        } else if let data = userDefaults.data(forKey: Self.legacyV17StorageKey),
                  let migrated = try? decoder.decode(ScreenshotPreferences.self, from: data) {
            preferences = Self.normalized(migrated)
            persistMigration(removing: Self.legacyV17StorageKey)
        } else if let data = userDefaults.data(forKey: Self.legacyV16StorageKey),
                  let migrated = try? decoder.decode(ScreenshotPreferences.self, from: data) {
            preferences = Self.normalized(migrated)
            persistMigration(removing: Self.legacyV16StorageKey)
        } else if let data = userDefaults.data(forKey: Self.legacyV15StorageKey),
                  let migrated = try? decoder.decode(ScreenshotPreferences.self, from: data) {
            preferences = Self.normalized(migrated)
            persistMigration(removing: Self.legacyV15StorageKey)
        } else if let data = userDefaults.data(forKey: Self.legacyV14StorageKey),
                  let migrated = try? decoder.decode(ScreenshotPreferences.self, from: data) {
            preferences = Self.normalized(migrated)
            persistMigration(removing: Self.legacyV14StorageKey)
        } else if let data = userDefaults.data(forKey: Self.legacyV13StorageKey),
                  let migrated = try? decoder.decode(ScreenshotPreferences.self, from: data) {
            preferences = Self.normalized(migrated)
            persistMigration(removing: Self.legacyV13StorageKey)
        } else {
            preferences = ScreenshotPreferences()
        }
        if userDefaults === UserDefaults.standard,
           !Self.didScheduleStandardAssetCleanup {
            Self.didScheduleStandardAssetCleanup = true
            let assetStore = watermarkAssetStore
            // A detached startup sweep must never delete an asset imported after
            // this preferences snapshot was taken. Files created concurrently are
            // left for the next launch if they do not become retained presets.
            let cleanupCutoff = Date().addingTimeInterval(-1)
            Task.detached(priority: .utility) {
                try? assetStore.cleanupOrphans(
                    retaining: [],
                    createdBefore: cleanupCutoff
                )
            }
        }
    }

    func update(_ mutation: (inout ScreenshotPreferences) -> Void) {
        var next = preferences
        mutation(&next)
        preferences = Self.normalized(next)
        persist()
    }

    @discardableResult
    func moveTool(
        _ tool: ScreenshotToolbarItemID,
        to zone: ScreenshotToolZone,
        before target: ScreenshotToolbarItemID?
    ) -> Bool {
        guard ScreenshotToolbarItemID.allCases.contains(tool),
              !Self.commandTools.contains(tool) else { return false }
        if target == tool { return self.zone(for: tool) == zone }

        let destinationTools = tools(in: zone).filter { $0 != tool }
        if let target, !destinationTools.contains(target) { return false }

        update { preferences in
            var toolOrder = preferences.toolOrder.filter { $0 != tool }
            let insertionIndex = target.flatMap(toolOrder.firstIndex(of:)) ?? toolOrder.endIndex
            toolOrder.insert(tool, at: insertionIndex)
            preferences.toolOrder = toolOrder

            preferences.quickToolIDs.removeAll { $0 == tool }
            preferences.hiddenToolIDs.removeAll { $0 == tool }
            switch zone {
            case .quick:
                preferences.quickToolIDs.append(tool)
            case .expanded:
                break
            case .hidden:
                preferences.hiddenToolIDs.append(tool)
            }
        }
        return true
    }

    func moveTool(_ tool: ScreenshotToolbarItemID, offset: Int) {
        guard ScreenshotToolbarItemID.allCases.contains(tool),
              !Self.commandTools.contains(tool), offset != 0 else { return }
        guard let zone = zone(for: tool) else { return }
        let zoneTools = tools(in: zone)
        guard let currentZoneIndex = zoneTools.firstIndex(of: tool) else { return }
        let targetZoneIndex = min(zoneTools.count - 1, max(0, currentZoneIndex + offset))
        guard targetZoneIndex != currentZoneIndex else { return }
        let remainingTools = zoneTools.filter { $0 != tool }
        let target = targetZoneIndex < remainingTools.count ? remainingTools[targetZoneIndex] : nil
        _ = moveTool(tool, to: zone, before: target)
    }

    @discardableResult
    func updateCaptureDefaultsFromSession(_ defaults: ScreenshotCaptureDefaults) -> Bool {
        guard !preferences.retainsCaptureDefaults else { return false }
        update {
            var sessionDefaults = defaults
            // The capture-toolbar watermark picker is a one-shot override. It
            // must never rewrite the globally configured default watermark.
            sessionDefaults.watermarkPresetID = $0.captureDefaults.watermarkPresetID
            $0.captureDefaults = sessionDefaults
        }
        return true
    }

    func resetCaptureDefaults() {
        let defaults = ScreenshotPreferences()
        update {
            $0.captureDefaults = defaults.captureDefaults
            $0.retainsCaptureDefaults = defaults.retainsCaptureDefaults
        }
    }

    func resetEditorDefaults() {
        let defaults = ScreenshotPreferences()
        update {
            $0.toolOrder = defaults.toolOrder
            $0.quickToolIDs = defaults.quickToolIDs
            $0.hiddenToolIDs = defaults.hiddenToolIDs
            $0.toolPresets = defaults.toolPresets
            $0.confirmsDiscardBeforeClosing = defaults.confirmsDiscardBeforeClosing
        }
    }

    func resetOutputDefaults() {
        let defaults = ScreenshotPreferences()
        update {
            $0.outputFormat = defaults.outputFormat
            $0.jpegQuality = defaults.jpegQuality
            $0.automaticallyRecognizesHistory = defaults.automaticallyRecognizesHistory
        }
    }

    func resetToolConfiguration() {
        let defaults = ScreenshotPreferences()
        update {
            $0.toolOrder = defaults.toolOrder
            $0.quickToolIDs = defaults.quickToolIDs
            $0.hiddenToolIDs = defaults.hiddenToolIDs
        }
    }

    func recordRecentColor(_ color: ScreenshotColor) {
        update { preferences in
            preferences.recordRecentColor(color)
        }
    }

    func saveCustomConstraint(_ constraint: ScreenshotRegionConstraint) {
        update { $0.saveCustomConstraint(constraint) }
    }

    func saveCustomConstraint(_ preset: ScreenshotCustomConstraintPreset) {
        update { $0.saveCustomConstraint(preset) }
    }

    func removeCustomConstraint(id: UUID) {
        update { $0.removeCustomConstraint(id: id) }
    }

    func saveWatermarkPreset(_ preset: ScreenshotWatermarkPreset) {
        update { $0.saveWatermarkPreset(preset) }
    }

    func removeWatermarkPreset(id: UUID) {
        update { $0.removeWatermarkPreset(id: id) }
    }

    private func zone(for tool: ScreenshotToolbarItemID) -> ScreenshotToolZone? {
        guard !Self.commandTools.contains(tool) else { return nil }
        if preferences.quickToolIDs.contains(tool) { return .quick }
        if preferences.hiddenToolIDs.contains(tool) { return .hidden }
        return .expanded
    }

    private func tools(in zone: ScreenshotToolZone) -> [ScreenshotToolbarItemID] {
        switch zone {
        case .quick: preferences.visibleQuickToolbarItemIDs
        case .expanded: preferences.visibleExtendedToolbarItemIDs
        case .hidden: preferences.hiddenToolIDs
        }
    }

    private static func normalized(_ value: ScreenshotPreferences) -> ScreenshotPreferences {
        var captureDefaults = value.captureDefaults
        captureDefaults.showsCursor = false
        return ScreenshotPreferences(
            toolOrder: value.toolOrder,
            quickToolIDs: value.quickToolIDs,
            hiddenToolIDs: value.hiddenToolIDs,
            toolPresets: value.toolPresets,
            recentColors: value.recentColors,
            customConstraints: value.customConstraints,
            watermarkPresets: value.watermarkPresets,
            captureDefaults: captureDefaults,
            retainsCaptureDefaults: value.retainsCaptureDefaults,
            confirmsDiscardBeforeClosing: value.confirmsDiscardBeforeClosing,
            automaticallyRecognizesHistory: value.automaticallyRecognizesHistory,
            outputFormat: value.outputFormat,
            jpegQuality: value.jpegQuality
        )
    }

    private func persist() {
        guard let data = try? encoder.encode(preferences) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private func persistMigration(removing legacyKey: String) {
        guard let migrated = try? encoder.encode(preferences) else { return }
        userDefaults.set(migrated, forKey: Self.storageKey)
        userDefaults.removeObject(forKey: legacyKey)
    }
}
