import AppKit
import BlocksScreenshotCore
import XCTest
@testable import Blocks

@MainActor
final class ScreenshotSettingsStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "ScreenshotSettingsStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testResetCaptureDefaultsPreservesEditorAndOutputSettings() {
        let store = makeCustomizedStore()

        store.resetCaptureDefaults()

        XCTAssertEqual(store.preferences.captureDefaults, ScreenshotCaptureDefaults())
        XCTAssertEqual(store.preferences.quickToolIDs, [.text, .arrow])
        XCTAssertEqual(store.preferences.outputFormat, .jpeg)
        XCTAssertEqual(store.preferences.jpegQuality, 0.72)
    }

    func testUnifiedEditorPreferencesUseCurrentVersionWithoutLegacyScreenshotTagSetting() {
        let preferences = ScreenshotPreferences()

        XCTAssertEqual(ScreenshotPreferences.currentVersion, 19)
        XCTAssertTrue(preferences.retainsCaptureDefaults)
        XCTAssertEqual(
            preferences.visibleQuickToolbarItemIDs,
            [.arrow, .rectangle, .text, .highlight, .pixelate]
        )
        XCTAssertFalse(preferences.visibleExtendedToolbarItemIDs.contains(.arrow))
        XCTAssertTrue(preferences.visibleExtendedToolbarItemIDs.contains(.ocr))
        XCTAssertTrue(preferences.visibleExtendedToolbarItemIDs.contains(.watermark))
        XCTAssertFalse(preferences.toolOrder.contains(.aspectRatio))
        XCTAssertEqual(Set(preferences.toolPresets.keys), Set(ScreenshotEditorTool.allCases))
        XCTAssertEqual(preferences.toolPresets[.arrow]?.appearance.endEnding, .filledArrow)
        XCTAssertFalse(preferences.automaticallyRecognizesHistory)
        XCTAssertTrue(preferences.confirmsDiscardBeforeClosing)
    }

    func testToolStripOverflowUsesIntrinsicContentWidth() {
        XCTAssertEqual(ScreenshotToolStripMetrics.intrinsicContentWidth(toolCount: 0), 248)
        XCTAssertEqual(ScreenshotToolStripMetrics.intrinsicContentWidth(toolCount: 13), 584)
        XCTAssertEqual(ScreenshotToolStripMetrics.intrinsicContentWidth(toolCount: 17), 752)
        XCTAssertFalse(ScreenshotToolStripMetrics.overflows(toolCount: 13, viewportWidth: 600))
        XCTAssertTrue(ScreenshotToolStripMetrics.overflows(toolCount: 17, viewportWidth: 600))
        XCTAssertEqual(ScreenshotToolStripMetrics.visibleToolCount(viewportWidth: 600), 13)
        XCTAssertEqual(
            ScreenshotToolStripMetrics.maximumFirstVisibleIndex(toolCount: 17, viewportWidth: 600),
            4
        )
    }

    func testAutomaticHistoryOCRChoicePersistsIndependently() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)

        store.update { $0.automaticallyRecognizesHistory = true }

        XCTAssertTrue(store.preferences.automaticallyRecognizesHistory)
        XCTAssertTrue(store.isAutomaticHistoryOCREnabled)
    }

    func testFeatureAvailabilityDefaultsEnabledAndPersistsEachFeatureIndependently() {
        let first = FeatureAvailabilityStore(defaults: defaults)

        XCTAssertTrue(first.screenshotEnabled)
        XCTAssertTrue(first.clipboardEnabled)

        first.setScreenshotEnabled(false)
        XCTAssertFalse(first.screenshotEnabled)
        XCTAssertTrue(first.clipboardEnabled)

        let second = FeatureAvailabilityStore(defaults: defaults)
        XCTAssertFalse(second.screenshotEnabled)
        XCTAssertTrue(second.clipboardEnabled)

        second.setClipboardEnabled(false)
        let third = FeatureAvailabilityStore(defaults: defaults)
        XCTAssertFalse(third.screenshotEnabled)
        XCTAssertFalse(third.clipboardEnabled)
    }

    func testResetEditorDefaultsPreservesCaptureAndOutputSettings() {
        let store = makeCustomizedStore()

        store.resetEditorDefaults()

        XCTAssertEqual(store.preferences.toolOrder, ScreenshotToolbarItemID.allCases)
        XCTAssertEqual(store.preferences.quickToolIDs, ScreenshotPreferences.defaultQuickTools)
        XCTAssertEqual(store.preferences.hiddenToolIDs, [])
        XCTAssertEqual(store.preferences.captureDefaults.delaySeconds, 5)
        XCTAssertEqual(store.preferences.outputFormat, .jpeg)
        XCTAssertTrue(store.preferences.confirmsDiscardBeforeClosing)
    }

    func testVersion13PreferencesMigrateOnceAndPreserveExistingChoices() throws {
        let legacyKey = "screenshot.preferences.v13"
        var legacy = ScreenshotPreferences()
        legacy.captureDefaults = ScreenshotCaptureDefaults(
            delaySeconds: 5,
            freezesFrame: true,
            regionConstraint: .ratio(width: 16, height: 9)
        )
        legacy.quickToolIDs = [.arrow, .text]
        legacy.outputFormat = .jpeg
        legacy.jpegQuality = 0.73
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object["version"] = 13
        object["addsScreenshotTag"] = true
        object["toolOrder"] = ["select", "crop", "text", "arrow", "ocr"]
        object["quickToolIDs"] = ["text", "arrow"]
        object["hiddenToolIDs"] = ["ocr"]
        object["toolPresets"] = []
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: legacyKey)

        let migrated = ScreenshotPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(migrated.preferences.version, 19)
        XCTAssertEqual(migrated.preferences.captureDefaults.delaySeconds, 5)
        XCTAssertEqual(migrated.preferences.quickToolIDs, [.text, .arrow])
        XCTAssertEqual(Array(migrated.preferences.toolOrder.prefix(2)), [.select, .text])
        XCTAssertFalse(migrated.preferences.toolOrder.contains(.aspectRatio))
        XCTAssertTrue(migrated.preferences.visibleExtendedToolbarItemIDs.contains(.watermark))
        XCTAssertTrue(migrated.preferences.toolOrder.contains(.step))
        XCTAssertEqual(migrated.preferences.outputFormat, .jpeg)
        XCTAssertEqual(migrated.preferences.jpegQuality, 0.73)
        XCTAssertTrue(migrated.preferences.confirmsDiscardBeforeClosing)
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertNotNil(defaults.data(forKey: ScreenshotPreferencesStore.storageKey))
    }

    func testVersion14PreferencesMigrateToV19AndRemoveLegacyStorage() throws {
        let legacyKey = "screenshot.preferences.v14"
        let legacy = ScreenshotPreferences(
            captureDefaults: .init(delaySeconds: 3, freezesFrame: true)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object["version"] = 14
        object["addsScreenshotTag"] = true
        object.removeValue(forKey: "customConstraints")
        var capture = try XCTUnwrap(object["captureDefaults"] as? [String: Any])
        capture["includesWindowShadow"] = true
        object["captureDefaults"] = capture
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: legacyKey)

        let migrated = ScreenshotPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(migrated.preferences.version, 19)
        XCTAssertEqual(migrated.preferences.captureDefaults.delaySeconds, 3)
        XCTAssertTrue(migrated.preferences.captureDefaults.freezesFrame)
        XCTAssertEqual(migrated.preferences.customConstraints, [])
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertNotNil(defaults.data(forKey: ScreenshotPreferencesStore.storageKey))
    }

    func testVersion15PreferencesMigrateToV19AndRemoveAspectFromConfigurableTools() throws {
        let legacyKey = "screenshot.preferences.v15"
        let saved = ScreenshotCustomConstraintPreset(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            constraint: .fixedPixels(width: 1_280, height: 720)
        )
        let legacy = ScreenshotPreferences(
            quickToolIDs: [.arrow, .rectangle, .text, .highlight, .pixelate],
            hiddenToolIDs: [.blur],
            customConstraints: [saved]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object["version"] = 15
        object["addsScreenshotTag"] = false
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: legacyKey)

        let migrated = ScreenshotPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(migrated.preferences.version, 19)
        XCTAssertEqual(
            migrated.preferences.quickToolIDs,
            [.arrow, .rectangle, .text, .highlight, .pixelate]
        )
        XCTAssertEqual(migrated.preferences.hiddenToolIDs, [.blur])
        XCTAssertEqual(migrated.preferences.customConstraints, [saved])
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertNotNil(defaults.data(forKey: ScreenshotPreferencesStore.storageKey))
    }

    func testVersion16PreferencesMigrateToV19AndDropOnlyTheLegacyLineTool() throws {
        let legacyKey = "screenshot.preferences.v16"
        var legacy = ScreenshotPreferences(
            toolOrder: [.select, .line, .arrow, .rectangle, .text],
            quickToolIDs: [.line, .arrow],
            hiddenToolIDs: [.rectangle]
        )
        var arrowAppearance = ScreenshotElementAppearance()
        arrowAppearance.lineWidth = 7
        legacy.toolPresets[.arrow] = ScreenshotToolPreset(
            tool: .arrow,
            appearance: arrowAppearance
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object["version"] = 16
        object["addsScreenshotTag"] = false
        object["toolOrder"] = ["select", "line", "arrow", "rectangle", "text"]
        object["quickToolIDs"] = ["line", "arrow"]
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: legacyKey)

        let migrated = ScreenshotPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(migrated.preferences.version, 19)
        XCTAssertFalse(migrated.preferences.toolOrder.contains(.line))
        XCTAssertEqual(migrated.preferences.visibleQuickToolbarItemIDs, [.arrow])
        XCTAssertEqual(migrated.preferences.hiddenToolIDs, [.rectangle])
        XCTAssertEqual(migrated.preferences.toolPresets[.arrow]?.appearance.lineWidth, 7)
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertNotNil(defaults.data(forKey: ScreenshotPreferencesStore.storageKey))
    }

    func testVersion17PreferencesMigrateToV19WithFixedSizeCommandAndWatermarkInMore() throws {
        let legacyKey = "screenshot.preferences.v17"
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ScreenshotPreferences()))
                as? [String: Any]
        )
        object["version"] = 17
        object["addsScreenshotTag"] = false
        object["toolOrder"] = ["select", "aspectRatio", "arrow", "text", "ocr"]
        object["quickToolIDs"] = ["aspectRatio", "arrow", "text"]
        object["hiddenToolIDs"] = ["ocr"]
        object.removeValue(forKey: "watermarkPresets")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: legacyKey)

        let migrated = ScreenshotPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(migrated.preferences.version, 19)
        XCTAssertEqual(migrated.preferences.visibleQuickToolbarItemIDs, [.arrow, .text])
        XCTAssertFalse(migrated.preferences.toolOrder.contains(.aspectRatio))
        XCTAssertTrue(migrated.preferences.visibleExtendedToolbarItemIDs.contains(.watermark))
        XCTAssertEqual(migrated.preferences.watermarkPresets, [])
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertNotNil(defaults.data(forKey: ScreenshotPreferencesStore.storageKey))
    }

    func testCustomConstraintsPersistThroughStore() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let stableID = UUID()

        store.saveCustomConstraint(.ratio(width: 16, height: 9))
        store.saveCustomConstraint(ScreenshotCustomConstraintPreset(
            id: stableID,
            constraint: .fixedPixels(width: 800, height: 1_200)
        ))
        let restored = ScreenshotPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(restored.preferences.customConstraints.map(\.constraint), [
            .fixedPixels(width: 1_200, height: 800),
            .ratio(width: 16, height: 9),
        ])
        XCTAssertEqual(restored.preferences.customConstraints[0].id, stableID)
        restored.removeCustomConstraint(id: stableID)
        XCTAssertFalse(restored.preferences.customConstraints.contains { $0.id == stableID })
    }

    func testResetOutputDefaultsPreservesCaptureAndEditorSettings() {
        let store = makeCustomizedStore()

        store.resetOutputDefaults()

        XCTAssertEqual(store.preferences.outputFormat, .png)
        XCTAssertEqual(store.preferences.jpegQuality, 0.9)
        XCTAssertEqual(store.preferences.captureDefaults.delaySeconds, 5)
        XCTAssertEqual(store.preferences.quickToolIDs, [.text, .arrow])
    }

    func testResetToolConfigurationRestoresOnlyOrderAndZones() {
        let store = makeCustomizedStore()
        var customStyle = ScreenshotElementAppearance()
        customStyle.lineWidth = 7
        store.update { $0.toolPresets[.arrow] = ScreenshotToolPreset(tool: .arrow, appearance: customStyle) }

        store.resetToolConfiguration()

        XCTAssertEqual(store.preferences.toolOrder, ScreenshotToolbarItemID.allCases)
        XCTAssertEqual(store.preferences.quickToolIDs, ScreenshotPreferences.defaultQuickTools)
        XCTAssertEqual(store.preferences.hiddenToolIDs, [])
        XCTAssertEqual(store.preferences.toolPresets[.arrow]?.appearance, customStyle)
    }

    func testQuickZoneAcceptsEveryMovableToolWithoutALimit() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let movableTools = ScreenshotToolbarItemID.allCases.filter { $0 != .select }

        for tool in movableTools {
            XCTAssertTrue(store.moveTool(tool, to: .quick, before: nil))
        }

        XCTAssertEqual(store.preferences.quickToolIDs, movableTools)
        XCTAssertEqual(store.preferences.visibleExtendedToolbarItemIDs, [])
        XCTAssertEqual(store.preferences.hiddenToolIDs, [])

        let restored = ScreenshotPreferencesStore(userDefaults: defaults)
        XCTAssertEqual(restored.preferences.quickToolIDs, movableTools)
        XCTAssertEqual(restored.preferences.visibleExtendedToolbarItemIDs, [])
    }

    func testAtomicMoveChangesZoneAndSharedOrderTogether() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)

        XCTAssertTrue(store.moveTool(.text, to: .expanded, before: .ellipse))
        XCTAssertFalse(store.preferences.visibleQuickToolbarItemIDs.contains(.text))
        XCTAssertEqual(store.preferences.visibleExtendedToolbarItemIDs.first, .text)

        XCTAssertTrue(store.moveTool(.text, to: .hidden, before: nil))
        XCTAssertTrue(store.preferences.hiddenToolIDs.contains(.text))
        XCTAssertFalse(store.preferences.visibleExtendedToolbarItemIDs.contains(.text))

        let restored = ScreenshotPreferencesStore(userDefaults: defaults)
        XCTAssertTrue(restored.preferences.hiddenToolIDs.contains(.text))
        XCTAssertFalse(restored.preferences.visibleQuickToolbarItemIDs.contains(.text))
        XCTAssertFalse(restored.preferences.visibleExtendedToolbarItemIDs.contains(.text))
    }

    func testAtomicMoveRejectsATargetOutsideTheDestinationWithoutPartialMutation() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let before = store.preferences

        XCTAssertFalse(store.moveTool(.text, to: .hidden, before: .arrow))

        XCTAssertEqual(store.preferences, before)
        XCTAssertEqual(ScreenshotPreferencesStore(userDefaults: defaults).preferences, before)
    }

    func testKeyboardReorderMovesToTheAdjacentToolInsideTheCurrentZone() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let expandedBefore = store.preferences.visibleExtendedToolbarItemIDs

        store.moveTool(.rectangle, offset: -1)

        XCTAssertEqual(
            Array(store.preferences.visibleQuickToolbarItemIDs.prefix(3)),
            [.rectangle, .arrow, .text]
        )
        XCTAssertEqual(store.preferences.visibleExtendedToolbarItemIDs, expandedBefore)
    }

    func testDropPlacementReordersInsideQuickZoneAtAnExactInsertionPoint() throws {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let before = store.preferences.visibleQuickToolbarItemIDs
        let dragged = try XCTUnwrap(before.first)
        let insertionIndex = min(4, before.count)
        let target = ScreenshotToolDragPlacement.target(
            for: dragged,
            in: before,
            insertionIndex: insertionIndex
        )

        XCTAssertTrue(store.moveTool(dragged, to: .quick, before: target))

        var expected = before
        expected.removeAll { $0 == dragged }
        expected.insert(dragged, at: insertionIndex - 1)
        XCTAssertEqual(store.preferences.visibleQuickToolbarItemIDs, expected)
    }

    func testDropPlacementReordersInsideMoreZoneAtTheBeginningAndEnd() throws {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let before = store.preferences.visibleExtendedToolbarItemIDs
        let last = try XCTUnwrap(before.last)

        let firstTarget = ScreenshotToolDragPlacement.target(
            for: last,
            in: before,
            insertionIndex: 0
        )
        XCTAssertTrue(store.moveTool(last, to: .expanded, before: firstTarget))
        XCTAssertEqual(store.preferences.visibleExtendedToolbarItemIDs.first, last)

        let reordered = store.preferences.visibleExtendedToolbarItemIDs
        let endTarget = ScreenshotToolDragPlacement.target(
            for: last,
            in: reordered,
            insertionIndex: reordered.count
        )
        XCTAssertTrue(store.moveTool(last, to: .expanded, before: endTarget))
        XCTAssertEqual(store.preferences.visibleExtendedToolbarItemIDs.last, last)
    }

    func testPointerDragResolutionExcludesTheSourceAndDetectsNoOpPositions() {
        let tools: [ScreenshotToolbarItemID] = [.arrow, .rectangle, .text, .ellipse]

        XCTAssertEqual(
            ScreenshotToolDragPlacement.reorderedTools(
                moving: .ellipse,
                in: tools,
                insertionIndex: 0
            ),
            [.ellipse, .arrow, .rectangle, .text]
        )
        XCTAssertEqual(
            ScreenshotToolDragPlacement.reorderedTools(
                moving: .arrow,
                in: tools,
                insertionIndex: tools.count
            ),
            [.rectangle, .text, .ellipse, .arrow]
        )
        XCTAssertTrue(ScreenshotToolDragPlacement.isNoOp(
            moving: .rectangle,
            from: .quick,
            to: .quick,
            destinationTools: tools,
            insertionIndex: 1
        ))
        XCTAssertFalse(ScreenshotToolDragPlacement.isNoOp(
            moving: .rectangle,
            from: .quick,
            to: .expanded,
            destinationTools: tools,
            insertionIndex: 1
        ))
    }

    func testPointerDragIntentResolvesSameZoneAndCrossZoneTargets() throws {
        let quickTools: [ScreenshotToolbarItemID] = [.arrow, .rectangle, .text, .ellipse]
        let sameZonePayload = ScreenshotToolDragPlacement.Payload(
            tool: .rectangle,
            sourceZone: .quick,
            sourceIndex: 1
        )

        XCTAssertEqual(
            try XCTUnwrap(ScreenshotToolDragPlacement.intent(
                for: sameZonePayload,
                destinationZone: .quick,
                destinationTools: quickTools,
                insertionIndex: 3
            )),
            ScreenshotToolDropIntent(
                tool: .rectangle,
                destinationZone: .quick,
                beforeTool: .ellipse
            )
        )

        let crossZonePayload = ScreenshotToolDragPlacement.Payload(
            tool: .text,
            sourceZone: .quick,
            sourceIndex: 2
        )
        XCTAssertEqual(
            try XCTUnwrap(ScreenshotToolDragPlacement.intent(
                for: crossZonePayload,
                destinationZone: .expanded,
                destinationTools: [.arrow, .ellipse],
                insertionIndex: 1
            )),
            ScreenshotToolDropIntent(
                tool: .text,
                destinationZone: .expanded,
                beforeTool: .ellipse
            )
        )
    }

    func testPointerDragNoOpAndCancelledIntentDoNotMutatePreferences() throws {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let snapshot = store.preferences
        let quickTools = snapshot.visibleQuickToolbarItemIDs
        let dragged = try XCTUnwrap(quickTools.first)
        let payload = ScreenshotToolDragPlacement.Payload(
            tool: dragged,
            sourceZone: .quick,
            sourceIndex: 0
        )

        XCTAssertNil(ScreenshotToolDragPlacement.intent(
            for: payload,
            destinationZone: .quick,
            destinationTools: quickTools,
            insertionIndex: 0
        ))

        let cancelledIntent = ScreenshotToolDragPlacement.intent(
            for: payload,
            destinationZone: .expanded,
            destinationTools: snapshot.visibleExtendedToolbarItemIDs,
            insertionIndex: 0
        )
        XCTAssertNotNil(cancelledIntent)
        XCTAssertEqual(store.preferences, snapshot)
        XCTAssertEqual(ScreenshotPreferencesStore(userDefaults: defaults).preferences, snapshot)
    }

    func testPointerDragInsertionIndexUsesToolMidpointsIncludingEmptyAndTailSlots() {
        XCTAssertEqual(ScreenshotToolDragPlacement.insertionIndex(atX: 20, toolCount: 0), 0)
        XCTAssertEqual(ScreenshotToolDragPlacement.insertionIndex(atX: 8, toolCount: 3), 0)
        XCTAssertEqual(ScreenshotToolDragPlacement.insertionIndex(atX: 31, toolCount: 3), 1)
        XCTAssertEqual(ScreenshotToolDragPlacement.insertionIndex(atX: 200, toolCount: 3), 3)
    }

    func testOCRCommandMovesBetweenExpandedQuickAndLibraryWithoutAStyleInspector() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)

        XCTAssertTrue(store.preferences.visibleExtendedToolbarItemIDs.contains(.ocr))
        XCTAssertFalse(store.preferences.visibleQuickToolbarItemIDs.contains(.ocr))

        XCTAssertTrue(store.moveTool(.pixelate, to: .expanded, before: nil))
        XCTAssertTrue(store.moveTool(.ocr, to: .quick, before: nil))
        XCTAssertTrue(store.preferences.visibleQuickToolbarItemIDs.contains(.ocr))

        XCTAssertTrue(store.moveTool(.ocr, to: .hidden, before: nil))
        XCTAssertTrue(store.preferences.hiddenToolIDs.contains(.ocr))
        XCTAssertFalse(store.preferences.visibleExtendedToolbarItemIDs.contains(.ocr))
        XCTAssertNil(ScreenshotToolbarItemID.ocr.editorTool)
        XCTAssertEqual(Set(store.preferences.toolPresets.keys), Set(ScreenshotEditorTool.allCases))
    }

    func testSelectAndAspectAreFixedWhileWatermarkCanMoveAcrossAllThreeZones() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)

        XCTAssertFalse(store.moveTool(.select, to: .hidden, before: nil))
        XCTAssertEqual(store.preferences.toolOrder.first, .select)
        XCTAssertFalse(store.moveTool(.aspectRatio, to: .hidden, before: nil))
        XCTAssertFalse(store.preferences.toolOrder.contains(.aspectRatio))

        XCTAssertTrue(store.moveTool(.watermark, to: .hidden, before: nil))
        XCTAssertTrue(store.preferences.hiddenToolIDs.contains(.watermark))
        XCTAssertTrue(store.moveTool(.watermark, to: .quick, before: .arrow))

        XCTAssertTrue(store.preferences.quickToolIDs.contains(.watermark))
        XCTAssertLessThan(
            store.preferences.toolOrder.firstIndex(of: .watermark)!,
            store.preferences.toolOrder.firstIndex(of: .arrow)!
        )
    }

    func testSessionCaptureChangesRespectRetentionPolicy() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let sessionDefaults = ScreenshotCaptureDefaults(delaySeconds: 5)

        XCTAssertFalse(store.updateCaptureDefaultsFromSession(sessionDefaults))
        XCTAssertEqual(store.preferences.captureDefaults, ScreenshotCaptureDefaults())

        store.update { $0.retainsCaptureDefaults = false }
        XCTAssertTrue(store.updateCaptureDefaultsFromSession(sessionDefaults))
        XCTAssertEqual(store.preferences.captureDefaults, sessionDefaults)
    }

    func testSessionCaptureWatermarkOverrideNeverRewritesGlobalDefault() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let preset = ScreenshotWatermarkPreset(
            name: "Default",
            style: ScreenshotWatermarkStyle(text: "Blocks")
        )
        store.saveWatermarkPreset(preset)
        store.update {
            $0.captureDefaults.watermarkPresetID = preset.id
            $0.retainsCaptureDefaults = false
        }

        XCTAssertTrue(store.updateCaptureDefaultsFromSession(
            ScreenshotCaptureDefaults(delaySeconds: 5, watermarkPresetID: nil)
        ))
        XCTAssertEqual(store.preferences.captureDefaults.delaySeconds, 5)
        XCTAssertEqual(store.preferences.captureDefaults.watermarkPresetID, preset.id)
    }

    func testWatermarkDeletionConfirmationOnlyMutatesAfterConfirm() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let preset = ScreenshotWatermarkPreset(
            name: "Default",
            style: ScreenshotWatermarkStyle(text: "Blocks")
        )
        store.saveWatermarkPreset(preset)
        store.update { $0.captureDefaults.watermarkPresetID = preset.id }
        let before = store.preferences
        var confirmation = ScreenshotWatermarkConfirmationState()

        confirmation.requestDelete(id: preset.id)
        XCTAssertEqual(confirmation.pendingAction, .delete(preset.id))
        XCTAssertEqual(store.preferences, before)

        confirmation.cancel()
        XCTAssertNil(confirmation.pendingAction)
        XCTAssertEqual(store.preferences, before)

        confirmation.requestDelete(id: preset.id)
        confirmation.confirm(using: store)

        XCTAssertNil(confirmation.pendingAction)
        XCTAssertTrue(store.preferences.watermarkPresets.isEmpty)
        XCTAssertNil(store.preferences.captureDefaults.watermarkPresetID)
    }

    func testWatermarkResetConfirmationOnlyMutatesAfterConfirm() {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        let first = ScreenshotWatermarkPreset(
            name: "First",
            style: ScreenshotWatermarkStyle(text: "Blocks")
        )
        let second = ScreenshotWatermarkPreset(
            name: "Second",
            style: ScreenshotWatermarkStyle(text: "Watermark")
        )
        store.saveWatermarkPreset(first)
        store.saveWatermarkPreset(second)
        store.update { $0.captureDefaults.watermarkPresetID = first.id }
        let before = store.preferences
        var confirmation = ScreenshotWatermarkConfirmationState()

        confirmation.requestReset()
        XCTAssertEqual(confirmation.pendingAction, .resetAll)
        XCTAssertEqual(store.preferences, before)

        confirmation.cancel()
        XCTAssertNil(confirmation.pendingAction)
        XCTAssertEqual(store.preferences, before)

        confirmation.requestReset()
        confirmation.confirm(using: store)

        XCTAssertNil(confirmation.pendingAction)
        XCTAssertTrue(store.preferences.watermarkPresets.isEmpty)
        XCTAssertNil(store.preferences.captureDefaults.watermarkPresetID)
    }

    func testToolZonesBoardUsesOnePointerCoordinatorForAllZones() {
        let board = ScreenshotToolZonesBoardView(frame: NSRect(x: 0, y: 0, width: 620, height: 268))

        XCTAssertEqual(board.configuredCollectionZones, [.quick, .expanded, .hidden])
        XCTAssertTrue(board.registeredDraggedTypes.isEmpty)
    }

    func testToolZonesBoardFreezesItsSnapshotUntilThePointerDragEnds() {
        let board = ScreenshotToolZonesBoardView(frame: NSRect(x: 0, y: 0, width: 620, height: 268))
        let initial = ScreenshotToolZonesSnapshot(
            quick: [.arrow, .rectangle],
            expanded: [.text],
            hidden: [.ellipse]
        )
        let pending = ScreenshotToolZonesSnapshot(
            quick: [.rectangle, .arrow],
            expanded: [.text, .ellipse],
            hidden: []
        )
        board.update(snapshot: initial, tooltipHost: nil)
        board.layoutSubtreeIfNeeded()
        board.beginPointerDrag(ScreenshotToolDragPlacement.Payload(
            tool: .arrow,
            sourceZone: .quick,
            sourceIndex: 0
        ))
        board.update(snapshot: pending, tooltipHost: nil)

        XCTAssertEqual(board.tools(in: .quick), initial.quick)
        XCTAssertEqual(board.tools(in: .expanded), initial.expanded)

        XCTAssertEqual(
            board.completePointerDrag(atBoardPoint: CGPoint(x: 12, y: 132)),
            ScreenshotToolDropIntent(
                tool: .arrow,
                destinationZone: .expanded,
                beforeTool: .text
            )
        )
        XCTAssertEqual(board.tools(in: .quick), pending.quick)
        XCTAssertEqual(board.tools(in: .expanded), pending.expanded)
    }

    func testToolZonesBoardCancelledDragDoesNotProduceAnIntent() {
        let board = ScreenshotToolZonesBoardView(frame: NSRect(x: 0, y: 0, width: 620, height: 268))
        board.update(
            snapshot: ScreenshotToolZonesSnapshot(
                quick: [.arrow],
                expanded: [.text],
                hidden: []
            ),
            tooltipHost: nil
        )
        board.beginPointerDrag(ScreenshotToolDragPlacement.Payload(
            tool: .arrow,
            sourceZone: .quick,
            sourceIndex: 0
        ))
        board.cancelPointerDrag()
        XCTAssertFalse(board.dragIsActive)
    }

    func testToolZonesBoardRejectsAnInvalidPointerPayloadWithoutMutation() {
        let board = ScreenshotToolZonesBoardView(frame: NSRect(x: 0, y: 0, width: 620, height: 268))
        board.update(
            snapshot: ScreenshotToolZonesSnapshot(
                quick: [.arrow],
                expanded: [.text],
                hidden: []
            ),
            tooltipHost: nil
        )
        board.layoutSubtreeIfNeeded()
        board.beginPointerDrag(ScreenshotToolDragPlacement.Payload(
            tool: .text,
            sourceZone: .quick,
            sourceIndex: 0
        ))

        XCTAssertNil(board.completePointerDrag(atBoardPoint: CGPoint(x: 12, y: 132)))
        XCTAssertFalse(board.dragIsActive)
        XCTAssertEqual(board.tools(in: .quick), [.arrow])
    }


    private func makeCustomizedStore() -> ScreenshotPreferencesStore {
        let store = ScreenshotPreferencesStore(userDefaults: defaults)
        store.update {
            $0.captureDefaults = ScreenshotCaptureDefaults(
                delaySeconds: 5,
                showsCursor: true,
                freezesFrame: true,
                regionConstraint: .ratio(width: 16, height: 9)
            )
            $0.toolOrder = [.select, .text, .arrow]
            $0.quickToolIDs = [.text, .arrow]
            $0.hiddenToolIDs = [.ellipse]
            $0.confirmsDiscardBeforeClosing = false
            $0.automaticallyRecognizesHistory = true
            $0.outputFormat = .jpeg
            $0.jpegQuality = 0.72
        }
        return store
    }
}
