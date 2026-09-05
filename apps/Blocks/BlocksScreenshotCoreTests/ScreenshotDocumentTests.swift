import AppKit
import CoreGraphics
import XCTest
@testable import BlocksScreenshotCore

final class ScreenshotDocumentTests: XCTestCase {
    func testStepNumberingUsesMaximumWithoutFillingDeletedGaps() {
        let elements = [makeStep(number: 1), makeStep(number: 3)]

        XCTAssertEqual(ScreenshotStepNumbering.nextNumber(in: elements), 4)
        XCTAssertEqual(ScreenshotStepNumbering.numberForDuplicate(in: elements), 4)
    }

    func testStepRenumberingConflictMovesEarlierRangeInSingleTransaction() throws {
        let first = makeStep(number: 1)
        let second = makeStep(number: 2)
        let third = makeStep(number: 3)
        let elements = [first, second, third]

        let transaction = try XCTUnwrap(
            ScreenshotStepNumbering.transaction(moving: third.id, to: 1, in: elements)
        )
        let updated = transaction.applying(to: elements)

        XCTAssertEqual(transaction.changes.count, 3)
        XCTAssertEqual(updated.map(\.stepNumber), [2, 3, 1])
        XCTAssertEqual(elements.map(\.stepNumber), [1, 2, 3])
    }

    func testStepRenumberingConflictMovesLaterRangeAndDocumentCommitsOnce() throws {
        let first = makeStep(number: 1)
        let second = makeStep(number: 2)
        let third = makeStep(number: 3)
        let document = ScreenshotSceneDocument(
            sourceContext: try makeSourceContext(),
            snapshot: .init(
                cropRect: .init(x: 0, y: 0, width: 100, height: 80),
                elements: [first, second, third]
            )
        )
        let transaction = try XCTUnwrap(
            ScreenshotStepNumbering.transaction(
                moving: first.id,
                to: 3,
                in: document.snapshot.elements
            )
        )

        XCTAssertTrue(document.applyStepNumberTransaction(transaction))
        XCTAssertEqual(document.snapshot.elements.map(\.stepNumber), [3, 1, 2])
        XCTAssertEqual(document.revision, 1)
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.snapshot.elements.map(\.stepNumber), [1, 2, 3])
    }

    func testStepElementKeepsOptionalNoteAndTypedAppearance() {
        let empty = makeStep(number: 1, note: "")
        let noted = makeStep(number: 2, note: "Install update")

        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(noted.text, "Install update")
        XCTAssertEqual(noted.appearance.payload.kind, .step)
        XCTAssertEqual(noted.kind, .step)
    }

    func testStepElementRoundTripsAndDuplicateReceivesNewMaximumNumber() throws {
        let original = makeStep(number: 4, note: "Publish")
        let decoded = try JSONDecoder().decode(
            ScreenshotElement.self,
            from: JSONEncoder().encode(original)
        )
        let document = ScreenshotSceneDocument(
            sourceContext: try makeSourceContext(),
            snapshot: .init(
                cropRect: .init(x: 0, y: 0, width: 100, height: 80),
                elements: [makeStep(number: 1), original]
            )
        )

        let duplicate = try XCTUnwrap(document.duplicateElement(id: original.id))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(duplicate.kind, .step)
        XCTAssertEqual(duplicate.stepNumber, 5)
        XCTAssertEqual(duplicate.text, "Publish")
    }

    func testLegacyFlatStepAppearanceDecodesIntoCanonicalThreeComponentModel() throws {
        let legacy = #"{"badgeSize":72,"noteFontSize":23,"noteBorderWidth":4,"gap":14}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ScreenshotStepAppearance.self, from: legacy)
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(decoded)
        ) as? [String: Any]

        XCTAssertEqual(decoded.badge.size, 72)
        XCTAssertEqual(decoded.connector.width, 4)
        XCTAssertEqual(decoded.note.fontSize, 23)
        XCTAssertEqual(decoded.note.backgroundBorderWidth, 4)
        XCTAssertEqual(decoded.gap, 14)
        XCTAssertNotNil(encoded?["badge"])
        XCTAssertNotNil(encoded?["connector"])
        XCTAssertNotNil(encoded?["note"])
        XCTAssertNil(encoded?["badgeSize"])
        XCTAssertNil(encoded?["noteFontSize"])
    }

    func testReplacingStepWithComponentsIsOneUndoableOrderedMutation() throws {
        let step = makeStep(number: 3, note: "Publish")
        let document = ScreenshotSceneDocument(
            sourceContext: try makeSourceContext(),
            snapshot: .init(
                cropRect: .init(x: 0, y: 0, width: 100, height: 80),
                elements: [step]
            )
        )
        let connector = ScreenshotElement(
            kind: .arrow,
            geometry: .line(start: .init(x: 20, y: 20), end: .init(x: 40, y: 20))
        )
        let note = ScreenshotElement(
            kind: .text,
            geometry: .rect(.init(x: 40, y: 10, width: 40, height: 20)),
            text: "Publish"
        )
        let badge = ScreenshotElement(
            kind: .counter,
            geometry: .counter(center: .init(x: 20, y: 20)),
            text: "3"
        )

        XCTAssertTrue(document.replaceElement(id: step.id, with: [connector, note, badge]))
        XCTAssertEqual(document.snapshot.elements.map(\.kind), [.arrow, .text, .counter])
        XCTAssertEqual(document.revision, 1)
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.snapshot.elements, [step])
    }

    func testStaleStepNumberTransactionDoesNotOverwriteChangedNumber() throws {
        let step = makeStep(number: 1)
        let transaction = try XCTUnwrap(
            ScreenshotStepNumbering.transaction(moving: step.id, to: 2, in: [step])
        )
        var changed = step
        changed.stepNumber = 7

        XCTAssertEqual(transaction.applying(to: [changed]).first?.stepNumber, 7)
    }

    func testTextLayoutUsesPingFangForEveryWeightAndKeepsBoldConsistent() {
        let bold = ScreenshotTextLayout(appearance: .init(fontSize: 20, textWeight: .bold))
        let semibold = ScreenshotTextLayout(appearance: .init(fontSize: 20, textWeight: .semibold))

        XCTAssertEqual(bold.fontName, "PingFangSC-Semibold")
        XCTAssertEqual(bold.fontName, semibold.fontName)
        XCTAssertEqual(bold.characterSpacing, 0)
        XCTAssertEqual(bold.lineHeight, 24)
    }

    func testTextLayoutConvertsSourceMetricsToViewPoints() {
        let layout = ScreenshotTextLayout(appearance: .init(fontSize: 24, textWeight: .medium))
        let viewMetrics = layout.viewMetrics(sourceUnitsPerViewPoint: 2)

        XCTAssertEqual(viewMetrics.fontSize, 12)
        XCTAssertEqual(viewMetrics.characterSpacing, 0)
        XCTAssertEqual(viewMetrics.lineHeight, 14.4, accuracy: 0.000_001)
    }

    func testTextLayoutScalesMetricsWhenViewUsesHalfASourceUnitPerPoint() {
        let layout = ScreenshotTextLayout(appearance: .init(fontSize: 24, textWeight: .medium))
        let viewMetrics = layout.viewMetrics(sourceUnitsPerViewPoint: 0.5)

        XCTAssertEqual(viewMetrics.fontSize, 48)
        XCTAssertEqual(viewMetrics.characterSpacing, 0)
        XCTAssertEqual(viewMetrics.lineHeight, 57.6, accuracy: 0.000_001)
    }

    func testTextLayoutMultipliesForegroundAlphaByElementOpacity() {
        let layout = ScreenshotTextLayout(appearance: .init(
            strokeColor: .init(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5),
            opacity: 0.4
        ))

        XCTAssertEqual(layout.foregroundColor.alpha, 0.2, accuracy: 0.000_001)
    }

    func testResolvedColorClampsSRGBAndComposesOpacityExactlyOnce() {
        let resolved = ScreenshotResolvedColor(
            .init(red: 1.2, green: -0.2, blue: 0.4, alpha: 0.5),
            opacity: 0.4
        )

        XCTAssertEqual(resolved.red, 1)
        XCTAssertEqual(resolved.green, 0)
        XCTAssertEqual(resolved.blue, 0.4)
        XCTAssertEqual(resolved.alpha, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(resolved.cgColor.alpha, 0.2, accuracy: 0.000_001)
    }

    func testTextLayoutMultipliesBackgroundAlphaByElementOpacityForAppKitInput() throws {
        let layout = ScreenshotTextLayout(appearance: .init(
            opacity: 0.4,
            textBackgroundColor: .init(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
        ))

        let background = try XCTUnwrap(layout.backgroundColor)
        let inputColor = try XCTUnwrap(NSColor(cgColor: background))
        XCTAssertEqual(background.alpha, 0.32, accuracy: 0.000_001)
        XCTAssertEqual(inputColor.alphaComponent, 0.32, accuracy: 0.000_001)
    }

    func testTextElementsDefaultToAutoSizingAndNonTextElementsDoNotCarryTextSizing() throws {
        let text = ScreenshotElement(
            kind: .text,
            geometry: .rect(.init(x: 2, y: 3, width: 40, height: 24)),
            text: "Hello"
        )
        let rectangle = ScreenshotElement(
            kind: .rectangle,
            geometry: .rect(.init(x: 2, y: 3, width: 40, height: 24))
        )

        let decoded = try JSONDecoder().decode(
            ScreenshotElement.self,
            from: JSONEncoder().encode(text)
        )

        XCTAssertEqual(text.textBoxSizing, .auto)
        XCTAssertEqual(decoded.textBoxSizing, .auto)
        XCTAssertNil(rectangle.textBoxSizing)
    }

    func testAutoTextMeasurementGrowsUntilMaximumWidthThenWraps() {
        let layout = ScreenshotTextLayout(appearance: .init(fontSize: 20, textWeight: .regular))

        let short = layout.measure("Hi", sizing: .auto, constrainedTo: 160)
        let medium = layout.measure("Hello screenshot", sizing: .auto, constrainedTo: 160)
        let long = layout.measure(
            "Hello screenshot editor with enough words to wrap onto several lines",
            sizing: .auto,
            constrainedTo: 160
        )

        XCTAssertGreaterThan(medium.width, short.width)
        XCTAssertLessThanOrEqual(medium.width, 160)
        XCTAssertEqual(long.width, 160, accuracy: 0.001)
        XCTAssertGreaterThan(long.height, medium.height)
    }

    func testFixedWidthTextMeasurementPreservesWidthAndGrowsHeight() {
        let layout = ScreenshotTextLayout(appearance: .init(fontSize: 18, textWeight: .medium))

        let short = layout.measure("Fixed", sizing: .fixedWidth, constrainedTo: 92)
        let long = layout.measure(
            "Fixed width text wraps and automatically increases its height",
            sizing: .fixedWidth,
            constrainedTo: 92
        )

        XCTAssertEqual(short.width, 92, accuracy: 0.001)
        XCTAssertEqual(long.width, 92, accuracy: 0.001)
        XCTAssertGreaterThan(long.height, short.height)
    }

    func testFixedBoxTextMeasurementUsesTheProvidedWidth() {
        let layout = ScreenshotTextLayout(appearance: .init(fontSize: 18, textWeight: .medium))

        let measured = layout.measure(
            "Fixed box text",
            sizing: .fixedBox,
            constrainedTo: 128
        )

        XCTAssertEqual(measured.width, 128, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(measured.height, layout.lineHeight + layout.padding * 2)
    }

    func testMixedChineseEnglishAndJapaneseTextWrapsWithinTheConstraint() {
        let layout = ScreenshotTextLayout(appearance: .init(fontSize: 20, textWeight: .semibold))

        let measured = layout.measure(
            "中文 English 日本語 mixed language content wraps correctly",
            sizing: .fixedWidth,
            constrainedTo: 108
        )

        XCTAssertEqual(measured.width, 108, accuracy: 0.001)
        XCTAssertGreaterThan(measured.height, layout.lineHeight + layout.padding * 2)
    }

    func testLargeFontMeasurementAlwaysContainsOneLineAndPadding() {
        let layout = ScreenshotTextLayout(appearance: .init(fontSize: 96, textWeight: .bold))

        let measured = layout.measure("大 A あ", sizing: .auto, constrainedTo: 600)

        XCTAssertGreaterThanOrEqual(measured.height, layout.lineHeight + layout.padding * 2)
        XCTAssertGreaterThan(measured.width, layout.padding * 2)
    }

    func testSourceContextRetainsOnlyLightweightTileDescriptors() throws {
        let image = try makeTestImage(width: 20, height: 20)
        let descriptor = ScreenshotSourceTileDescriptor(
            id: "display-1",
            bounds: .init(x: 0, y: 0, width: 20, height: 20)
        )

        let context = ScreenshotSourceContext(
            sourceBounds: descriptor.bounds,
            tileDescriptors: [descriptor],
            compositeSource: image
        )

        XCTAssertEqual(context.tileDescriptors, [descriptor])
    }
    func testSceneSnapshotRoundTripsStableElementIDsAndEveryElementKind() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let elements = ScreenshotElementKind.allCases.enumerated().map { index, kind in
            ScreenshotElement(
                id: index == 0 ? id : UUID(),
                kind: kind,
                geometry: kind.usesLineGeometry
                    ? .line(start: .init(x: 2, y: 3), end: .init(x: 20, y: 18))
                    : .rect(.init(x: 3, y: 4, width: 12, height: 9)),
                text: kind == .text ? "line one\nline two" : nil,
                appearance: .init()
            )
        }
        let snapshot = ScreenshotSceneSnapshot(
            cropRect: .init(x: 1, y: 2, width: 30, height: 20),
            elements: elements
        )

        let decoded = try JSONDecoder().decode(
            ScreenshotSceneSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.elements.first?.id, id)
        XCTAssertEqual(Set(decoded.elements.map(\.kind)), Set(ScreenshotElementKind.allCases))
    }

    func testAddUpdateRemoveUndoRedoPreserveSourceContext() throws {
        let source = try makeTestImage(width: 40, height: 30)
        let context = ScreenshotSourceContext(
            sourceBounds: .init(x: 0, y: 0, width: 40, height: 30),
            tileDescriptors: [
                .init(id: "display-1", bounds: .init(x: 0, y: 0, width: 40, height: 30)),
            ],
            compositeSource: source
        )
        let document = ScreenshotSceneDocument(sourceContext: context)
        let element = makeRectangle(id: UUID())

        XCTAssertTrue(document.add(element))
        XCTAssertEqual(document.revision, 1)
        XCTAssertEqual(document.snapshot.elements.map(\.id), [element.id])

        XCTAssertTrue(document.updateElement(id: element.id) {
            $0.geometry = .rect(.init(x: 12, y: 13, width: 10, height: 8))
            $0.appearance.lineWidth = 7
        })
        XCTAssertEqual(document.revision, 2)
        XCTAssertEqual(document.snapshot.elements.first?.appearance.lineWidth, 7)

        XCTAssertTrue(document.removeElement(id: element.id))
        XCTAssertTrue(document.snapshot.elements.isEmpty)
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.snapshot.elements.first?.appearance.lineWidth, 7)
        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.snapshot.elements.first?.geometry, element.geometry)
        XCTAssertTrue(document.redo())
        XCTAssertEqual(document.snapshot.elements.first?.appearance.lineWidth, 7)
        XCTAssertTrue(document.sourceContext.compositeSource === source)
    }

    func testDuplicateAndLayerMovesAreSingleUndoableDocumentMutations() throws {
        let source = try makeTestImage(width: 80, height: 60)
        let document = ScreenshotSceneDocument(sourceContext: .init(
            sourceBounds: .init(x: 0, y: 0, width: 80, height: 60),
            tileDescriptors: [],
            compositeSource: source
        ))
        let back = ScreenshotElement(
            kind: .rectangle,
            geometry: .rect(.init(x: 2, y: 2, width: 20, height: 20)),
            appearance: .defaultValue(for: .rectangle)
        )
        let front = ScreenshotElement(
            kind: .ellipse,
            geometry: .rect(.init(x: 8, y: 8, width: 20, height: 20)),
            appearance: .defaultValue(for: .ellipse)
        )
        XCTAssertTrue(document.add(back))
        XCTAssertTrue(document.add(front))

        let duplicate = try XCTUnwrap(document.duplicateElement(id: back.id, offsetX: 4, offsetY: 5))
        XCTAssertNotEqual(duplicate.id, back.id)
        XCTAssertEqual(document.snapshot.elements.last?.id, duplicate.id)
        XCTAssertTrue(document.moveElementBackward(id: duplicate.id))
        XCTAssertEqual(document.snapshot.elements.map(\.id), [back.id, duplicate.id, front.id])
        XCTAssertTrue(document.moveElementForward(id: duplicate.id))
        XCTAssertEqual(document.snapshot.elements.map(\.id), [back.id, front.id, duplicate.id])

        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.snapshot.elements.map(\.id), [back.id, duplicate.id, front.id])
    }

    func testInteractionDraftCommitsAsOneUndoEntry() throws {
        let document = try makeDocument()
        let element = makeRectangle(id: UUID())
        XCTAssertTrue(document.add(element))
        let revisionBeforeDraft = document.revision

        XCTAssertTrue(document.beginInteraction())
        XCTAssertTrue(document.updateInteraction { snapshot in
            snapshot.elements[0].geometry = .rect(.init(x: 10, y: 10, width: 8, height: 8))
        })
        XCTAssertTrue(document.updateInteraction { snapshot in
            snapshot.elements[0].geometry = .rect(.init(x: 15, y: 12, width: 8, height: 8))
        })

        XCTAssertEqual(document.revision, revisionBeforeDraft)
        XCTAssertNotEqual(document.presentedSnapshot, document.snapshot)
        XCTAssertTrue(document.commitInteraction())
        XCTAssertEqual(document.revision, revisionBeforeDraft + 1)
        XCTAssertEqual(document.snapshot, document.presentedSnapshot)

        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.snapshot.elements.first?.geometry, element.geometry)
    }

    func testCancelInteractionDoesNotChangeDocumentOrHistory() throws {
        let document = try makeDocument()
        let original = document.snapshot

        XCTAssertTrue(document.beginInteraction())
        XCTAssertTrue(document.updateInteraction { snapshot in
            snapshot.elements.append(self.makeRectangle(id: UUID()))
            snapshot.cropRect = .init(x: 5, y: 5, width: 10, height: 10)
        })
        XCTAssertTrue(document.cancelInteraction())

        XCTAssertEqual(document.snapshot, original)
        XCTAssertEqual(document.presentedSnapshot, original)
        XCTAssertEqual(document.revision, 0)
        XCTAssertFalse(document.canUndo)
    }

    func testInteractionCropIsNormalizedAndClampedBeforePresentationAndCommit() throws {
        let document = try makeDocument()

        XCTAssertTrue(document.beginInteraction())
        XCTAssertTrue(document.updateInteraction { snapshot in
            snapshot.cropRect = .init(x: 50, y: 25, width: -30, height: -20)
        })

        XCTAssertEqual(document.presentedSnapshot.cropRect, .init(x: 20, y: 5, width: 20, height: 20))
        XCTAssertTrue(document.commitInteraction())
        XCTAssertEqual(document.snapshot.cropRect, .init(x: 20, y: 5, width: 20, height: 20))
        XCTAssertTrue(document.canUndo)
    }

    func testSetCropNormalizesRawMagnifierCenterAndDiameterInsideNonZeroSmallCrop() throws {
        let magnifier = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 500, y: -20)),
            appearance: .magnifier(.init(diameter: 400))
        )
        let document = ScreenshotSceneDocument(
            sourceContext: try makeSourceContext(),
            snapshot: .init(
                cropRect: .init(x: 0, y: 0, width: 100, height: 80),
                elements: [magnifier]
            )
        )
        let crop = ScreenshotPixelRect(x: 20, y: 10, width: 30, height: 24)

        XCTAssertTrue(document.setCropRect(crop))

        let normalized = try XCTUnwrap(document.snapshot.elements.first)
        guard case let .magnifier(center) = normalized.geometry,
              case let .magnifier(appearance) = normalized.appearance.payload else {
            return XCTFail("Expected a normalized magnifier element")
        }
        XCTAssertEqual(center, .init(x: 38, y: 22))
        XCTAssertEqual(appearance.diameter, 24, accuracy: 0.000_001)

        let layout = try XCTUnwrap(
            ScreenshotMagnifierResolvedLayout(element: normalized, constrainedTo: crop)
        )
        XCTAssertEqual(layout.center, center)
        XCTAssertEqual(layout.diameter, appearance.diameter, accuracy: 0.000_001)
        XCTAssertEqual(layout.lensRect, .init(x: 26, y: 10, width: 24, height: 24))
    }

    func testCropDraftCancelCommitAndSingleUndoRestoreCropAndMagnifierTogether() throws {
        let originalCrop = ScreenshotPixelRect(x: 10, y: 10, width: 80, height: 60)
        let magnifier = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 60, y: 40)),
            appearance: .magnifier(.init(diameter: 60))
        )
        let document = ScreenshotSceneDocument(
            sourceContext: try makeSourceContext(),
            snapshot: .init(cropRect: originalCrop, elements: [magnifier])
        )
        let original = document.snapshot
        let revisedCrop = ScreenshotPixelRect(x: 30, y: 20, width: 30, height: 20)

        XCTAssertTrue(document.beginInteraction())
        XCTAssertTrue(document.updateInteraction { $0.cropRect = revisedCrop })
        let cancelledDraft = document.presentedSnapshot
        XCTAssertEqual(cancelledDraft.cropRect, revisedCrop)
        XCTAssertMagnifier(
            cancelledDraft.elements[0],
            hasCenter: .init(x: 50, y: 30),
            diameter: 20
        )
        XCTAssertTrue(document.cancelInteraction())
        XCTAssertEqual(document.snapshot, original)
        XCTAssertEqual(document.presentedSnapshot, original)
        XCTAssertEqual(document.revision, 0)
        XCTAssertFalse(document.canUndo)

        XCTAssertTrue(document.beginInteraction())
        XCTAssertTrue(document.updateInteraction { $0.cropRect = revisedCrop })
        XCTAssertTrue(document.commitInteraction())
        XCTAssertEqual(document.snapshot, cancelledDraft)
        XCTAssertEqual(document.revision, 1)
        XCTAssertTrue(document.canUndo)

        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.snapshot, original)
        XCTAssertEqual(document.snapshot.cropRect, originalCrop)
        XCTAssertMagnifier(
            document.snapshot.elements[0],
            hasCenter: .init(x: 60, y: 40),
            diameter: 60
        )
    }

    func testDuplicateMagnifierNearCropEdgeRemainsFullyInsideCrop() throws {
        let crop = ScreenshotPixelRect(x: 20, y: 10, width: 70, height: 60)
        let original = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 55, y: 40)),
            appearance: .magnifier(.init(diameter: 60))
        )
        let document = ScreenshotSceneDocument(
            sourceContext: try makeSourceContext(),
            snapshot: .init(cropRect: crop, elements: [original])
        )

        let returnedDuplicate = try XCTUnwrap(
            document.duplicateElement(id: original.id, offsetX: 500, offsetY: -500)
        )
        let storedDuplicate = try XCTUnwrap(
            document.snapshot.elements.first(where: { $0.id == returnedDuplicate.id })
        )
        let layout = try XCTUnwrap(
            ScreenshotMagnifierResolvedLayout(element: storedDuplicate, constrainedTo: crop)
        )

        XCTAssertMagnifier(
            storedDuplicate,
            hasCenter: .init(x: 60, y: 40),
            diameter: 60
        )
        XCTAssertEqual(layout.lensRect, .init(x: 30, y: 10, width: 60, height: 60))
        XCTAssertGreaterThanOrEqual(layout.lensRect.x, crop.x)
        XCTAssertGreaterThanOrEqual(layout.lensRect.y, crop.y)
        XCTAssertLessThanOrEqual(
            layout.lensRect.x + layout.lensRect.width,
            crop.x + crop.width
        )
        XCTAssertLessThanOrEqual(
            layout.lensRect.y + layout.lensRect.height,
            crop.y + crop.height
        )
    }

    func testEmptyInteractionCropIsRejectedWithoutChangingHistory() throws {
        let document = try makeDocument()
        let original = document.snapshot

        XCTAssertTrue(document.beginInteraction())
        XCTAssertFalse(document.updateInteraction { snapshot in
            snapshot.cropRect = .init(x: 5, y: 5, width: 0, height: 10)
        })
        XCTAssertEqual(document.presentedSnapshot, original)
        XCTAssertTrue(document.commitInteraction())

        XCTAssertEqual(document.snapshot, original)
        XCTAssertEqual(document.revision, 0)
        XCTAssertFalse(document.canUndo)
    }

    func testVisibleElementsUsePresentedDraftCrop() throws {
        let document = try makeDocument()
        let inside = makeRectangle(id: UUID(), rect: .init(x: 2, y: 2, width: 8, height: 8))
        let outside = makeRectangle(id: UUID(), rect: .init(x: 30, y: 20, width: 8, height: 8))
        XCTAssertTrue(document.add(inside))
        XCTAssertTrue(document.add(outside))
        XCTAssertTrue(document.setCropRect(.init(x: 0, y: 0, width: 20, height: 15)))
        XCTAssertEqual(document.visibleElements.map(\.id), [inside.id])

        XCTAssertTrue(document.beginInteraction())
        XCTAssertTrue(document.updateInteraction { snapshot in
            snapshot.cropRect = .init(x: 0, y: 0, width: 40, height: 30)
        })

        XCTAssertEqual(Set(document.visibleElements.map(\.id)), Set([inside.id, outside.id]))
        XCTAssertTrue(document.cancelInteraction())
        XCTAssertEqual(document.visibleElements.map(\.id), [inside.id])
    }

    func testCropHidesOutOfBoundsElementsAndRestoresThemWhenExpanded() throws {
        let document = try makeDocument()
        let inside = makeRectangle(id: UUID(), rect: .init(x: 2, y: 2, width: 8, height: 8))
        let outside = makeRectangle(id: UUID(), rect: .init(x: 30, y: 20, width: 8, height: 8))
        XCTAssertTrue(document.add(inside))
        XCTAssertTrue(document.add(outside))

        XCTAssertTrue(document.setCropRect(.init(x: 0, y: 0, width: 20, height: 15)))
        XCTAssertEqual(document.visibleElements.map(\.id), [inside.id])
        XCTAssertEqual(document.snapshot.elements.count, 2)

        XCTAssertTrue(document.setCropRect(.init(x: 0, y: 0, width: 40, height: 30)))
        XCTAssertEqual(Set(document.visibleElements.map(\.id)), Set([inside.id, outside.id]))
        XCTAssertEqual(document.snapshot.elements.count, 2)
    }

    func testRenderRequestCapturesImmutableSnapshotAndExpiresAfterRevisionChanges() throws {
        let document = try makeDocument()
        let request = document.makeRenderRequest()
        let captured = request.snapshot

        XCTAssertTrue(document.isRenderRequestCurrent(request))
        XCTAssertTrue(document.add(makeRectangle(id: UUID())))

        XCTAssertEqual(request.snapshot, captured)
        XCTAssertTrue(request.snapshot.elements.isEmpty)
        XCTAssertFalse(document.isRenderRequestCurrent(request))
        XCTAssertNotEqual(request.revision, document.renderRevision)
    }

    func testDraftUpdateAndCancellationEachExpirePriorRenderRevision() throws {
        let document = try makeDocument()
        let committedRequest = document.makeRenderRequest()
        XCTAssertTrue(document.beginInteraction())
        XCTAssertTrue(document.updateInteraction { snapshot in
            snapshot.elements.append(self.makeRectangle(id: UUID()))
        })
        let draftRequest = document.makeRenderRequest()

        XCTAssertFalse(document.isRenderRequestCurrent(committedRequest))
        XCTAssertEqual(draftRequest.snapshot.elements.count, 1)
        XCTAssertTrue(document.cancelInteraction())

        XCTAssertFalse(document.isRenderRequestCurrent(draftRequest))
        XCTAssertTrue(document.makeRenderRequest().snapshot.elements.isEmpty)
    }

    func testCancelledRequestIsNeverCurrentEvenWithoutDocumentMutation() throws {
        let document = try makeDocument()
        let request = document.makeRenderRequest()

        request.cancellation.cancel()

        XCTAssertFalse(document.isRenderRequestCurrent(request))
    }

    func testLegacySceneDecodesWithSquareOutputAndWatermarkElementRoundTrips() throws {
        let legacy = #"{"cropRect":{"x":1,"y":2,"width":20,"height":10},"elements":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScreenshotSceneSnapshot.self, from: legacy)
        XCTAssertEqual(decoded.outputAppearance, .init())

        let watermark = ScreenshotElement(
            kind: .watermark,
            geometry: .rect(.init(x: 2, y: 3, width: 12, height: 6)),
            watermark: .init(
                presetID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
                name: "Watermark",
                style: .init(text: "Blocks", density: 0.7, angleDegrees: -24, opacity: 0.3)
            )
        )
        let snapshot = ScreenshotSceneSnapshot(
            cropRect: .init(x: 0, y: 0, width: 40, height: 30),
            elements: [watermark],
            outputAppearance: .init(isRounded: true)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ScreenshotSceneSnapshot.self, from: JSONEncoder().encode(snapshot)),
            snapshot
        )
    }

    func testOutputAppearanceMutationIsUndoableAndIncludedInRenderRequest() throws {
        let document = try makeDocument()
        XCTAssertTrue(document.setOutputAppearance(.init(isRounded: true)))
        XCTAssertTrue(document.snapshot.outputAppearance.isRounded)
        XCTAssertTrue(document.makeRenderRequest().snapshot.outputAppearance.isRounded)
        XCTAssertTrue(document.undo())
        XCTAssertFalse(document.snapshot.outputAppearance.isRounded)
        XCTAssertTrue(document.redo())
        XCTAssertTrue(document.snapshot.outputAppearance.isRounded)
    }

    private func makeDocument() throws -> ScreenshotSceneDocument {
        let image = try makeTestImage(width: 40, height: 30)
        return ScreenshotSceneDocument(sourceContext: .init(
            sourceBounds: .init(x: 0, y: 0, width: 40, height: 30),
            tileDescriptors: [],
            compositeSource: image
        ))
    }

    private func makeStep(number: Int, note: String = "") -> ScreenshotElement {
        ScreenshotElement(
            kind: .step,
            geometry: .step(
                badgeCenter: .init(x: 20 + Double(number * 10), y: 20),
                note: note.isEmpty ? nil : .init(x: 42, y: 8, width: 48, height: 24)
            ),
            text: note,
            stepNumber: number,
            appearance: .step()
        )
    }

    private func makeSourceContext() throws -> ScreenshotSourceContext {
        .init(
            sourceBounds: .init(x: 0, y: 0, width: 100, height: 80),
            tileDescriptors: [],
            compositeSource: try makeTestImage(width: 100, height: 80)
        )
    }

    private func makeRectangle(
        id: UUID,
        rect: ScreenshotPixelRect = .init(x: 2, y: 3, width: 10, height: 8)
    ) -> ScreenshotElement {
        ScreenshotElement(id: id, kind: .rectangle, geometry: .rect(rect), appearance: .init())
    }

    private func XCTAssertMagnifier(
        _ element: ScreenshotElement,
        hasCenter expectedCenter: ScreenshotPixelPoint,
        diameter expectedDiameter: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .magnifier(center) = element.geometry,
              case let .magnifier(appearance) = element.appearance.payload else {
            return XCTFail("Expected a magnifier element", file: file, line: line)
        }
        XCTAssertEqual(center, expectedCenter, file: file, line: line)
        XCTAssertEqual(
            appearance.diameter,
            expectedDiameter,
            accuracy: 0.000_001,
            file: file,
            line: line
        )
    }
}
private extension ScreenshotElementKind {
    var usesLineGeometry: Bool {
        self == .arrow || self == .line || self == .freehand
    }
}

func makeTestImage(
    width: Int,
    height: Int,
    pixels: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { x, y in
        let value = UInt8((x * 17 + y * 31) % 255)
        return (value, UInt8(255 - value), UInt8((x + y) % 255), 255)
    }
) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let pixel = pixels(x, y)
            let offset = (y * width + x) * 4
            bytes[offset] = pixel.0
            bytes[offset + 1] = pixel.1
            bytes[offset + 2] = pixel.2
            bytes[offset + 3] = pixel.3
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: width * 4,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          ) else {
        throw TestImageError.creationFailed
    }
    return image
}

private enum TestImageError: Error {
    case creationFailed
}
