import XCTest
@testable import BlocksScreenshotCore

final class ScreenshotGeometryTests: XCTestCase {
    func testCurvatureAnchorUsesHysteresisAroundStraightLine() {
        var anchor = ScreenshotCurvatureAnchor(
            initialValue: 0.4,
            enterThreshold: 0.06,
            exitThreshold: 0.09
        )

        let entered = anchor.resolve(0.05)
        XCTAssertEqual(entered.value, 0)
        XCTAssertTrue(entered.isAnchored)
        XCTAssertTrue(entered.didEnterAnchor)

        let held = anchor.resolve(0.08)
        XCTAssertEqual(held.value, 0)
        XCTAssertTrue(held.isAnchored)
        XCTAssertFalse(held.didEnterAnchor)

        let exited = anchor.resolve(0.1)
        XCTAssertEqual(exited.value, 0.1)
        XCTAssertFalse(exited.isAnchored)
        XCTAssertFalse(exited.didEnterAnchor)
    }

    func testCurvatureAnchorCanBeBypassedForPrecisionEditing() {
        var anchor = ScreenshotCurvatureAnchor(
            initialValue: 0,
            enterThreshold: 0.06,
            exitThreshold: 0.09
        )

        let bypassed = anchor.resolve(0.02, bypassesAnchor: true)

        XCTAssertEqual(bypassed.value, 0.02)
        XCTAssertFalse(bypassed.isAnchored)
        XCTAssertFalse(bypassed.didEnterAnchor)
    }

    func testCurveControlPointRoundTripsCurvature() {
        let start = ScreenshotPixelPoint(x: 10, y: 20)
        let end = ScreenshotPixelPoint(x: 110, y: 20)
        let control = ScreenshotGeometry.lineControlPoint(start: start, end: end, curvature: 0.6)

        XCTAssertEqual(control.x, 60, accuracy: 0.001)
        XCTAssertEqual(control.y, 50, accuracy: 0.001)
        XCTAssertEqual(
            ScreenshotGeometry.lineCurvature(start: start, end: end, control: control),
            0.6,
            accuracy: 0.001
        )
    }
    func testObjectHitResultsAreOrderedFrontToBackAndKeepTypedGeometry() {
        let bottom = ScreenshotElement(
            kind: .rectangle,
            geometry: .rect(.init(x: 10, y: 10, width: 40, height: 40)),
            appearance: .shape(.init(fillColor: .init(red: 1, green: 0, blue: 0, alpha: 1)))
        )
        let top = ScreenshotElement(
            kind: .callout,
            geometry: .callout(
                body: .init(x: 18, y: 18, width: 30, height: 24),
                pointer: .init(x: 52, y: 48)
            ),
            text: "A",
            appearance: .callout(.init())
        )

        let hits = ScreenshotGeometry.hitResults(
            at: .init(x: 24, y: 24),
            elements: [bottom, top],
            tolerance: 0
        )

        XCTAssertEqual(hits.map(\.elementID), [top.id, bottom.id])
        XCTAssertEqual(hits.first?.kind, .calloutNote)
    }

    func testCompositeCalloutKeepsConnectorEndsBoundToTargetAndNote() throws {
        let appearance = ScreenshotElementAppearance.callout(.init())
        let original = ScreenshotElement(
            kind: .callout,
            geometry: .calloutComposite(
                target: .ellipse(.init(x: 20, y: 20, width: 40, height: 30)),
                note: .init(x: 110, y: 20, width: 70, height: 32)
            ),
            text: "Note",
            appearance: appearance
        )
        let originalLayout = try XCTUnwrap(ScreenshotCalloutResolvedLayout(element: original))
        var bound = original
        guard case var .callout(boundAppearance) = bound.appearance.payload else {
            return XCTFail("Expected callout appearance")
        }
        boundAppearance.connectorAttachment = originalLayout.connectorAttachment
        bound.appearance.payload = .callout(boundAppearance)

        var movedTarget = bound
        movedTarget.geometry = .calloutComposite(
            target: .ellipse(.init(x: 40, y: 20, width: 40, height: 30)),
            note: originalLayout.noteRect
        )
        let targetLayout = try XCTUnwrap(ScreenshotCalloutResolvedLayout(element: movedTarget))
        XCTAssertEqual(targetLayout.connector.start, originalLayout.connector.start)
        XCTAssertNotEqual(targetLayout.connector.end, originalLayout.connector.end)

        var movedNote = bound
        movedNote.geometry = .calloutComposite(
            target: originalLayout.target,
            note: .init(x: 110, y: 42, width: 70, height: 32)
        )
        let noteLayout = try XCTUnwrap(ScreenshotCalloutResolvedLayout(element: movedNote))
        XCTAssertNotEqual(noteLayout.connector.start, originalLayout.connector.start)
        XCTAssertNotEqual(noteLayout.connector.end, originalLayout.connector.end)
        XCTAssertEqual(noteLayout.target, originalLayout.target)
        XCTAssertEqual(
            noteLayout.hitKind(at: noteLayout.connector.end, tolerance: 1),
            .calloutTarget
        )
    }

    func testLinkedAnnotationPlacementChoosesVisibleNearestSide() {
        let bounds = ScreenshotPixelRect(x: 0, y: 0, width: 300, height: 180)
        let rightEdgeTarget = ScreenshotPixelRect(x: 270, y: 70, width: 20, height: 20)

        let note = ScreenshotLinkedAnnotationLayout.noteRect(
            targetBounds: rightEdgeTarget,
            noteSize: CGSize(width: 100, height: 44),
            gap: 20,
            constrainedTo: bounds
        )

        XCTAssertLessThan(note.x + note.width, rightEdgeTarget.x)
        XCTAssertGreaterThanOrEqual(note.x, bounds.x)
        XCTAssertGreaterThanOrEqual(note.y, bounds.y)
        XCTAssertLessThanOrEqual(note.x + note.width, bounds.x + bounds.width)
        XCTAssertLessThanOrEqual(note.y + note.height, bounds.y + bounds.height)

        let leftEdgeTarget = ScreenshotPixelRect(x: 10, y: 70, width: 20, height: 20)
        let leftEdgeNote = ScreenshotLinkedAnnotationLayout.noteRect(
            targetBounds: leftEdgeTarget,
            noteSize: CGSize(width: 100, height: 44),
            gap: 20,
            constrainedTo: bounds
        )
        XCTAssertGreaterThan(leftEdgeNote.x, leftEdgeTarget.x + leftEdgeTarget.width)

        let topEdgeTarget = ScreenshotPixelRect(x: 140, y: 0, width: 20, height: 20)
        let topEdgeNote = ScreenshotLinkedAnnotationLayout.noteRect(
            targetBounds: topEdgeTarget,
            noteSize: CGSize(width: 260, height: 44),
            gap: 20,
            constrainedTo: bounds
        )
        XCTAssertGreaterThan(topEdgeNote.y, topEdgeTarget.y + topEdgeTarget.height)

        let bottomEdgeTarget = ScreenshotPixelRect(x: 140, y: 160, width: 20, height: 20)
        let bottomEdgeNote = ScreenshotLinkedAnnotationLayout.noteRect(
            targetBounds: bottomEdgeTarget,
            noteSize: CGSize(width: 260, height: 44),
            gap: 20,
            constrainedTo: bounds
        )
        XCTAssertLessThan(bottomEdgeNote.y + bottomEdgeNote.height, bottomEdgeTarget.y)
    }

    func testLegacyCalloutAttachmentIsIgnoredAndNotEncoded() throws {
        let legacy = ScreenshotCalloutConnectorAttachment(
            targetDirection: .init(x: -1, y: 0),
            notePosition: .init(x: 1, y: 1)
        )
        let appearance = ScreenshotCalloutAppearance(
            target: .init(),
            connector: .init(),
            note: .init(),
            connectorAttachment: legacy
        )
        let element = ScreenshotElement(
            kind: .callout,
            geometry: .calloutComposite(
                target: .ellipse(.init(x: 10, y: 10, width: 30, height: 30)),
                note: .init(x: 100, y: 10, width: 80, height: 44)
            ),
            appearance: .callout(appearance)
        )

        let layout = try XCTUnwrap(ScreenshotCalloutResolvedLayout(element: element))
        XCTAssertGreaterThan(layout.connector.end.x, 39)
        let encoded = try JSONEncoder().encode(appearance)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("connectorAttachment"))
    }

    func testSourceBoundsAndLineEndpoints() {
        let line = ScreenshotElementGeometry.line(
            start: .init(x: 20, y: 18),
            end: .init(x: 2, y: 3)
        )

        XCTAssertEqual(ScreenshotGeometry.bounds(of: line), .init(x: 2, y: 3, width: 18, height: 15))
        XCTAssertEqual(
            ScreenshotGeometry.lineEndpoints(of: line),
            .init(start: .init(x: 20, y: 18), end: .init(x: 2, y: 3))
        )
    }

    func testEightDirectionalResize() {
        let rect = ScreenshotPixelRect(x: 10, y: 10, width: 20, height: 20)
        let cases: [(ScreenshotResizeHandle, ScreenshotPixelPoint, ScreenshotPixelRect)] = [
            (.northWest, .init(x: 5, y: 6), .init(x: 5, y: 6, width: 25, height: 24)),
            (.north, .init(x: 20, y: 6), .init(x: 10, y: 6, width: 20, height: 24)),
            (.northEast, .init(x: 35, y: 6), .init(x: 10, y: 6, width: 25, height: 24)),
            (.east, .init(x: 35, y: 20), .init(x: 10, y: 10, width: 25, height: 20)),
            (.southEast, .init(x: 35, y: 36), .init(x: 10, y: 10, width: 25, height: 26)),
            (.south, .init(x: 20, y: 36), .init(x: 10, y: 10, width: 20, height: 26)),
            (.southWest, .init(x: 5, y: 36), .init(x: 5, y: 10, width: 25, height: 26)),
            (.west, .init(x: 5, y: 20), .init(x: 5, y: 10, width: 25, height: 20)),
        ]

        for (handle, point, expected) in cases {
            XCTAssertEqual(ScreenshotGeometry.resize(rect, handle: handle, to: point), expected, "\(handle)")
        }
    }

    func testResizeNormalizesWhenDraggedThroughOppositeEdge() {
        let rect = ScreenshotPixelRect(x: 10, y: 10, width: 20, height: 20)

        XCTAssertEqual(
            ScreenshotGeometry.resize(rect, handle: .northWest, to: .init(x: 40, y: 45)),
            .init(x: 30, y: 30, width: 10, height: 15)
        )
    }

    func testHitTestUsesLineWidthAndPathSegments() {
        let line = ScreenshotElement(
            kind: .line,
            geometry: .line(start: .init(x: 0, y: 0), end: .init(x: 20, y: 0)),
            appearance: .init(lineWidth: 6)
        )
        let path = ScreenshotElement(
            kind: .freehand,
            geometry: .path([.init(x: 0, y: 10), .init(x: 20, y: 10)]),
            appearance: .init(lineWidth: 4)
        )

        XCTAssertTrue(ScreenshotGeometry.hitTest(.init(x: 10, y: 3), element: line, tolerance: 0))
        XCTAssertFalse(ScreenshotGeometry.hitTest(.init(x: 10, y: 3.1), element: line, tolerance: 0))
        XCTAssertTrue(ScreenshotGeometry.hitTest(.init(x: 10, y: 12), element: path, tolerance: 0))
        XCTAssertFalse(ScreenshotGeometry.hitTest(.init(x: 10, y: 12.1), element: path, tolerance: 0))
    }

    func testArrowWithNoneEndingDoesNotKeepAPhantomArrowHitArea() {
        let arrow = ScreenshotElement(
            kind: .arrow,
            geometry: .line(start: .init(x: 0, y: 10), end: .init(x: 20, y: 10)),
            appearance: .init(lineWidth: 2, endEnding: .none)
        )

        XCTAssertFalse(ScreenshotGeometry.hitTest(.init(x: 14, y: 12), element: arrow, tolerance: 0))
    }

    func testHitTestDistinguishesHollowAndFilledRectangles() {
        let hollow = ScreenshotElement(
            kind: .rectangle,
            geometry: .rect(.init(x: 10, y: 10, width: 20, height: 16)),
            appearance: .init(lineWidth: 2)
        )
        var filled = hollow
        filled.appearance.fillColor = .init(red: 1, green: 0, blue: 0, alpha: 1)

        XCTAssertTrue(ScreenshotGeometry.hitTest(.init(x: 10, y: 18), element: hollow, tolerance: 0))
        XCTAssertFalse(ScreenshotGeometry.hitTest(.init(x: 20, y: 18), element: hollow, tolerance: 0))
        XCTAssertTrue(ScreenshotGeometry.hitTest(.init(x: 20, y: 18), element: filled, tolerance: 0))
    }

    func testHitTestUsesEllipseInsteadOfBoundingRectangle() {
        let hollow = ScreenshotElement(
            kind: .ellipse,
            geometry: .rect(.init(x: 10, y: 10, width: 20, height: 20)),
            appearance: .init(lineWidth: 2)
        )
        var filled = hollow
        filled.appearance.fillColor = .init(red: 1, green: 0, blue: 0, alpha: 1)

        XCTAssertFalse(ScreenshotGeometry.hitTest(.init(x: 11, y: 11), element: hollow, tolerance: 0))
        XCTAssertTrue(ScreenshotGeometry.hitTest(.init(x: 20, y: 10), element: hollow, tolerance: 0))
        XCTAssertFalse(ScreenshotGeometry.hitTest(.init(x: 20, y: 20), element: hollow, tolerance: 0))
        XCTAssertTrue(ScreenshotGeometry.hitTest(.init(x: 20, y: 20), element: filled, tolerance: 0))
        XCTAssertTrue(ScreenshotGeometry.hitTestHandle(.init(x: 9, y: 9), rect: .init(x: 10, y: 10, width: 20, height: 15), tolerance: 2) == .northWest)
    }

    func testTranslateAndClampRemainInSourceSpace() {
        let geometry = ScreenshotElementGeometry.path([
            .init(x: 2, y: 3),
            .init(x: 8, y: 9),
        ])
        XCTAssertEqual(
            ScreenshotGeometry.translate(geometry, dx: 4, dy: -2),
            .path([.init(x: 6, y: 1), .init(x: 12, y: 7)])
        )
        XCTAssertEqual(
            ScreenshotGeometry.clamp(
                .rect(.init(x: 35, y: -4, width: 12, height: 10)),
                to: .init(x: 0, y: 0, width: 40, height: 30)
            ),
            .rect(.init(x: 28, y: 0, width: 12, height: 10))
        )
    }

    func testTranslateWithinBoundsPreservesLineAndPathShape() {
        let bounds = ScreenshotPixelRect(x: 0, y: 0, width: 40, height: 30)
        let line = ScreenshotElementGeometry.line(
            start: .init(x: 30, y: 10),
            end: .init(x: 38, y: 20)
        )
        let path = ScreenshotElementGeometry.path([
            .init(x: 2, y: 3),
            .init(x: 8, y: 9),
        ])

        XCTAssertEqual(
            ScreenshotGeometry.translateWithinBounds(line, dx: 20, dy: 0, bounds: bounds),
            .line(start: .init(x: 32, y: 10), end: .init(x: 40, y: 20))
        )
        XCTAssertEqual(
            ScreenshotGeometry.translateWithinBounds(path, dx: -20, dy: -20, bounds: bounds),
            .path([.init(x: 0, y: 0), .init(x: 6, y: 6)])
        )
    }

    func testElementAwareTranslationKeepsCounterBodyInsideSourceBounds() {
        let counter = ScreenshotElement(
            kind: .counter,
            geometry: .counter(center: .init(x: 20, y: 20)),
            text: "1",
            appearance: .counter(.init(size: 40))
        )
        let bounds = ScreenshotPixelRect(x: 0, y: 0, width: 100, height: 100)

        XCTAssertEqual(
            ScreenshotGeometry.translateWithinBounds(counter, dx: -50, dy: -50, bounds: bounds),
            .counter(center: .init(x: 20, y: 20))
        )
        XCTAssertEqual(
            ScreenshotGeometry.translateWithinBounds(counter, dx: 100, dy: 100, bounds: bounds),
            .counter(center: .init(x: 80, y: 80))
        )
    }

    func testStepBoundsAndTranslationTreatBadgeAndNoteAsOneElement() {
        let step = ScreenshotElement(
            kind: .step,
            geometry: .step(
                badgeCenter: .init(x: 20, y: 20),
                note: .init(x: 40, y: 8, width: 50, height: 24)
            ),
            text: "Build",
            stepNumber: 1,
            appearance: .step(.init(badgeSize: 28, gap: 6))
        )

        XCTAssertEqual(
            ScreenshotGeometry.bounds(of: step),
            .init(x: 6, y: 6, width: 84, height: 28)
        )
        XCTAssertEqual(
            ScreenshotGeometry.translate(step.geometry, dx: 5, dy: 7),
            .step(
                badgeCenter: .init(x: 25, y: 27),
                note: .init(x: 45, y: 15, width: 50, height: 24)
            )
        )
    }

    func testStepResolvedLayoutKeepsRawPartsAndConnectsTheirNearestEdges() throws {
        let note = ScreenshotPixelRect(x: 46, y: 10, width: 40, height: 20)
        let step = ScreenshotElement(
            kind: .step,
            geometry: .step(badgeCenter: .init(x: 20.5, y: 20), note: note),
            text: "Build",
            stepNumber: 1,
            appearance: .step(.init(badgeSize: 28, noteBorderWidth: 2, gap: 12))
        )

        let layout = try XCTUnwrap(ScreenshotStepResolvedLayout(element: step))
        let connector = try XCTUnwrap(layout.connector)

        XCTAssertEqual(layout.badgeCenter, .init(x: 20.5, y: 20))
        XCTAssertEqual(layout.badgeDiameter, 28)
        XCTAssertEqual(layout.badgeRect, .init(x: 6, y: 6, width: 29, height: 28))
        XCTAssertEqual(layout.badgeTextRect, .init(x: 6, y: 9, width: 28, height: 21))
        XCTAssertEqual(layout.badgeFontSize, 12.88, accuracy: 0.001)
        XCTAssertEqual(layout.connectorLineWidth, 2)
        XCTAssertEqual(layout.noteRect, note, "Resolving layout must not move the independently positioned note")
        XCTAssertEqual(connector.start.x, 34.5, accuracy: 0.001)
        XCTAssertEqual(connector.start.y, 20, accuracy: 0.001)
        XCTAssertEqual(connector.end, .init(x: 46, y: 20))
        XCTAssertEqual(layout.bounds, .init(x: 6, y: 6, width: 80, height: 28))
    }

    func testStepHitResultsIdentifyBadgeNoteAndConnectorParts() {
        let step = ScreenshotElement(
            kind: .step,
            geometry: .step(
                badgeCenter: .init(x: 20, y: 20),
                note: .init(x: 46, y: 10, width: 40, height: 20)
            ),
            text: "Build",
            stepNumber: 1,
            appearance: .step(.init(badgeSize: 28, noteBorderWidth: 1, gap: 12))
        )

        XCTAssertEqual(
            ScreenshotGeometry.hitResults(at: .init(x: 20, y: 20), elements: [step], tolerance: 0).first?.kind,
            .stepBadge
        )
        XCTAssertEqual(
            ScreenshotGeometry.hitResults(at: .init(x: 60, y: 20), elements: [step], tolerance: 0).first?.kind,
            .stepNote
        )
        XCTAssertEqual(
            ScreenshotGeometry.hitResults(at: .init(x: 40, y: 20), elements: [step], tolerance: 0).first?.kind,
            .stepConnector
        )
    }

    func testStepCurvedConnectorUsesOneSharedPathForBoundsAndHitTesting() throws {
        var appearance = ScreenshotStepAppearance(badgeSize: 28, gap: 12)
        appearance.connector.curvature = 1
        let step = ScreenshotElement(
            kind: .step,
            geometry: .step(
                badgeCenter: .init(x: 20, y: 40),
                note: .init(x: 80, y: 30, width: 50, height: 24)
            ),
            text: "Build",
            stepNumber: 1,
            appearance: .step(appearance)
        )

        let layout = try XCTUnwrap(ScreenshotStepResolvedLayout(element: step))
        let control = try XCTUnwrap(layout.connectorControlPoint)
        let connectorBounds = try XCTUnwrap(layout.connectorBounds)
        let connectorRect = CGRect(
            x: connectorBounds.x,
            y: connectorBounds.y,
            width: connectorBounds.width,
            height: connectorBounds.height
        )
        let layoutRect = CGRect(
            x: layout.bounds.x,
            y: layout.bounds.y,
            width: layout.bounds.width,
            height: layout.bounds.height
        )
        let connector = try XCTUnwrap(layout.connector)
        let curveMidpoint = ScreenshotPixelPoint(
            x: connector.start.x * 0.25 + control.x * 0.5 + connector.end.x * 0.25,
            y: connector.start.y * 0.25 + control.y * 0.5 + connector.end.y * 0.25
        )

        XCTAssertTrue(
            connectorRect.insetBy(dx: -1, dy: -1).contains(
                CGPoint(x: control.x, y: control.y)
            )
        )
        XCTAssertEqual(layout.hitKind(at: curveMidpoint, tolerance: 1), .stepConnector)
        XCTAssertTrue(layoutRect.contains(connectorRect))
    }

    func testStepHitResolutionPrefersActualAndThenNearestSubtargetAtLargeTolerance() {
        let step = ScreenshotElement(
            kind: .step,
            geometry: .step(
                badgeCenter: .init(x: 20, y: 20),
                note: .init(x: 42, y: 10, width: 40, height: 20)
            ),
            text: "Build",
            stepNumber: 1,
            appearance: .step(.init(badgeSize: 28, noteBorderWidth: 1, gap: 8))
        )

        XCTAssertEqual(
            ScreenshotGeometry.hitResults(
                at: .init(x: 43, y: 20),
                elements: [step],
                tolerance: 20
            ).first?.kind,
            .stepNote,
            "An actual note hit must beat the badge's enlarged tolerance"
        )
        XCTAssertEqual(
            ScreenshotGeometry.hitResults(
                at: .init(x: 39, y: 20),
                elements: [step],
                tolerance: 20
            ).first?.kind,
            .stepNote,
            "The nearer subtarget must win when both tolerance regions overlap"
        )
        XCTAssertEqual(
            ScreenshotGeometry.hitResults(
                at: .init(x: 37, y: 20),
                elements: [step],
                tolerance: 20
            ).first?.kind,
            .stepBadge
        )
    }

    func testStepPartConstraintsOnlyResolveThePartBeingOperated() {
        let bounds = ScreenshotPixelRect(x: 0, y: 0, width: 100, height: 70)
        let originalBadge = ScreenshotPixelPoint(x: 20, y: 20)
        let originalNote = ScreenshotPixelRect(x: 40, y: 10, width: 50, height: 24)

        let resolvedNote = ScreenshotStepResolvedLayout.constrainedNoteRect(
            .init(x: 24, y: 10, width: 50, height: 24),
            badgeCenter: originalBadge,
            badgeDiameter: 28,
            gap: 12,
            constrainedTo: bounds
        )
        let resolvedBadge = ScreenshotStepResolvedLayout.constrainedBadgeCenter(
            .init(x: 48, y: 20),
            badgeDiameter: 28,
            noteRect: originalNote,
            gap: 12,
            constrainedTo: bounds
        )

        XCTAssertEqual(originalBadge, .init(x: 20, y: 20), "Constraining the note must not mutate the badge")
        XCTAssertEqual(originalNote, .init(x: 40, y: 10, width: 50, height: 24), "Constraining the badge must not mutate the note")
        XCTAssertGreaterThanOrEqual(resolvedNote.x, 46)
        XCTAssertLessThanOrEqual(resolvedNote.x + resolvedNote.width, bounds.x + bounds.width)
        XCTAssertLessThanOrEqual(resolvedBadge.x, 14.001)
        XCTAssertGreaterThanOrEqual(resolvedBadge.x, 13.999)
    }

    func testStepPartConstraintsKeepCurrentPartInsideSmallBoundsAndMaximizeAvailableGap() {
        let bounds = ScreenshotPixelRect(x: 0, y: 0, width: 64, height: 40)
        let note = ScreenshotPixelRect(x: 18, y: 4, width: 42, height: 32)

        let badge = ScreenshotStepResolvedLayout.constrainedBadgeCenter(
            .init(x: 32, y: 20),
            badgeDiameter: 20,
            noteRect: note,
            gap: 12,
            constrainedTo: bounds
        )

        XCTAssertGreaterThanOrEqual(badge.x - 10, Double(bounds.x))
        XCTAssertLessThanOrEqual(badge.x + 10, Double(bounds.x + bounds.width))
        XCTAssertGreaterThanOrEqual(badge.y - 10, Double(bounds.y))
        XCTAssertLessThanOrEqual(badge.y + 10, Double(bounds.y + bounds.height))
        XCTAssertTrue(badge.x == 10 || badge.x == 54 || badge.y == 10 || badge.y == 30)
    }

    func testMagnifierResolvedLayoutUsesAppearanceDiameterAndKeepsCircleInsideSource() throws {
        let magnifier = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 5, y: 5)),
            appearance: .magnifier(.init(zoom: 2, diameter: 120))
        )

        let layout = try XCTUnwrap(ScreenshotMagnifierResolvedLayout(
            element: magnifier,
            constrainedTo: .init(x: 0, y: 0, width: 100, height: 80)
        ))

        XCTAssertEqual(layout.diameter, 80)
        XCTAssertEqual(layout.center, .init(x: 40, y: 40))
        XCTAssertEqual(layout.lensRect, .init(x: 0, y: 0, width: 80, height: 80))
        XCTAssertEqual(ScreenshotGeometry.bounds(of: magnifier), .init(x: -55, y: -55, width: 120, height: 120))
    }

    func testMagnifierResolvedLayoutShrinksBelowMinimumForASmallerSource() throws {
        let magnifier = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 4, y: 4)),
            appearance: .magnifier(.init(zoom: 2, diameter: 120))
        )

        let layout = try XCTUnwrap(ScreenshotMagnifierResolvedLayout(
            element: magnifier,
            constrainedTo: .init(x: 0, y: 0, width: 40, height: 30)
        ))

        XCTAssertEqual(layout.diameter, 30)
        XCTAssertEqual(layout.center, .init(x: 15, y: 15))
        XCTAssertEqual(layout.lensRect, .init(x: 0, y: 0, width: 30, height: 30))
    }

    func testMagnifierResolvedLayoutSnapsOddDiameterToASquarePixelGrid() throws {
        let magnifier = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 60.5, y: 50)),
            appearance: .magnifier(.init(zoom: 2, diameter: 121))
        )

        let layout = try XCTUnwrap(ScreenshotMagnifierResolvedLayout(element: magnifier))

        XCTAssertEqual(layout.diameter, 121)
        XCTAssertEqual(layout.center, .init(x: 60.5, y: 49.5))
        XCTAssertEqual(layout.lensRect, .init(x: 0, y: -11, width: 121, height: 121))
        XCTAssertEqual(layout.lensRect.width, layout.lensRect.height)
    }

    func testMagnifierResolvedLayoutQuantizesFractionalDiameterBeforeConstraining() throws {
        let magnifier = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 100.3, y: 90.7)),
            appearance: .magnifier(.init(zoom: 2, diameter: 120.2))
        )

        let layout = try XCTUnwrap(ScreenshotMagnifierResolvedLayout(
            element: magnifier,
            constrainedTo: .init(x: 20, y: 30, width: 180, height: 140)
        ))

        XCTAssertEqual(layout.diameter, 120)
        XCTAssertEqual(layout.center, .init(x: 100, y: 91))
        XCTAssertEqual(layout.lensRect, .init(x: 40, y: 31, width: 120, height: 120))
    }

    func testMagnifierHitTestingUsesTheCanvasConstrainedLensOnAShortSource() {
        let magnifier = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 50, y: 15)),
            appearance: .magnifier(.init(zoom: 2, diameter: 30))
        )
        let bounds = ScreenshotPixelRect(x: 0, y: 0, width: 100, height: 30)

        XCTAssertTrue(ScreenshotGeometry.hitTest(
            .init(x: 78, y: 15),
            element: magnifier,
            tolerance: 0
        ))
        XCTAssertFalse(ScreenshotGeometry.hitTest(
            .init(x: 78, y: 15),
            element: magnifier,
            tolerance: 0,
            constrainedTo: bounds
        ))
    }

    func testConstrainedResizePreservesOppositeAnchorAtBounds() {
        let bounds = ScreenshotPixelRect(x: 0, y: 0, width: 40, height: 30)
        let rect = ScreenshotPixelRect(x: 10, y: 8, width: 20, height: 14)

        XCTAssertEqual(
            ScreenshotGeometry.resize(rect, handle: .east, to: .init(x: 80, y: 15), constrainedTo: bounds),
            .init(x: 10, y: 8, width: 30, height: 14)
        )
        XCTAssertEqual(
            ScreenshotGeometry.resize(rect, handle: .northWest, to: .init(x: -20, y: -10), constrainedTo: bounds),
            .init(x: 0, y: 0, width: 30, height: 22)
        )
    }

    func testHorizontalLineOnCropEdgeStillIntersects() {
        let line = ScreenshotElementGeometry.line(
            start: .init(x: 0, y: 0),
            end: .init(x: 20, y: 0)
        )

        XCTAssertTrue(ScreenshotGeometry.intersects(line, rect: .init(x: 0, y: 0, width: 20, height: 10)))
    }
}
