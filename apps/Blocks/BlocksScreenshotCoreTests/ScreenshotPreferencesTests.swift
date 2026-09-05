import XCTest
@testable import BlocksScreenshotCore

final class ScreenshotPreferencesTests: XCTestCase {
    func testTypedLineAppearanceDecodesMissingFutureFieldsWithDefaults() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "color": ["red": 1.0, "green": 0.2, "blue": 0.1, "alpha": 1.0],
            "width": 4.0,
            "opacity": 0.8,
            "startEnding": "none",
            "endEnding": "filledArrow",
            "pattern": "solid",
        ])

        let appearance = try JSONDecoder().decode(ScreenshotLineAppearance.self, from: data)

        XCTAssertEqual(appearance.width, 4)
        XCTAssertEqual(appearance.curvature, 0)
        XCTAssertEqual(appearance.arrowHeadSize, 1)
    }

    func testTypedShapeAppearanceDecodesMissingFillOpacityWithDefault() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "strokeColor": ["red": 1.0, "green": 0.2, "blue": 0.1, "alpha": 1.0],
            "strokeWidth": 3.0,
            "opacity": 1.0,
            "cornerRadius": 8.0,
        ])

        let appearance = try JSONDecoder().decode(ScreenshotShapeAppearance.self, from: data)

        XCTAssertNil(appearance.fillColor)
        XCTAssertEqual(appearance.fillOpacity, 0.16)
    }
    func testProfessionalToolPackUsesTypedPresets() {
        let preferences = ScreenshotPreferences()
        let professionalTools: [ScreenshotEditorTool] = [
            .counter, .step, .callout, .spotlight, .redact, .magnifier,
        ]

        XCTAssertEqual(preferences.version, 19)
        XCTAssertTrue(professionalTools.allSatisfy(ScreenshotEditorTool.allCases.contains))
        XCTAssertTrue(professionalTools.allSatisfy { preferences.toolPresets[$0]?.tool == $0 })
        XCTAssertEqual(preferences.toolPresets[.counter]?.appearance.payload.kind, .counter)
        XCTAssertEqual(preferences.toolPresets[.step]?.appearance.payload.kind, .step)
        XCTAssertEqual(preferences.toolPresets[.callout]?.appearance.payload.kind, .callout)
        XCTAssertEqual(preferences.toolPresets[.spotlight]?.appearance.payload.kind, .spotlight)
        XCTAssertEqual(preferences.toolPresets[.redact]?.appearance.payload.kind, .redact)
        XCTAssertEqual(preferences.toolPresets[.magnifier]?.appearance.payload.kind, .magnifier)
        XCTAssertTrue(professionalTools.allSatisfy {
            preferences.extendedToolIDs.contains($0.toolbarItemID)
        })
    }

    func testDefaultsUseV19CommandQuickExpandedAndHiddenZones() {
        let preferences = ScreenshotPreferences()

        XCTAssertEqual(preferences.version, 19)
        XCTAssertEqual(preferences.toolOrder, ScreenshotToolbarItemID.allCases)
        XCTAssertEqual(ScreenshotPreferences.commandToolIDs, [.select])
        XCTAssertEqual(
            ScreenshotPreferences.defaultQuickTools,
            [.arrow, .rectangle, .text, .highlight, .pixelate]
        )
        XCTAssertEqual(
            preferences.quickToolIDs,
            [.arrow, .rectangle, .text, .highlight, .pixelate]
        )
        XCTAssertEqual(preferences.hiddenToolIDs, [])
        XCTAssertEqual(
            preferences.extendedToolIDs,
            [.ellipse, .freehand, .blur, .counter, .step, .callout, .spotlight, .redact, .magnifier, .watermark, .ocr]
        )
        XCTAssertEqual(
            Set(ScreenshotPreferences.commandToolIDs
                + preferences.visibleQuickToolbarItemIDs
                + preferences.visibleExtendedToolbarItemIDs
                + preferences.hiddenToolIDs),
            Set(ScreenshotToolbarItemID.allCases)
        )
        XCTAssertTrue(preferences.retainsCaptureDefaults)
        XCTAssertFalse(preferences.automaticallyRecognizesHistory)
        XCTAssertTrue(preferences.confirmsDiscardBeforeClosing)
        XCTAssertEqual(preferences.outputFormat, .png)
        XCTAssertEqual(preferences.captureDefaults.regionConstraint, .free)
        XCTAssertEqual(preferences.recentColors, [])
        XCTAssertEqual(preferences.customConstraints, [])
        XCTAssertEqual(preferences.watermarkPresets, [])
    }

    func testToolbarItemIDsMapEditorToolsAndLeaveOCRAsACommand() {
        XCTAssertEqual(ScreenshotToolbarItemID.allCases.count, ScreenshotEditorTool.allCases.count + 1)

        for tool in ScreenshotEditorTool.allCases {
            let itemID = ScreenshotToolbarItemID(editorTool: tool)
            XCTAssertEqual(itemID.editorTool, tool)
            XCTAssertEqual(tool.toolbarItemID, itemID)
        }

        XCTAssertNil(ScreenshotToolbarItemID.ocr.editorTool)
        XCTAssertNil(ScreenshotToolbarItemID.aspectRatio.editorTool)
    }

    func testToolConfigurationPinsOnlySelectAndNormalizesThreeMovableZones() {
        let preferences = ScreenshotPreferences(
            toolOrder: [.blur, .aspectRatio, .select, .arrow, .blur],
            quickToolIDs: [
                .select, .aspectRatio, .text, .freehand, .ellipse, .rectangle, .arrow, .blur, .highlight,
            ],
            hiddenToolIDs: [.select, .aspectRatio, .line, .line]
        )

        XCTAssertEqual(
            preferences.toolOrder,
            [
                .select, .blur, .arrow, .rectangle, .ellipse, .freehand, .text,
                .highlight, .pixelate, .counter, .step, .callout, .spotlight, .redact, .magnifier,
                .watermark, .ocr,
            ]
        )
        XCTAssertEqual(
            preferences.quickToolIDs,
            [.blur, .arrow, .rectangle, .ellipse, .freehand, .text, .highlight]
        )
        XCTAssertEqual(preferences.hiddenToolIDs, [])
        XCTAssertEqual(
            preferences.extendedToolIDs,
            [.pixelate, .counter, .step, .callout, .spotlight, .redact, .magnifier, .watermark, .ocr]
        )
    }

    func testQuickZonePreservesEveryRequestedMovableToolWithoutALimit() {
        let requested = ScreenshotToolbarItemID.allCases.filter { $0 != .select }

        let preferences = ScreenshotPreferences(quickToolIDs: requested)

        XCTAssertEqual(preferences.quickToolIDs, requested)
        XCTAssertEqual(preferences.extendedToolIDs, [])
        XCTAssertEqual(preferences.hiddenToolIDs, [])
    }

    func testOCRCanMoveToQuickOrHiddenWithoutCreatingAStyleEntry() {
        let quick = ScreenshotPreferences(quickToolIDs: [.ocr, .arrow])
        XCTAssertEqual(quick.quickToolIDs, [.arrow, .ocr])
        XCTAssertFalse(quick.extendedToolIDs.contains(.ocr))

        let hidden = ScreenshotPreferences(
            quickToolIDs: [.ocr, .arrow],
            hiddenToolIDs: [.ocr]
        )
        XCTAssertEqual(hidden.quickToolIDs, [.arrow])
        XCTAssertEqual(hidden.hiddenToolIDs, [.ocr])
        XCTAssertNil(ScreenshotToolbarItemID.ocr.editorTool)
        XCTAssertEqual(Set(hidden.toolPresets.keys), Set(ScreenshotEditorTool.allCases))
    }

    func testHiddenToolsTakePrecedenceOverQuickTools() {
        let preferences = ScreenshotPreferences(
            quickToolIDs: [.arrow, .rectangle, .text],
            hiddenToolIDs: [.rectangle, .blur]
        )

        XCTAssertEqual(preferences.quickToolIDs, [.arrow, .text])
        XCTAssertEqual(preferences.hiddenToolIDs, [.rectangle, .blur])
        XCTAssertFalse(preferences.extendedToolIDs.contains(.rectangle))
        XCTAssertFalse(preferences.extendedToolIDs.contains(.blur))
    }

    func testCurrentPreferencesRoundTripIncludesWatermarkAndOCRKeys() throws {
        let appearance = ScreenshotElementAppearance(
            startEnding: .circle,
            endEnding: .filledArrow,
            linePattern: .dashed,
            cornerRadius: 9,
            smoothing: 0.8,
            highlightMode: .freehand,
            textWeight: .semibold,
            textAlignment: .trailing,
            textBackgroundColor: .init(red: 1, green: 1, blue: 0, alpha: 0.5),
            effectIntensity: 12
        )
        let original = ScreenshotPreferences(
            toolOrder: [.select, .aspectRatio, .text, .arrow],
            quickToolIDs: [.text, .arrow],
            hiddenToolIDs: [.blur],
            toolPresets: [.arrow: ScreenshotToolPreset(tool: .arrow, appearance: appearance)],
            confirmsDiscardBeforeClosing: false,
            automaticallyRecognizesHistory: true,
            outputFormat: .jpeg,
            jpegQuality: 0.82
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenshotPreferences.self, from: encoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.version, ScreenshotPreferences.currentVersion)
        XCTAssertEqual(decoded.toolPresets[.arrow]?.appearance, appearance)
        XCTAssertNil(object["initialToolbarState"])
        XCTAssertNotNil(object["quickToolIDs"])
        XCTAssertNotNil(object["hiddenToolIDs"])
        XCTAssertNil(object["addsScreenshotTag"])
        XCTAssertEqual(object["automaticallyRecognizesHistory"] as? Bool, true)
        XCTAssertEqual(object["confirmsDiscardBeforeClosing"] as? Bool, false)
        XCTAssertNil(object["defaultEditorMode"])
        XCTAssertNil(object["fullHiddenTools"])
        XCTAssertNil(object["quickHiddenTools"])
        XCTAssertNotNil(object["recentColors"])
        XCTAssertNotNil(object["customConstraints"])
        XCTAssertNotNil(object["watermarkPresets"])
    }

    func testVersionSevenPayloadIsRejectedWithoutCompatibilityDecoding() {
        let legacy = #"{"version":7,"initialToolbarState":"compact","toolOrder":["select","crop","arrow"],"quickToolIDs":["arrow"],"hiddenToolIDs":[],"toolPresets":{},"captureDefaults":{"delaySeconds":0,"showsCursor":false,"includesWindowShadow":true,"freezesFrame":false,"regionConstraint":{"free":{}}},"retainsCaptureDefaults":true,"outputFormat":"png","jpegQuality":0.9}"#.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(ScreenshotPreferences.self, from: legacy))
        XCTAssertEqual(ScreenshotPreferences.currentVersion, 19)
    }

    func testRetainsCaptureDefaultsRoundTrips() throws {
        let original = ScreenshotPreferences(retainsCaptureDefaults: false)

        let decoded = try JSONDecoder().decode(
            ScreenshotPreferences.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.retainsCaptureDefaults)
    }

    func testVersionThirteenMigratesToV19WithoutCropAndPreservesConfiguration() throws {
        let arrowAppearance = ScreenshotElementAppearance.line(.init(
            color: .init(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
            width: 7,
            endEnding: .filledArrow
        ))
        let legacy = LegacyPreferencesV13(
            toolOrder: ["select", "crop", "text", "arrow", "ocr"],
            quickToolIDs: ["text", "arrow"],
            hiddenToolIDs: ["ocr"],
            toolPresets: [.arrow: .init(tool: .arrow, appearance: arrowAppearance)],
            captureDefaults: .init(
                delaySeconds: 3,
                showsCursor: false,
                freezesFrame: true,
                regionConstraint: .fixedPixels(width: 800, height: 600)
            ),
            retainsCaptureDefaults: false,
            confirmsDiscardBeforeClosing: false,
            addsScreenshotTag: true,
            automaticallyRecognizesHistory: true,
            outputFormat: .jpeg,
            jpegQuality: 0.73
        )

        let migrated = try JSONDecoder().decode(
            ScreenshotPreferences.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(migrated.version, 19)
        XCTAssertEqual(migrated.quickToolIDs, [.text, .arrow])
        XCTAssertEqual(Array(migrated.toolOrder.prefix(3)), [.select, .text, .arrow])
        XCTAssertFalse(migrated.toolOrder.contains(where: { $0.rawValue == "crop" }))
        XCTAssertTrue(migrated.toolOrder.contains(.step))
        XCTAssertEqual(migrated.toolPresets[.arrow]?.appearance, arrowAppearance)
        XCTAssertEqual(migrated.toolPresets[.step]?.appearance.payload.kind, .step)
        XCTAssertEqual(migrated.captureDefaults, legacy.captureDefaults)
        XCTAssertFalse(migrated.retainsCaptureDefaults)
        XCTAssertFalse(migrated.confirmsDiscardBeforeClosing)
        XCTAssertTrue(migrated.automaticallyRecognizesHistory)
        XCTAssertEqual(migrated.outputFormat, .jpeg)
        XCTAssertEqual(migrated.jpegQuality, 0.73)
        XCTAssertEqual(migrated.customConstraints, [])
        XCTAssertFalse(migrated.toolOrder.contains(.aspectRatio))
        XCTAssertTrue(migrated.extendedToolIDs.contains(.watermark))
    }

    func testVersionFourteenMigratesToV19AndDiscardsWindowShadowPreference() throws {
        let current = ScreenshotPreferences(
            recentColors: [.init(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)],
            captureDefaults: .init(delaySeconds: 5, freezesFrame: true)
        )
        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = 14
        object["addsScreenshotTag"] = true
        object.removeValue(forKey: "customConstraints")
        var capture = try XCTUnwrap(object["captureDefaults"] as? [String: Any])
        capture["includesWindowShadow"] = true
        object["captureDefaults"] = capture

        let migrated = try JSONDecoder().decode(
            ScreenshotPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(migrated.version, 19)
        XCTAssertEqual(migrated.captureDefaults.delaySeconds, 5)
        XCTAssertTrue(migrated.captureDefaults.freezesFrame)
        XCTAssertEqual(migrated.recentColors, current.recentColors)
        XCTAssertEqual(migrated.customConstraints, [])
    }

    func testVersionFifteenMigratesToV19WithoutAspectAndPreservesSavedConstraints() throws {
        let saved = ScreenshotCustomConstraintPreset(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            constraint: .ratio(width: 21, height: 9)
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

        let migrated = try JSONDecoder().decode(
            ScreenshotPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(migrated.version, 19)
        XCTAssertEqual(
            migrated.quickToolIDs,
            [.arrow, .rectangle, .text, .highlight, .pixelate]
        )
        XCTAssertEqual(migrated.hiddenToolIDs, [.blur])
        XCTAssertEqual(migrated.customConstraints, [saved])
        XCTAssertEqual(migrated.toolOrder.first, .select)
        XCTAssertFalse(migrated.toolOrder.contains(.aspectRatio))
        XCTAssertTrue(migrated.extendedToolIDs.contains(.watermark))
    }

    func testVersionFifteenFullQuickZonePreservesAllToolsWhenAspectIsAdded() throws {
        let legacyQuick: [ScreenshotToolbarItemID] = [
            .arrow, .line, .rectangle, .ellipse, .text, .highlight,
        ]
        let legacy = ScreenshotPreferences(
            quickToolIDs: legacyQuick,
            hiddenToolIDs: [.blur]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object["version"] = 15
        object["addsScreenshotTag"] = false

        let migrated = try JSONDecoder().decode(
            ScreenshotPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(
            migrated.quickToolIDs,
            [.arrow, .rectangle, .ellipse, .text, .highlight]
        )
        XCTAssertFalse(migrated.visibleExtendedToolbarItemIDs.contains(.highlight))
        XCTAssertFalse(migrated.visibleExtendedToolbarItemIDs.contains(.text))
        XCTAssertEqual(migrated.hiddenToolIDs, [.blur])

        let quick = Set(migrated.visibleQuickToolbarItemIDs)
        let expanded = Set(migrated.visibleExtendedToolbarItemIDs)
        let hidden = Set(migrated.hiddenToolIDs)
        XCTAssertTrue(quick.isDisjoint(with: expanded))
        XCTAssertTrue(quick.isDisjoint(with: hidden))
        XCTAssertTrue(expanded.isDisjoint(with: hidden))
        XCTAssertEqual(
            quick.union(expanded).union(hidden),
            Set(ScreenshotToolbarItemID.allCases).subtracting(ScreenshotPreferences.commandToolIDs)
        )
    }

    func testVersionSixteenMigratesToV19DroppingLineAndPreservingArrowZoneAndStyle() throws {
        let arrowStyle = ScreenshotElementAppearance.line(.init(
            color: .init(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            width: 7,
            startEnding: .circle,
            endEnding: .filledArrow
        ))
        let legacy = ScreenshotPreferences(
            toolOrder: [.select, .line, .rectangle, .arrow, .text],
            quickToolIDs: [.line, .rectangle],
            hiddenToolIDs: [.arrow],
            toolPresets: [
                .line: .init(tool: .line, appearance: .line(.init(width: 13))),
                .arrow: .init(tool: .arrow, appearance: arrowStyle),
            ]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object["version"] = 16
        object["addsScreenshotTag"] = false
        object["toolOrder"] = ["select", "line", "rectangle", "arrow", "text"]
        object["quickToolIDs"] = ["line", "rectangle"]
        object["hiddenToolIDs"] = ["arrow"]

        let migrated = try JSONDecoder().decode(
            ScreenshotPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(migrated.version, 19)
        XCTAssertFalse(migrated.toolOrder.contains(.line))
        XCTAssertFalse(migrated.quickToolIDs.contains(.line))
        XCTAssertEqual(migrated.hiddenToolIDs, [.arrow])
        XCTAssertEqual(migrated.toolPresets[.arrow]?.appearance, arrowStyle)
        XCTAssertNil(migrated.toolPresets[.line])
    }

    func testVersionSeventeenMigratesToV19RemovingAspectAndAddingWatermarkToMore() throws {
        let legacy = ScreenshotPreferences(
            toolOrder: [.select, .text, .arrow],
            quickToolIDs: [.text, .arrow],
            hiddenToolIDs: [.blur]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object["version"] = 17
        object["addsScreenshotTag"] = false
        object["toolOrder"] = ["select", "aspectRatio", "text", "arrow", "blur"]
        object["quickToolIDs"] = ["aspectRatio", "text", "arrow"]
        object.removeValue(forKey: "watermarkPresets")

        let migrated = try JSONDecoder().decode(
            ScreenshotPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(migrated.version, 19)
        XCTAssertFalse(migrated.toolOrder.contains(.aspectRatio))
        XCTAssertEqual(migrated.quickToolIDs, [.text, .arrow])
        XCTAssertTrue(migrated.extendedToolIDs.contains(.watermark))
        XCTAssertEqual(migrated.watermarkPresets, [])
    }

    func testVersionEighteenMigratesOnlyTextWatermarksAndDropsInvalidDefaultReference() throws {
        let textID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let imageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ScreenshotPreferences())) as? [String: Any]
        )
        object["version"] = 18
        object["addsScreenshotTag"] = true
        object["watermarkPresets"] = [
            [
                "id": textID.uuidString,
                "name": "Legacy Text",
                "content": ["text": ["_0": [
                    "text": "Legacy",
                    "color": ["red": 0.2, "green": 0.3, "blue": 0.4, "alpha": 1.0],
                    "weight": "semibold",
                    "alignment": "center",
                    "fontSize": 64.0,
                ]]],
                "defaultSizeFraction": 0.2,
                "defaultPosition": "bottomTrailing",
                "marginFraction": 0.02,
                "opacity": 0.4,
            ],
            [
                "id": imageID.uuidString,
                "name": "Legacy Image",
                "content": ["image": ["_0": ["assetID": "legacy-image"]]],
                "defaultSizeFraction": 0.2,
                "defaultPosition": "bottomTrailing",
                "marginFraction": 0.02,
                "opacity": 0.35,
            ],
        ]
        var capture = try XCTUnwrap(object["captureDefaults"] as? [String: Any])
        capture["watermarkPresetID"] = imageID.uuidString
        object["captureDefaults"] = capture

        let migrated = try JSONDecoder().decode(
            ScreenshotPreferences.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(migrated.version, 19)
        XCTAssertEqual(migrated.watermarkPresets.count, 1)
        XCTAssertEqual(migrated.watermarkPresets[0].id, textID)
        XCTAssertEqual(migrated.watermarkPresets[0].style.text, "Legacy")
        XCTAssertEqual(migrated.watermarkPresets[0].style.fontSizeFraction, 0.05)
        XCTAssertEqual(migrated.watermarkPresets[0].style.density, 0.5)
        XCTAssertEqual(migrated.watermarkPresets[0].style.angleDegrees, -30)
        XCTAssertEqual(migrated.watermarkPresets[0].style.opacity, 0.4)
        XCTAssertNil(migrated.captureDefaults.watermarkPresetID)
    }

    func testWatermarkPresetsClampRoundTripReplaceAndDelete() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let unsafe = ScreenshotWatermarkPreset(
            id: id,
            name: "Logo",
            style: .init(
                text: "Blocks",
                fontSizeFraction: 10,
                density: -1,
                angleDegrees: 200,
                opacity: 2
            )
        )
        XCTAssertEqual(unsafe.style.fontSizeFraction, 0.12)
        XCTAssertEqual(unsafe.style.density, 0)
        XCTAssertEqual(unsafe.style.angleDegrees, 90)
        XCTAssertEqual(unsafe.style.opacity, 1)

        var preferences = ScreenshotPreferences(watermarkPresets: [unsafe, unsafe])
        XCTAssertEqual(preferences.watermarkPresets, [unsafe])
        preferences.saveWatermarkPreset(.init(
            id: id,
            name: "Updated",
            style: .init(text: "Updated Blocks")
        ))
        XCTAssertEqual(preferences.watermarkPresets.count, 1)
        XCTAssertEqual(preferences.watermarkPresets[0].name, "Updated")

        let decoded = try JSONDecoder().decode(
            ScreenshotPreferences.self,
            from: JSONEncoder().encode(preferences)
        )
        XCTAssertEqual(decoded, preferences)
        preferences.removeWatermarkPreset(id: id)
        XCTAssertTrue(preferences.watermarkPresets.isEmpty)
    }

    func testCustomConstraintsNormalizeDeduplicateLimitAndDelete() {
        XCTAssertNil(ScreenshotPreferences.normalizedCustomConstraint(.ratio(width: 0, height: 9)))
        XCTAssertNil(ScreenshotPreferences.normalizedCustomConstraint(.ratio(width: .infinity, height: 9)))
        XCTAssertNil(ScreenshotPreferences.normalizedCustomConstraint(.ratio(width: 32_769, height: 1)))
        XCTAssertNil(ScreenshotPreferences.normalizedCustomConstraint(.fixedPixels(width: 0, height: 600)))
        XCTAssertNil(ScreenshotPreferences.normalizedCustomConstraint(.fixedPixels(width: 32_769, height: 600)))
        XCTAssertNil(ScreenshotPreferences.normalizedCustomConstraint(.fixedPixels(width: 32_768, height: 32_768)))
        XCTAssertEqual(
            ScreenshotPreferences.normalizedCustomConstraint(.ratio(width: 32_000.5, height: 18_000.25)),
            .ratio(width: 32_000.5 / 18_000.25, height: 1)
        )

        var preferences = ScreenshotPreferences(customConstraints: [
            .init(constraint: .free),
            .init(constraint: .ratio(width: .nan, height: 9)),
            .init(constraint: .fixedPixels(width: 800, height: 1_200)),
        ])

        XCTAssertEqual(preferences.customConstraints.map(\.constraint), [
            .fixedPixels(width: 1_200, height: 800),
        ])

        preferences.saveCustomConstraint(.ratio(width: 16, height: 9))
        preferences.saveCustomConstraint(.ratio(width: 32, height: 18))
        XCTAssertEqual(preferences.customConstraints.count, 2)
        XCTAssertEqual(preferences.customConstraints.first?.constraint, .ratio(width: 32, height: 18))

        for value in 2...10 {
            preferences.saveCustomConstraint(.fixedPixels(width: value * 100, height: 100))
        }
        XCTAssertEqual(preferences.customConstraints.count, ScreenshotPreferences.customConstraintLimit)
        XCTAssertEqual(preferences.customConstraints.first?.constraint, .fixedPixels(width: 1_000, height: 100))

        let removedID = preferences.customConstraints[3].id
        preferences.removeCustomConstraint(id: removedID)
        XCTAssertEqual(preferences.customConstraints.count, 7)
        XCTAssertFalse(preferences.customConstraints.contains { $0.id == removedID })
    }

    func testRecentColorsClampToSRGBOpaqueDeduplicateAndLimitToEight() {
        var colors: [ScreenshotColor] = []
        for index in 0..<10 {
            colors.append(ScreenshotColor(
                red: Double(index) / 8,
                green: index == 0 ? -0.2 : 0.4,
                blue: index == 1 ? 1.4 : 0.6,
                alpha: 0.15
            ))
        }
        colors.append(ScreenshotColor(red: 0, green: 0, blue: 0.6, alpha: 0.8))

        let preferences = ScreenshotPreferences(recentColors: colors)

        XCTAssertEqual(preferences.recentColors.count, 8)
        XCTAssertTrue(preferences.recentColors.allSatisfy { $0.alpha == 1 })
        XCTAssertEqual(
            preferences.recentColors[0],
            ScreenshotColor(red: 0, green: 0, blue: 0.6, alpha: 1)
        )
        XCTAssertEqual(
            preferences.recentColors[1],
            ScreenshotColor(red: 0.125, green: 0.4, blue: 1, alpha: 1)
        )
        XCTAssertTrue(preferences.recentColors.allSatisfy {
            (0...1).contains($0.red) && (0...1).contains($0.green) && (0...1).contains($0.blue)
        })
    }

    func testRecordingRecentColorMovesItToFrontAndKeepsInvariantAcrossRoundTrip() throws {
        var preferences = ScreenshotPreferences(recentColors: [
            .init(red: 1, green: 0, blue: 0, alpha: 1),
            .init(red: 0, green: 1, blue: 0, alpha: 1),
        ])

        preferences.recordRecentColor(.init(red: 0, green: 1, blue: 0, alpha: 0.2))
        let decoded = try JSONDecoder().decode(
            ScreenshotPreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        XCTAssertEqual(decoded.recentColors, [
            .init(red: 0, green: 1, blue: 0, alpha: 1),
            .init(red: 1, green: 0, blue: 0, alpha: 1),
        ])
    }
}
private struct LegacyPreferencesV13: Encodable {
    enum Tool: String, Encodable {
        case arrow
    }

    struct Preset: Encodable {
        let tool: Tool
        let appearance: ScreenshotElementAppearance
    }

    let version = 13
    let toolOrder: [String]
    let quickToolIDs: [String]
    let hiddenToolIDs: [String]
    let toolPresets: [Tool: Preset]
    let captureDefaults: ScreenshotCaptureDefaults
    let retainsCaptureDefaults: Bool
    let confirmsDiscardBeforeClosing: Bool
    let addsScreenshotTag: Bool
    let automaticallyRecognizesHistory: Bool
    let outputFormat: ScreenshotOutputFormat
    let jpegQuality: Double
}
