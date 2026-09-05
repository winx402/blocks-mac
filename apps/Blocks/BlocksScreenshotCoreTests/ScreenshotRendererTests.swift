import CoreGraphics
import ImageIO
import XCTest
@testable import BlocksScreenshotCore

final class ScreenshotRendererTests: XCTestCase {
    private let renderer = ScreenshotRenderer()
    private let encoder = ScreenshotImageEncoder()

    func testRenderAppliesElementsInSourceSpaceThenProducesCropDimensions() throws {
        let source = try makeTestImage(width: 48, height: 36) { _, _ in (255, 255, 255, 255) }
        let snapshot = ScreenshotSceneSnapshot(
            cropRect: .init(x: 8, y: 6, width: 24, height: 18),
            elements: [makeElement(.rectangle, rect: .init(x: 10, y: 8, width: 12, height: 8))]
        )

        let rendered = try renderer.render(source: source, snapshot: snapshot)

        XCTAssertEqual(rendered.width, 24)
        XCTAssertEqual(rendered.height, 18)
        XCTAssertNotEqual(try rgbaPixels(rendered), try rgbaPixels(try crop(source, to: snapshot.cropRect)))
    }

    func testEveryElementKindChangesRenderedPixels() throws {
        let source = try makeTestImage(width: 96, height: 72)

        for kind in ScreenshotElementKind.allCases {
            let snapshot = ScreenshotSceneSnapshot(
                cropRect: .init(x: 0, y: 0, width: 96, height: 72),
                elements: [makeElement(kind)]
            )
            let rendered = try renderer.render(source: source, snapshot: snapshot)
            XCTAssertNotEqual(try rgbaPixels(rendered), try rgbaPixels(source), "\(kind) did not render")
        }
    }

    func testStepRendersBadgeAndAttachedNoteAsOneElement() throws {
        let source = try makeTestImage(width: 140, height: 64) { _, _ in (255, 255, 255, 255) }
        let appearance = ScreenshotStepAppearance(
            badgeFillColor: .init(red: 0.9, green: 0.1, blue: 0.1, alpha: 1),
            noteBackgroundColor: .init(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
            noteTextColor: .white
        )
        let withNote = ScreenshotElement(
            kind: .step,
            geometry: .step(
                badgeCenter: .init(x: 24, y: 32),
                note: .init(x: 44, y: 16, width: 84, height: 32)
            ),
            text: "Install",
            stepNumber: 2,
            appearance: .step(appearance)
        )
        var badgeOnly = withNote
        badgeOnly.geometry = .step(badgeCenter: .init(x: 24, y: 32), note: nil)
        badgeOnly.text = ""

        let notedPixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 140, height: 64), elements: [withNote])
        ))
        let badgePixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 140, height: 64), elements: [badgeOnly])
        ))

        XCTAssertNotEqual(notedPixels, badgePixels)
        XCTAssertGreaterThan(changedPixelCount(notedPixels), changedPixelCount(badgePixels))
    }

    func testStepWithEmptyTextExportsOnlyTheBadge() throws {
        let source = try makeTestImage(width: 120, height: 64) { _, _ in (255, 255, 255, 255) }
        let appearance = ScreenshotStepAppearance(
            badgeFillColor: .init(red: 1, green: 1, blue: 1, alpha: 1),
            badgeBorderColor: .init(red: 1, green: 1, blue: 1, alpha: 1),
            noteBackgroundColor: .init(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
            noteBorderColor: .init(red: 1, green: 0, blue: 0, alpha: 1),
            noteBorderWidth: 2,
            gap: 12
        )
        let editingBase = ScreenshotElement(
            kind: .step,
            geometry: .step(
                badgeCenter: .init(x: 24, y: 32),
                note: .init(x: 50, y: 16, width: 58, height: 32)
            ),
            text: "",
            stepNumber: 2,
            appearance: .step(appearance)
        )
        var badgeOnly = editingBase
        badgeOnly.geometry = .step(badgeCenter: .init(x: 24, y: 32), note: nil)
        let editingPixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 120, height: 64), elements: [editingBase])
        ))
        let badgePixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 120, height: 64), elements: [badgeOnly])
        ))
        XCTAssertEqual(editingPixels, badgePixels, "Empty step notes are editor-only placeholders")
    }

    func testStepBadgeSizeChangesRenderedBadgeAndNumberScale() throws {
        let source = try makeTestImage(width: 120, height: 80) { _, _ in (255, 255, 255, 255) }
        let small = ScreenshotElement(
            kind: .step,
            geometry: .step(badgeCenter: .init(x: 40, y: 40), note: nil),
            text: "",
            stepNumber: 8,
            appearance: .step(.init(badgeSize: 28))
        )
        var large = small
        large.appearance = .step(.init(badgeSize: 56))

        let smallPixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 120, height: 80), elements: [small])
        ))
        let largePixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 120, height: 80), elements: [large])
        ))

        XCTAssertGreaterThan(changedPixelCount(largePixels), changedPixelCount(smallPixels) * 2)
    }

    func testMagnifierPreservesTopLeftOrientationAndMagnifiesInPlace() throws {
        let source = try makeTestImage(width: 120, height: 90) { x, y in
            guard (45..<75).contains(x), (15..<45).contains(y) else { return (255, 255, 255, 255) }
            switch (x < 60, y < 30) {
            case (true, true): return (255, 0, 0, 255)
            case (false, true): return (0, 255, 0, 255)
            case (true, false): return (0, 0, 255, 255)
            case (false, false): return (255, 255, 0, 255)
            }
        }
        let magnifier = makeMagnifier(center: .init(x: 60, y: 30), diameter: 60, zoom: 2)

        let rendered = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 120, height: 90), elements: [magnifier])
        )
        let pixels = try rgbaPixels(rendered)

        assertPixel(pixel(atX: 42, y: 12, width: 120, bytes: pixels), near: [255, 0, 0, 255])
        assertPixel(pixel(atX: 78, y: 12, width: 120, bytes: pixels), near: [0, 255, 0, 255])
        assertPixel(pixel(atX: 42, y: 48, width: 120, bytes: pixels), near: [0, 0, 255, 255])
        assertPixel(pixel(atX: 78, y: 48, width: 120, bytes: pixels), near: [255, 255, 0, 255])
        XCTAssertEqual(pixel(atX: 60, y: 72, width: 120, bytes: pixels), [255, 255, 255, 255])
    }

    func testMagnifierDiameterAndZoomBothChangeRenderedPixels() throws {
        let source = try makeTestImage(width: 160, height: 120)
        let small = makeMagnifier(center: .init(x: 80, y: 60), diameter: 60, zoom: 2)
        let large = makeMagnifier(center: .init(x: 80, y: 60), diameter: 120, zoom: 2)
        let strongZoom = makeMagnifier(center: .init(x: 80, y: 60), diameter: 60, zoom: 5)

        let smallPixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 160, height: 120), elements: [small])
        ))
        let largePixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 160, height: 120), elements: [large])
        ))
        let strongPixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 160, height: 120), elements: [strongZoom])
        ))

        XCTAssertNotEqual(smallPixels, largePixels, "Diameter must be part of the rendered lens geometry")
        XCTAssertNotEqual(smallPixels, strongPixels, "Zoom must change the sampled source extent")
    }

    func testMagnifierCropConstrainsLensAndSamplingToTheOutput() throws {
        let source = try makeTestImage(width: 160, height: 120)
        let magnifier = makeMagnifier(center: .init(x: 78, y: 58), diameter: 100, zoom: 4)
        let cropRect = ScreenshotPixelRect(x: 96, y: 42, width: 28, height: 34)

        let full = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 160, height: 120), elements: [magnifier])
        )
        let cropped = try renderer.render(
            source: source,
            snapshot: .init(cropRect: cropRect, elements: [magnifier])
        )

        XCTAssertNotEqual(
            try rgbaPixels(cropped),
            try rgbaPixels(try crop(full, to: cropRect)),
            "The lens must be resolved inside the current output instead of preserving an off-crop full-canvas position"
        )
        let constrainedLens = try XCTUnwrap(ScreenshotMagnifierResolvedLayout(
            element: magnifier,
            constrainedTo: cropRect
        ))
        XCTAssertEqual(constrainedLens.lensRect, .init(x: 96, y: 44, width: 28, height: 28))
        let plan = try renderer.makeRenderPlan(
            sourceWidth: 160,
            sourceHeight: 120,
            snapshot: .init(cropRect: cropRect, elements: [magnifier])
        )
        XCTAssertEqual(plan.elementIndexes, [0])
        XCTAssertEqual(plan.effectBoundaryCount, 1)
        XCTAssertTrue(plan.workingRect.contains(CGRect(
            x: constrainedLens.lensRect.x,
            y: constrainedLens.lensRect.y,
            width: constrainedLens.lensRect.width,
            height: constrainedLens.lensRect.height
        )))
        XCTAssertTrue(plan.workingRect.contains(CGRect(
            x: cropRect.x,
            y: cropRect.y,
            width: cropRect.width,
            height: cropRect.height
        )))
    }

    func testMagnifierSamplesOnlyEarlierLayers() throws {
        let source = try makeTestImage(width: 120, height: 90) { _, _ in (255, 255, 255, 255) }
        let mark = ScreenshotElement(
            kind: .rectangle,
            geometry: .rect(.init(x: 54, y: 24, width: 12, height: 12)),
            appearance: .shape(.init(
                strokeColor: .init(red: 0, green: 0, blue: 0, alpha: 1),
                fillColor: .init(red: 0, green: 0, blue: 0, alpha: 1),
                fillOpacity: 1,
                strokeWidth: 1
            ))
        )
        let magnifier = makeMagnifier(center: .init(x: 60, y: 30), diameter: 60, zoom: 3)

        let markThenLens = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 120, height: 90), elements: [mark, magnifier])
        )
        let lensThenMark = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 120, height: 90), elements: [magnifier, mark])
        )

        XCTAssertNotEqual(try rgbaPixels(markThenLens), try rgbaPixels(lensThenMark))
    }

    func testMagnifierShadowProducesVisiblePixelsOutsideTheLens() throws {
        let source = try makeTestImage(width: 120, height: 90) { _, _ in (255, 255, 255, 255) }
        let noShadow = makeMagnifier(center: .init(x: 60, y: 45), diameter: 60, zoom: 2)
        var withShadow = noShadow
        withShadow.appearance = .magnifier(.init(
            zoom: 2,
            diameter: 60,
            borderColor: .init(red: 0, green: 0, blue: 0, alpha: 0),
            borderWidth: 0,
            shadow: 1
        ))

        let plainPixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 120, height: 90), elements: [noShadow])
        ))
        let shadowPixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 120, height: 90), elements: [withShadow])
        ))

        XCTAssertNotEqual(shadowPixels, plainPixels)
        XCTAssertNotEqual(
            pixel(atX: 94, y: 45, width: 120, bytes: shadowPixels),
            pixel(atX: 94, y: 45, width: 120, bytes: plainPixels),
            "The shadow must affect pixels outside the 60pt lens"
        )
    }

    func testMagnifierShadowDoesNotFillTransparentSamplePixelsBlack() throws {
        let source = try makeTestImage(width: 120, height: 90) { x, y in
            if (45..<52).contains(x), (30..<60).contains(y) {
                return (255, 0, 0, 255)
            }
            return (0, 0, 0, 0)
        }
        let magnifier = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 60, y: 45)),
            appearance: .magnifier(.init(
                zoom: 2,
                diameter: 60,
                borderColor: .init(red: 0, green: 0, blue: 0, alpha: 0),
                borderWidth: 0,
                shadow: 1
            ))
        )

        let pixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(
                cropRect: .init(x: 0, y: 0, width: 120, height: 90),
                elements: [magnifier]
            )
        ))

        XCTAssertEqual(
            pixel(atX: 60, y: 45, width: 120, bytes: pixels)[3],
            0,
            "Transparent sampled pixels must replace the opaque shadow caster"
        )
        XCTAssertGreaterThan(
            pixel(atX: 94, y: 45, width: 120, bytes: pixels)[3],
            0,
            "The same shadow must remain visible outside the lens"
        )
    }

    func testMagnifierShadowOnlyCropConstrainsTheLensToTheOutput() throws {
        let source = try makeTestImage(width: 120, height: 90) { _, _ in (255, 255, 255, 255) }
        let magnifier = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 60, y: 45)),
            appearance: .magnifier(.init(
                zoom: 2,
                diameter: 60,
                borderColor: .init(red: 0, green: 0, blue: 0, alpha: 0),
                borderWidth: 0,
                shadow: 1
            ))
        )
        let shadowOnlyCrop = ScreenshotPixelRect(x: 92, y: 39, width: 6, height: 12)

        let full = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 120, height: 90), elements: [magnifier])
        )
        let direct = try renderer.render(
            source: source,
            snapshot: .init(cropRect: shadowOnlyCrop, elements: [magnifier])
        )

        XCTAssertNotEqual(
            try rgbaPixels(direct),
            try rgbaPixels(try crop(full, to: shadowOnlyCrop)),
            "A crop change must keep the complete lens in the current output instead of leaving only an old off-crop shadow"
        )
        XCTAssertNotEqual(
            try rgbaPixels(direct),
            try rgbaPixels(try crop(source, to: shadowOnlyCrop)),
            "A crop wholly outside the lens must still include its visible shadow"
        )
    }

    func testMagnifierBorderIsDrawnInsideItsCanvasConstrainedDiameter() throws {
        let source = try makeTestImage(width: 90, height: 90) { _, _ in (255, 255, 255, 255) }
        let magnifier = ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: .init(x: 30, y: 30)),
            appearance: .magnifier(.init(
                zoom: 2,
                diameter: 60,
                borderColor: .init(red: 1, green: 0, blue: 0, alpha: 1),
                borderWidth: 12,
                shadow: 0
            ))
        )

        let pixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 90, height: 90), elements: [magnifier])
        ))

        assertPixel(pixel(atX: 10, y: 30, width: 90, bytes: pixels), near: [255, 0, 0, 255])
        assertPixel(pixel(atX: 30, y: 10, width: 90, bytes: pixels), near: [255, 0, 0, 255])
        assertPixel(pixel(atX: 15, y: 30, width: 90, bytes: pixels), near: [255, 255, 255, 255])
    }

    func testElementsOutsideCropAreNotRendered() throws {
        let source = try makeTestImage(width: 48, height: 36) { _, _ in (255, 255, 255, 255) }
        let cropRect = ScreenshotPixelRect(x: 0, y: 0, width: 20, height: 16)
        let snapshot = ScreenshotSceneSnapshot(
            cropRect: cropRect,
            elements: [makeElement(.rectangle, rect: .init(x: 30, y: 24, width: 10, height: 8))]
        )

        XCTAssertEqual(
            try rgbaPixels(renderer.render(source: source, snapshot: snapshot)),
            try rgbaPixels(try crop(source, to: cropRect))
        )
    }

    func testThickLineWhoseCenterlineIsOutsideCropStillRendersIntoCrop() throws {
        let source = try makeTestImage(width: 32, height: 24) { _, _ in (255, 255, 255, 255) }
        let cropRect = ScreenshotPixelRect(x: 10, y: 4, width: 12, height: 16)
        let line = ScreenshotElement(
            kind: .line,
            geometry: .line(start: .init(x: 8, y: 5), end: .init(x: 8, y: 19)),
            appearance: .init(strokeColor: .init(red: 0, green: 0, blue: 0, alpha: 1), lineWidth: 6)
        )

        let rendered = try renderer.render(
            source: source,
            snapshot: .init(cropRect: cropRect, elements: [line])
        )

        XCTAssertNotEqual(try rgbaPixels(rendered), try rgbaPixels(try crop(source, to: cropRect)))
    }

    func testSourceContextWithNonZeroOriginUsesAbsoluteSourceCoordinates() throws {
        let source = try makeTestImage(width: 24, height: 18) { _, _ in (255, 255, 255, 255) }
        let context = ScreenshotSourceContext(
            sourceBounds: .init(x: 100, y: 200, width: 24, height: 18),
            tileDescriptors: [],
            compositeSource: source
        )
        let cropRect = ScreenshotPixelRect(x: 104, y: 203, width: 12, height: 10)
        let snapshot = ScreenshotSceneSnapshot(
            cropRect: cropRect,
            elements: [makeElement(.rectangle, rect: .init(x: 106, y: 205, width: 6, height: 5))]
        )

        let rendered = try renderer.render(sourceContext: context, snapshot: snapshot)

        XCTAssertEqual(rendered.width, 12)
        XCTAssertEqual(rendered.height, 10)
        XCTAssertNotEqual(try rgbaPixels(rendered), Array(repeating: 255, count: 12 * 10 * 4))
    }

    func testDashedLineRendersFewerPixelsThanSolidLine() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let geometry = ScreenshotElementGeometry.line(
            start: .init(x: 10, y: 16),
            end: .init(x: 118, y: 16)
        )
        let solid = ScreenshotElement(
            kind: .line,
            geometry: geometry,
            appearance: .init(strokeColor: black, lineWidth: 4, linePattern: .solid)
        )
        var dashed = solid
        dashed.appearance.linePattern = .dashed

        let solidPixels = try rgbaPixels(renderSingle(solid, width: 128, height: 32))
        let dashedPixels = try rgbaPixels(renderSingle(dashed, width: 128, height: 32))

        XCTAssertNotEqual(dashedPixels, solidPixels)
        XCTAssertLessThan(changedPixelCount(dashedPixels), changedPixelCount(solidPixels))
    }

    func testFilledArrowLineEndingAddsRenderedPixels() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let plain = ScreenshotElement(
            kind: .line,
            geometry: .line(start: .init(x: 12, y: 24), end: .init(x: 92, y: 24)),
            appearance: .init(strokeColor: black, lineWidth: 3)
        )
        var arrow = plain
        arrow.appearance.endEnding = .filledArrow

        let plainPixels = try rgbaPixels(renderSingle(plain, width: 108, height: 48))
        let arrowPixels = try rgbaPixels(renderSingle(arrow, width: 108, height: 48))

        XCTAssertNotEqual(arrowPixels, plainPixels)
        XCTAssertGreaterThan(changedPixelCount(arrowPixels), changedPixelCount(plainPixels))
    }

    func testArrowKindWithNoneEndingDoesNotImplicitlyAddAnArrowhead() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let geometry = ScreenshotElementGeometry.line(
            start: .init(x: 12, y: 24),
            end: .init(x: 92, y: 24)
        )
        let line = ScreenshotElement(
            kind: .line,
            geometry: geometry,
            appearance: .init(strokeColor: black, lineWidth: 3, endEnding: .none)
        )
        let arrowWithoutEnding = ScreenshotElement(
            kind: .arrow,
            geometry: geometry,
            appearance: .init(strokeColor: black, lineWidth: 3, endEnding: .none)
        )

        XCTAssertEqual(
            try rgbaPixels(renderSingle(arrowWithoutEnding, width: 108, height: 48)),
            try rgbaPixels(renderSingle(line, width: 108, height: 48))
        )
    }

    func testRoundedRectangleLeavesMoreCornerPixelsUntouchedThanSquare() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let square = ScreenshotElement(
            kind: .rectangle,
            geometry: .rect(.init(x: 8, y: 8, width: 40, height: 32)),
            appearance: .init(strokeColor: black, fillColor: black, lineWidth: 1, cornerRadius: 0)
        )
        var rounded = square
        rounded.appearance.cornerRadius = 10

        let squarePixels = try rgbaPixels(renderSingle(square, width: 56, height: 48))
        let roundedPixels = try rgbaPixels(renderSingle(rounded, width: 56, height: 48))

        XCTAssertNotEqual(roundedPixels, squarePixels)
        XCTAssertLessThan(changedPixelCount(roundedPixels), changedPixelCount(squarePixels))
    }

    func testFreehandSmoothingChangesRenderedCurvePixels() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let raw = ScreenshotElement(
            kind: .freehand,
            geometry: .path([.init(x: 8, y: 8), .init(x: 30, y: 42), .init(x: 54, y: 10)]),
            appearance: .init(strokeColor: black, lineWidth: 4, smoothing: 0)
        )
        var smoothed = raw
        smoothed.appearance.smoothing = 1

        XCTAssertNotEqual(
            try rgbaPixels(renderSingle(raw, width: 64, height: 52)),
            try rgbaPixels(renderSingle(smoothed, width: 64, height: 52))
        )
    }

    func testFreehandSmoothingAmountChangesRenderedPath() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let points = [
            ScreenshotPixelPoint(x: 8, y: 10),
            ScreenshotPixelPoint(x: 20, y: 42),
            ScreenshotPixelPoint(x: 36, y: 8),
            ScreenshotPixelPoint(x: 54, y: 38),
        ]
        let light = ScreenshotElement(
            kind: .freehand,
            geometry: .path(points),
            appearance: .init(strokeColor: black, lineWidth: 4, smoothing: 0.25)
        )
        var full = light
        full.appearance.smoothing = 1

        XCTAssertNotEqual(
            try rgbaPixels(renderSingle(light, width: 64, height: 52)),
            try rgbaPixels(renderSingle(full, width: 64, height: 52))
        )
    }

    func testFreehandHighlightRendersPathPixelsWithoutFillingItsBounds() throws {
        let yellow = ScreenshotColor(red: 1, green: 0.9, blue: 0, alpha: 0.5)
        let highlight = ScreenshotElement(
            kind: .highlight,
            geometry: .path([.init(x: 8, y: 12), .init(x: 32, y: 30), .init(x: 56, y: 12)]),
            appearance: .init(
                strokeColor: yellow,
                lineWidth: 10,
                opacity: 0.7,
                highlightMode: .freehand
            )
        )
        let pixels = try rgbaPixels(renderSingle(highlight, width: 64, height: 40))

        XCTAssertGreaterThan(changedPixelCount(pixels), 0)
        XCTAssertLessThan(changedPixelCount(pixels), 64 * 40 / 2)
    }

    func testMultilineTextRendersAdditionalLinePixels() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let oneLine = ScreenshotElement(
            kind: .text,
            geometry: .rect(.init(x: 4, y: 4, width: 100, height: 48)),
            text: "First",
            appearance: .init(strokeColor: black, fontSize: 16, textWeight: .bold)
        )
        var twoLines = oneLine
        twoLines.text = "First\nSecond"

        let oneLinePixels = try rgbaPixels(renderSingle(oneLine, width: 108, height: 56))
        let twoLinePixels = try rgbaPixels(renderSingle(twoLines, width: 108, height: 56))

        XCTAssertNotEqual(twoLinePixels, oneLinePixels)
        XCTAssertGreaterThan(changedPixelCount(twoLinePixels), changedPixelCount(oneLinePixels))
    }

    func testMixedLanguageTextWrapsInsideItsTextRect() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let textRect = ScreenshotPixelRect(x: 8, y: 8, width: 52, height: 80)
        let element = ScreenshotElement(
            kind: .text,
            geometry: .rect(textRect),
            text: "中文 English 日本語 mixed text",
            appearance: .init(strokeColor: black, fontSize: 16, textWeight: .bold)
        )

        let pixels = try rgbaPixels(renderSingle(element, width: 120, height: 96))

        XCTAssertEqual(
            changedPixelCount(pixels, in: CGRect(x: 64, y: 0, width: 56, height: 96), imageWidth: 120),
            0,
            "CoreText layout must wrap and clip text to the element rect"
        )
    }

    func testTextAlignmentMovesTheSameMixedLanguageTextWithinItsRect() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let textRect = ScreenshotPixelRect(x: 8, y: 8, width: 120, height: 40)
        let leading = ScreenshotElement(
            kind: .text,
            geometry: .rect(textRect),
            text: "中文 A 日本語",
            appearance: .init(strokeColor: black, fontSize: 16, textAlignment: .leading)
        )
        var trailing = leading
        trailing.appearance.textAlignment = .trailing

        let leadingPixels = try rgbaPixels(renderSingle(leading, width: 120, height: 64))
        let trailingPixels = try rgbaPixels(renderSingle(trailing, width: 120, height: 64))

        XCTAssertGreaterThan(
            firstChangedPixelX(in: trailingPixels, imageWidth: 120),
            firstChangedPixelX(in: leadingPixels, imageWidth: 120) + 8
        )
    }

    func testCenterAlignedTextIsPositionedBetweenLeadingAndTrailing() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let textRect = ScreenshotPixelRect(x: 8, y: 8, width: 120, height: 40)
        let leading = ScreenshotElement(
            kind: .text,
            geometry: .rect(textRect),
            text: "中文 A 日本語",
            appearance: .init(strokeColor: black, fontSize: 16, textAlignment: .leading)
        )
        var center = leading
        center.appearance.textAlignment = .center
        var trailing = leading
        trailing.appearance.textAlignment = .trailing

        let leadingX = firstChangedPixelX(in: try rgbaPixels(renderSingle(leading, width: 120, height: 64)), imageWidth: 120)
        let centerX = firstChangedPixelX(in: try rgbaPixels(renderSingle(center, width: 120, height: 64)), imageWidth: 120)
        let trailingX = firstChangedPixelX(in: try rgbaPixels(renderSingle(trailing, width: 120, height: 64)), imageWidth: 120)

        XCTAssertGreaterThan(centerX, leadingX + 3)
        XCTAssertGreaterThan(trailingX, centerX + 3)
    }

    func testAutomaticallyWrappedTextPaintsPixelsOnSecondLine() throws {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let element = ScreenshotElement(
            kind: .text,
            geometry: .rect(.init(x: 8, y: 8, width: 52, height: 72)),
            text: "English words wrap onto another line",
            appearance: .init(strokeColor: black, fontSize: 16)
        )

        let pixels = try rgbaPixels(renderSingle(element, width: 80, height: 88))

        XCTAssertGreaterThan(
            changedPixelCount(pixels, in: CGRect(x: 8, y: 28, width: 52, height: 24), imageWidth: 80),
            0,
            "A narrow text rect must lay out a second line instead of clipping after the first line"
        )
    }

    func testTextBackgroundOpacityMatchesElementOpacity() throws {
        let element = ScreenshotElement(
            kind: .text,
            geometry: .rect(.init(x: 8, y: 8, width: 48, height: 32)),
            text: " ",
            appearance: .init(
                opacity: 0.4,
                textBackgroundColor: .init(red: 1, green: 0, blue: 0, alpha: 0.5)
            )
        )

        let pixels = try rgbaPixels(renderSingle(element, width: 72, height: 48))
        let backgroundPixel = pixel(atX: 12, y: 12, width: 72, bytes: pixels)

        XCTAssertEqual(backgroundPixel[0], 255)
        XCTAssertEqual(backgroundPixel[1], 204, accuracy: 2)
        XCTAssertEqual(backgroundPixel[2], 204, accuracy: 2)
    }

    func testLargeFontRendererUsesMeasuredRectAndSharedPaddingWithoutClipping() throws {
        let style = ScreenshotElementAppearance(
            strokeColor: .init(red: 0, green: 0, blue: 0, alpha: 1),
            fontSize: 96,
            textWeight: .bold
        )
        let layout = ScreenshotTextLayout(appearance: style)
        let measured = layout.measure("████", sizing: .auto, constrainedTo: 380)
        let textRect = ScreenshotPixelRect(
            x: 12,
            y: 12,
            width: Int(measured.width),
            height: Int(measured.height)
        )
        let element = ScreenshotElement(
            kind: .text,
            geometry: .rect(textRect),
            text: "████",
            textBoxSizing: .auto,
            appearance: style
        )

        let pixels = try rgbaPixels(renderSingle(element, width: 420, height: 400))
        let outerRect = CGRect(
            x: textRect.x,
            y: textRect.y,
            width: textRect.width,
            height: textRect.height
        )
        let contentRect = layout.contentRect(in: outerRect)

        XCTAssertGreaterThan(
            changedPixelCount(pixels, in: contentRect, imageWidth: 420),
            0,
            "A measured large-font text box must render visible glyph pixels"
        )
        XCTAssertEqual(
            changedPixelCount(
                pixels,
                in: CGRect(x: outerRect.minX, y: outerRect.minY, width: layout.padding, height: outerRect.height),
                imageWidth: 420
            ),
            0,
            "Renderer text must use the same leading padding as measurement"
        )
        XCTAssertEqual(
            changedPixelCount(
                pixels,
                in: CGRect(x: outerRect.minX, y: outerRect.minY, width: outerRect.width, height: layout.padding),
                imageWidth: 420
            ),
            0,
            "Renderer text must use the same top padding as measurement"
        )
    }

    private func renderSingle(_ element: ScreenshotElement, width: Int, height: Int) throws -> CGImage {
        let source = try makeTestImage(width: width, height: height) { _, _ in (255, 255, 255, 255) }

        return try renderer.render(
            source: source,
            snapshot: .init(
                cropRect: .init(x: 0, y: 0, width: width, height: height),
                elements: [element]
            )
        )
    }

    private func makeMagnifier(
        center: ScreenshotPixelPoint,
        diameter: Double,
        zoom: Double
    ) -> ScreenshotElement {
        ScreenshotElement(
            kind: .magnifier,
            geometry: .magnifier(center: center),
            appearance: .magnifier(.init(
                zoom: zoom,
                diameter: diameter,
                borderColor: .init(red: 0, green: 0, blue: 0, alpha: 0),
                borderWidth: 0,
                shadow: 0
            ))
        )
    }

    private func assertPixel(
        _ actual: [UInt8],
        near expected: [UInt8],
        accuracy: Int = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualChannel, expectedChannel) in zip(actual, expected) {
            XCTAssertLessThanOrEqual(
                abs(Int(actualChannel) - Int(expectedChannel)),
                accuracy,
                "Expected \(expected), got \(actual)",
                file: file,
                line: line
            )
        }
    }

    func testBlurAndPixelateOnlyChangeTheirExactEffectRects() throws {
        let source = try makeTestImage(width: 64, height: 48)
        let blurRect = ScreenshotPixelRect(x: 4, y: 5, width: 20, height: 16)
        let pixelRect = ScreenshotPixelRect(x: 36, y: 24, width: 18, height: 14)
        let elements = [
            ScreenshotElement(kind: .blur, geometry: .rect(blurRect), appearance: .init(effectIntensity: 5)),
            ScreenshotElement(kind: .pixelate, geometry: .rect(pixelRect), appearance: .init(effectIntensity: 7)),
        ]

        let rendered = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 64, height: 48), elements: elements)
        )
        let before = try rgbaPixels(source)
        let after = try rgbaPixels(rendered)

        XCTAssertNotEqual(pixel(atX: 10, y: 10, width: 64, bytes: before), pixel(atX: 10, y: 10, width: 64, bytes: after))
        XCTAssertNotEqual(pixel(atX: 42, y: 30, width: 64, bytes: before), pixel(atX: 42, y: 30, width: 64, bytes: after))
        XCTAssertEqual(pixel(atX: 60, y: 3, width: 64, bytes: before), pixel(atX: 60, y: 3, width: 64, bytes: after))
    }

    func testEllipticalEffectOnlyChangesPixelsInsideEllipse() throws {
        let source = try makeTestImage(width: 64, height: 48)
        let effect = ScreenshotElement(
            kind: .pixelate,
            geometry: .rect(.init(x: 12, y: 8, width: 36, height: 32)),
            appearance: .effect(.init(shape: .ellipse, intensity: 8))
        )

        let rendered = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 64, height: 48), elements: [effect])
        )
        let before = try rgbaPixels(source)
        let after = try rgbaPixels(rendered)

        XCTAssertEqual(
            pixel(atX: 13, y: 9, width: 64, bytes: before),
            pixel(atX: 13, y: 9, width: 64, bytes: after)
        )
        XCTAssertNotEqual(
            pixel(atX: 30, y: 24, width: 64, bytes: before),
            pixel(atX: 30, y: 24, width: 64, bytes: after)
        )
    }

    func testSpotlightFeatherProducesGradualInteriorTransition() throws {
        let source = try makeTestImage(width: 64, height: 48) { _, _ in (255, 255, 255, 255) }
        let spotlight = ScreenshotElement(
            kind: .spotlight,
            geometry: .rect(.init(x: 16, y: 8, width: 32, height: 32)),
            appearance: .spotlight(.init(shape: .rectangle, dimIntensity: 0.8, feather: 8))
        )

        let rendered = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 64, height: 48), elements: [spotlight])
        )
        let bytes = try rgbaPixels(rendered)
        let outside = pixel(atX: 5, y: 24, width: 64, bytes: bytes)[0]
        let feathered = pixel(atX: 18, y: 24, width: 64, bytes: bytes)[0]
        let center = pixel(atX: 32, y: 24, width: 64, bytes: bytes)[0]

        XCTAssertLessThan(outside, feathered)
        XCTAssertLessThan(feathered, center)
    }

    func testMultipleSpotlightsDimTheBackgroundOnceAndExposeTheirUnion() throws {
        let source = try makeTestImage(width: 96, height: 56) { _, _ in (255, 255, 255, 255) }
        func spotlight(_ rect: ScreenshotPixelRect) -> ScreenshotElement {
            ScreenshotElement(
                kind: .spotlight,
                geometry: .rect(rect),
                appearance: .spotlight(.init(shape: .ellipse, dimIntensity: 0.65, feather: 0))
            )
        }
        let first = spotlight(.init(x: 16, y: 12, width: 24, height: 24))
        let second = spotlight(.init(x: 54, y: 12, width: 24, height: 24))
        let third = spotlight(.init(x: 34, y: 20, width: 28, height: 24))

        let one = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 96, height: 56), elements: [first])
        ))
        let two = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 96, height: 56), elements: [first, second])
        ))
        let three = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 96, height: 56), elements: [first, second, third])
        ))

        let outsideOne = pixel(atX: 6, y: 6, width: 96, bytes: one)
        XCTAssertEqual(pixel(atX: 6, y: 6, width: 96, bytes: two), outsideOne)
        XCTAssertEqual(pixel(atX: 6, y: 6, width: 96, bytes: three), outsideOne)
        XCTAssertEqual(pixel(atX: 28, y: 24, width: 96, bytes: three)[0], 255)
        XCTAssertEqual(pixel(atX: 66, y: 24, width: 96, bytes: three)[0], 255)
        XCTAssertEqual(pixel(atX: 48, y: 28, width: 96, bytes: three)[0], 255)
    }

    func testOverlappingSpotlightFeathersUseBrightestMaskWithoutAccumulation() throws {
        let source = try makeTestImage(width: 64, height: 48) { _, _ in (255, 255, 255, 255) }
        let spotlight = ScreenshotElement(
            kind: .spotlight,
            geometry: .rect(.init(x: 16, y: 8, width: 32, height: 32)),
            appearance: .spotlight(.init(shape: .rectangle, dimIntensity: 0.8, feather: 8))
        )

        let one = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 64, height: 48), elements: [spotlight])
        ))
        let duplicate = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 64, height: 48), elements: [spotlight, spotlight])
        ))

        XCTAssertEqual(pixel(atX: 18, y: 24, width: 64, bytes: duplicate),
                       pixel(atX: 18, y: 24, width: 64, bytes: one))
        XCTAssertEqual(pixel(atX: 32, y: 24, width: 64, bytes: duplicate),
                       pixel(atX: 32, y: 24, width: 64, bytes: one))
        XCTAssertEqual(pixel(atX: 5, y: 24, width: 64, bytes: duplicate),
                       pixel(atX: 5, y: 24, width: 64, bytes: one))
    }

    func testEmptyCalloutDoesNotEnterFinalPixelsButPopulatedCompositeRenders() throws {
        let source = try makeTestImage(width: 160, height: 80) { _, _ in (255, 255, 255, 255) }
        let empty = ScreenshotElement(
            kind: .callout,
            geometry: .calloutComposite(
                target: .ellipse(.init(x: 12, y: 20, width: 34, height: 28)),
                note: .init(x: 92, y: 20, width: 56, height: 30)
            ),
            text: "",
            textBoxSizing: .fixedWidth,
            appearance: .callout(.init())
        )
        var populated = empty
        populated.text = "Target"

        let emptyPixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 160, height: 80), elements: [empty])
        ))
        let populatedPixels = try rgbaPixels(renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 160, height: 80), elements: [populated])
        ))

        XCTAssertEqual(emptyPixels, try rgbaPixels(source))
        XCTAssertNotEqual(populatedPixels, emptyPixels)
    }

    func testCroppedRenderIsPixelEquivalentToCroppingFullSceneResult() throws {
        let source = try makeTestImage(width: 128, height: 96)
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let elements = [
            ScreenshotElement(
                kind: .rectangle,
                geometry: .rect(.init(x: 30, y: 24, width: 62, height: 42)),
                appearance: .init(strokeColor: black, fillColor: black, lineWidth: 2)
            ),
            ScreenshotElement(
                kind: .blur,
                geometry: .rect(.init(x: 42, y: 30, width: 48, height: 36)),
                appearance: .init(effectIntensity: 4)
            ),
            ScreenshotElement(
                kind: .pixelate,
                geometry: .rect(.init(x: 50, y: 38, width: 28, height: 20)),
                appearance: .init(effectIntensity: 6)
            ),
            ScreenshotElement(
                kind: .line,
                geometry: .line(start: .init(x: 32, y: 62), end: .init(x: 98, y: 34)),
                appearance: .init(strokeColor: black, lineWidth: 3)
            ),
        ]
        let cropRect = ScreenshotPixelRect(x: 48, y: 36, width: 32, height: 24)
        let full = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 128, height: 96), elements: elements)
        )
        let cropped = try renderer.render(
            source: source,
            snapshot: .init(cropRect: cropRect, elements: elements)
        )

        XCTAssertEqual(try rgbaPixels(cropped), try rgbaPixels(try crop(full, to: cropRect)))
    }

    func testRasterEffectsResolveBeforeVectorAnnotationsRegardlessOfInsertionOrder() throws {
        let source = try makeTestImage(width: 72, height: 56) { _, _ in (255, 255, 255, 255) }
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let rectangle = ScreenshotElement(
            kind: .rectangle,
            geometry: .rect(.init(x: 20, y: 16, width: 30, height: 24)),
            appearance: .init(strokeColor: black, fillColor: black, lineWidth: 1)
        )
        let blur = ScreenshotElement(
            kind: .blur,
            geometry: .rect(.init(x: 12, y: 8, width: 48, height: 40)),
            appearance: .init(effectIntensity: 5)
        )

        let vectorThenEffect = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 72, height: 56), elements: [rectangle, blur])
        )
        let effectThenVector = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 72, height: 56), elements: [blur, rectangle])
        )

        XCTAssertEqual(try rgbaPixels(vectorThenEffect), try rgbaPixels(effectThenVector))
    }

    func testRenderPlanUsesCropEffectSamplingExtentAndVectorBatches() throws {
        let cropRect = ScreenshotPixelRect(x: 1_000, y: 800, width: 120, height: 80)
        let firstVector = ScreenshotElement(
            kind: .rectangle,
            geometry: .rect(.init(x: 1_010, y: 810, width: 30, height: 20)),
            appearance: .init()
        )
        let secondVector = ScreenshotElement(
            kind: .ellipse,
            geometry: .rect(.init(x: 1_050, y: 820, width: 30, height: 20)),
            appearance: .init()
        )
        let thirdVector = ScreenshotElement(
            kind: .line,
            geometry: .line(start: .init(x: 1_010, y: 850), end: .init(x: 1_100, y: 850)),
            appearance: .init()
        )
        let fourthVector = ScreenshotElement(
            kind: .rectangle,
            geometry: .rect(.init(x: 1_070, y: 840, width: 30, height: 20)),
            appearance: .init()
        )
        let elements = [
            firstVector,
            secondVector,
            ScreenshotElement(
                kind: .blur,
                geometry: .rect(cropRect),
                appearance: .init(effectIntensity: 4)
            ),
            thirdVector,
            ScreenshotElement(
                kind: .pixelate,
                geometry: .rect(.init(x: 1_020, y: 820, width: 40, height: 30)),
                appearance: .init(effectIntensity: 8)
            ),
            fourthVector,
        ]

        let plan = try renderer.makeRenderPlan(
            sourceWidth: 6_000,
            sourceHeight: 2_000,
            snapshot: .init(cropRect: cropRect, elements: elements)
        )

        XCTAssertEqual(plan.outputRect, CGRect(x: 1_000, y: 800, width: 120, height: 80))
        XCTAssertEqual(plan.workingRect, CGRect(x: 984, y: 784, width: 152, height: 112))
        XCTAssertEqual(plan.effectBoundaryCount, 2)
        XCTAssertEqual(plan.vectorBatchCount, 3)
        XCTAssertLessThan(plan.workingRect.width, 6_000)
        XCTAssertLessThan(plan.workingRect.height, 2_000)
    }

    func testRenderPlanAndExecutionExcludeLargeOffscreenScene() throws {
        let source = try makeTestImage(width: 96, height: 72)
        let cropRect = ScreenshotPixelRect(x: 20, y: 16, width: 48, height: 36)
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let requiredElements = [
            ScreenshotElement(
                kind: .rectangle,
                geometry: .rect(.init(x: 24, y: 20, width: 28, height: 20)),
                appearance: .init(strokeColor: black, fillColor: black, lineWidth: 2)
            ),
            ScreenshotElement(
                kind: .blur,
                geometry: .rect(.init(x: 22, y: 18, width: 40, height: 30)),
                appearance: .init(effectIntensity: 3)
            ),
            ScreenshotElement(
                kind: .line,
                geometry: .line(start: .init(x: 22, y: 46), end: .init(x: 66, y: 22)),
                appearance: .init(strokeColor: black, lineWidth: 3)
            ),
        ]
        var fullScene: [ScreenshotElement] = []
        for index in 0..<200 {
            let offset = 10_000 + index * 20
            fullScene.append(ScreenshotElement(
                kind: .rectangle,
                geometry: .rect(.init(x: offset, y: offset, width: 12, height: 10)),
                appearance: .init(strokeColor: black, lineWidth: 4)
            ))
            fullScene.append(ScreenshotElement(
                kind: index.isMultiple(of: 2) ? .blur : .pixelate,
                geometry: .rect(.init(x: offset, y: offset, width: 12, height: 10)),
                appearance: .init(effectIntensity: 12)
            ))
        }
        fullScene.append(contentsOf: requiredElements)
        let snapshot = ScreenshotSceneSnapshot(cropRect: cropRect, elements: fullScene)

        let plan = try renderer.makeRenderPlan(sourceWidth: 96, sourceHeight: 72, snapshot: snapshot)
        let fullRender = try renderer.render(source: source, snapshot: snapshot)
        let requiredRender = try renderer.render(
            source: source,
            snapshot: .init(cropRect: cropRect, elements: requiredElements)
        )

        XCTAssertEqual(plan.effectBoundaryCount, 1)
        XCTAssertEqual(plan.vectorBatchCount, 2)
        XCTAssertEqual(plan.elementIndexes, [400, 401, 402])
        XCTAssertEqual(try rgbaPixels(fullRender), try rgbaPixels(requiredRender))
    }

    func testCancelledRenderRequestFailsBeforeProducingImage() throws {
        let source = try makeTestImage(width: 24, height: 18)
        let request = ScreenshotSceneRenderRequest(
            revision: .init(rawValue: 7),
            snapshot: .init(cropRect: .init(x: 0, y: 0, width: 24, height: 18))
        )
        request.cancellation.cancel()

        XCTAssertThrowsError(try renderer.render(source: source, request: request)) { error in
            XCTAssertEqual(error as? ScreenshotRenderError, .cancelled)
        }
    }

    func testPNGAndJPEGEncodingsAreDecodableAndJPEGUsesOpaqueCanvas() throws {
        let image = try makeTestImage(width: 12, height: 9) { x, y in
            x < 6 && y < 5 ? (255, 0, 0, 128) : (0, 0, 0, 0)
        }

        let decodedPNG = try decodeImage(encoder.pngData(image))
        let decodedJPEG = try decodeImage(encoder.jpegData(image, quality: 0.72))

        XCTAssertEqual(decodedPNG.width, 12)
        XCTAssertEqual(decodedPNG.height, 9)
        XCTAssertEqual(decodedJPEG.width, 12)
        XCTAssertEqual(decodedJPEG.height, 9)
        XCTAssertFalse(decodedJPEG.alphaInfo.hasAlpha)
        let jpegPixels = try rgbaPixels(decodedJPEG)
        let transparentRegionPixel = (8 * decodedJPEG.width + 10) * 4
        XCTAssertGreaterThan(jpegPixels[transparentRegionPixel], 240)
        XCTAssertGreaterThan(jpegPixels[transparentRegionPixel + 1], 240)
        XCTAssertGreaterThan(jpegPixels[transparentRegionPixel + 2], 240)
    }

    func testPixelCompositorPreservesSourceOrientationAndTopLeftPlacement() throws {
        let source = try makeTestImage(width: 2, height: 2) { x, y in
            switch (x, y) {
            case (0, 0): (255, 0, 0, 255)
            case (1, 0): (0, 255, 0, 255)
            case (0, 1): (0, 0, 255, 255)
            default: (255, 255, 0, 255)
            }
        }
        let output = try ScreenshotImageCompositor.compose(
            size: .init(width: 4, height: 4),
            tiles: [
                .init(
                    image: source,
                    destination: .init(x: 1, y: 1, width: 2, height: 2)
                )
            ]
        )
        let sourcePixels = try rgbaPixels(source)
        let outputPixels = try rgbaPixels(output)

        XCTAssertEqual(pixel(atX: 1, y: 1, width: 4, bytes: outputPixels), pixel(atX: 0, y: 0, width: 2, bytes: sourcePixels))
        XCTAssertEqual(pixel(atX: 2, y: 1, width: 4, bytes: outputPixels), pixel(atX: 1, y: 0, width: 2, bytes: sourcePixels))
        XCTAssertEqual(pixel(atX: 1, y: 2, width: 4, bytes: outputPixels), pixel(atX: 0, y: 1, width: 2, bytes: sourcePixels))
        XCTAssertEqual(pixel(atX: 2, y: 2, width: 4, bytes: outputPixels), pixel(atX: 1, y: 1, width: 2, bytes: sourcePixels))
    }

    func testRoundedOutputCropsInSourceSpaceAndAppliesOneFinalMask() throws {
        let source = try makeTestImage(width: 100, height: 80) { _, _ in (40, 80, 120, 255) }
        let output = try ScreenshotOutputProcessor.process(
            image: source,
            imageRect: .init(x: 20, y: 30, width: 100, height: 80),
            outputRect: .init(x: 30, y: 40, width: 60, height: 40),
            appearance: .init(isRounded: true)
        )
        let pixels = try rgbaPixels(output)

        XCTAssertEqual(output.width, 60)
        XCTAssertEqual(output.height, 40)
        XCTAssertEqual(pixel(atX: 0, y: 0, width: 60, bytes: pixels)[3], 0)
        XCTAssertEqual(pixel(atX: 30, y: 20, width: 60, bytes: pixels)[3], 255)
        XCTAssertEqual(
            ScreenshotOutputAppearance(isRounded: true).cornerRadius(for: .init(width: 60, height: 40)),
            8
        )
    }

    func testRendererUsesSnapshotOutputAppearanceAfterFinalCrop() throws {
        let source = try makeTestImage(width: 80, height: 60) { _, _ in (255, 0, 0, 255) }
        let output = try renderer.render(
            source: source,
            snapshot: .init(
                cropRect: .init(x: 10, y: 8, width: 50, height: 36),
                outputAppearance: .init(isRounded: true)
            )
        )
        let pixels = try rgbaPixels(output)
        XCTAssertEqual(output.width, 50)
        XCTAssertEqual(output.height, 36)
        XCTAssertEqual(pixel(atX: 0, y: 0, width: 50, bytes: pixels)[3], 0)
        XCTAssertEqual(pixel(atX: 25, y: 18, width: 50, bytes: pixels), [255, 0, 0, 255])
    }

    func testTiledTextWatermarkRendersAcrossFinalCrop() throws {
        let source = try makeTestImage(width: 100, height: 70) { _, _ in (255, 255, 255, 255) }
        let watermark = ScreenshotElement(
            kind: .watermark,
            geometry: .rect(.init(x: 0, y: 0, width: 100, height: 70)),
            watermark: .init(
                name: "Text",
                style: .init(
                    text: "Blocks",
                    color: .accentRed,
                    fontSizeFraction: 0.08,
                    density: 0.8,
                    angleDegrees: -30,
                    opacity: 0.8
                )
            )
        )
        let output = try renderer.render(
            source: source,
            snapshot: .init(cropRect: .init(x: 10, y: 8, width: 80, height: 54), elements: [watermark])
        )
        XCTAssertEqual(output.width, 80)
        XCTAssertEqual(output.height, 54)
        XCTAssertGreaterThan(changedPixelCount(try rgbaPixels(output), in: .init(x: 0, y: 0, width: 80, height: 54), imageWidth: 80), 0)
    }

    func testEditorPreviewClipsWatermarkToDocumentCrop() throws {
        let source = try makeTestImage(width: 120, height: 80) { _, _ in (255, 255, 255, 255) }
        let watermark = ScreenshotElement(
            kind: .watermark,
            geometry: .rect(.init(x: 0, y: 0, width: 120, height: 80)),
            watermark: .init(
                name: "Preview watermark",
                style: .init(
                    text: "WM",
                    color: .accentRed,
                    fontSizeFraction: 0.16,
                    density: 1,
                    angleDegrees: 0,
                    opacity: 1
                )
            )
        )
        let output = try renderer.render(
            source: source,
            request: .init(
                revision: .init(rawValue: 1),
                snapshot: .init(
                    cropRect: .init(x: 0, y: 0, width: 120, height: 80),
                    watermarkClipRect: .init(x: 30, y: 20, width: 60, height: 40),
                    elements: [watermark]
                )
            )
        )
        let pixels = try rgbaPixels(output)

        XCTAssertEqual(
            changedPixelCount(
                pixels,
                in: .init(x: 0, y: 0, width: 120, height: 20),
                imageWidth: 120
            ),
            0
        )
        XCTAssertEqual(
            changedPixelCount(
                pixels,
                in: .init(x: 0, y: 60, width: 120, height: 20),
                imageWidth: 120
            ),
            0
        )
        XCTAssertGreaterThan(
            changedPixelCount(
                pixels,
                in: .init(x: 30, y: 20, width: 60, height: 40),
                imageWidth: 120
            ),
            0
        )
    }

    func testTiledWatermarkDensityAngleOpacityAndRelativeSizeAffectPixels() throws {
        let source = try makeTestImage(width: 240, height: 140) { _, _ in (255, 255, 255, 255) }
        func render(style: ScreenshotWatermarkStyle) throws -> [UInt8] {
            let watermark = ScreenshotElement(
                kind: .watermark,
                geometry: .rect(.init(x: 0, y: 0, width: 240, height: 140)),
                watermark: .init(
                    name: "Scalable watermark",
                    style: style
                )
            )
            let output = try renderer.render(
                source: source,
                snapshot: .init(cropRect: .init(x: 0, y: 0, width: 240, height: 140), elements: [watermark])
            )
            return try rgbaPixels(output)
        }

        let sparse = try render(style: .init(text: "WM", color: .accentRed, fontSizeFraction: 0.04, density: 0, angleDegrees: 0, opacity: 0.25))
        let dense = try render(style: .init(text: "WM", color: .accentRed, fontSizeFraction: 0.04, density: 1, angleDegrees: 0, opacity: 0.25))
        let rotated = try render(style: .init(text: "WM", color: .accentRed, fontSizeFraction: 0.08, density: 1, angleDegrees: 45, opacity: 0.8))

        XCTAssertNotEqual(sparse, dense)
        XCTAssertNotEqual(dense, rotated)
    }

    func testCounterAndStepBadgeTextUseOpticallyCenteredSharedLayout() throws {
        for number in [1, 8, 10, 99, 100] {
            for size in [28.0, 64.0] {
                let source = try makeTestImage(width: 140, height: 100) { _, _ in (255, 255, 255, 255) }
                let clear = ScreenshotColor(red: 1, green: 1, blue: 1, alpha: 0)
                let appearance = ScreenshotCounterAppearance(
                    size: size,
                    fillColor: clear,
                    textColor: .init(red: 0, green: 0, blue: 0, alpha: 1),
                    borderColor: clear,
                    borderWidth: 0
                )
                let counter = ScreenshotElement(
                    kind: .counter,
                    geometry: .counter(center: .init(x: 70, y: 50)),
                    text: String(number),
                    appearance: .counter(appearance)
                )
                let rendered = try renderer.render(
                    source: source,
                    snapshot: .init(cropRect: .init(x: 0, y: 0, width: 140, height: 100), elements: [counter])
                )
                let bounds = try XCTUnwrap(changedPixelBounds(try rgbaPixels(rendered), imageWidth: 140))
                XCTAssertEqual(bounds.midX, 70, accuracy: 1.5, "counter \(number), size \(size)")
                XCTAssertEqual(bounds.midY, 50, accuracy: 1.5, "counter \(number), size \(size)")

                let step = ScreenshotElement(
                    kind: .step,
                    geometry: .step(badgeCenter: .init(x: 70, y: 50), note: nil),
                    text: "",
                    stepNumber: number,
                    appearance: .step(.init(badge: appearance, connector: .init(), note: .init()))
                )
                let stepRendered = try renderer.render(
                    source: source,
                    snapshot: .init(cropRect: .init(x: 0, y: 0, width: 140, height: 100), elements: [step])
                )
                let stepBounds = try XCTUnwrap(changedPixelBounds(try rgbaPixels(stepRendered), imageWidth: 140))
                XCTAssertEqual(stepBounds.midX, 70, accuracy: 1.5, "step \(number), size \(size)")
                XCTAssertEqual(stepBounds.midY, 50, accuracy: 1.5, "step \(number), size \(size)")
            }
        }
    }

    private func makeElement(
        _ kind: ScreenshotElementKind,
        rect: ScreenshotPixelRect = .init(x: 12, y: 10, width: 48, height: 32)
    ) -> ScreenshotElement {
        let black = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
        let geometry: ScreenshotElementGeometry
        let appearance: ScreenshotElementAppearance
        switch kind {
        case .arrow, .line:
            geometry = .line(start: .init(x: 12, y: 10), end: .init(x: 60, y: 42))
            appearance = .line(.init(
                color: black,
                width: 4,
                opacity: 0.8,
                endEnding: kind == .arrow ? .filledArrow : .none
            ))
        case .freehand:
            geometry = .path([.init(x: 12, y: 10), .init(x: 30, y: 42), .init(x: 60, y: 20)])
            appearance = .freehand(.init(color: black, width: 4, opacity: 0.8))
        case .highlight:
            geometry = .rect(rect)
            appearance = .highlight(.init(color: black, width: 4, opacity: 0.8))
        case .counter:
            geometry = .counter(center: .init(x: 36, y: 28))
            appearance = .counter(.init(fillColor: black))
        case .step:
            geometry = .step(
                badgeCenter: .init(x: 24, y: 28),
                note: .init(x: 42, y: 14, width: 44, height: 28)
            )
            appearance = .step(.init(badgeFillColor: black))
        case .callout:
            geometry = .callout(body: rect, pointer: .init(x: 68, y: 52))
            appearance = .callout(.init(backgroundColor: black))
        case .magnifier:
            geometry = .magnifier(center: .init(
                x: Double(rect.x) + Double(rect.width) / 2,
                y: Double(rect.y) + Double(rect.height) / 2
            ))
            appearance = .magnifier(.init())
        case .watermark:
            geometry = .rect(rect)
            appearance = .shape()
        case .spotlight:
            geometry = .rect(rect)
            appearance = .spotlight(.init())
        case .redact:
            geometry = .rect(rect)
            appearance = .redact(.init(color: black))
        case .rectangle, .ellipse:
            geometry = .rect(rect)
            appearance = .shape(.init(
                strokeColor: black,
                fillColor: .init(red: 1, green: 0, blue: 0, alpha: 0.3),
                strokeWidth: 4,
                opacity: 0.8,
                cornerRadius: 5
            ))
        case .text:
            geometry = .rect(rect)
            appearance = .text(.init(color: black, fontSize: 18, weight: .semibold, opacity: 0.8))
        case .blur, .pixelate:
            geometry = .rect(rect)
            appearance = .effect(.init(intensity: 6))
        }
        return ScreenshotElement(
            kind: kind,
            geometry: geometry,
            text: kind == .text ? "Blocks\n截图" : (kind == .callout ? "Callout" : (kind == .counter ? "1" : (kind == .step ? "Next" : nil))),
            stepNumber: kind == .step ? 1 : nil,
            watermark: kind == .watermark
                ? .init(name: "Watermark", style: .init(text: "WM", color: black, fontSizeFraction: 0.08))
                : nil,
            appearance: appearance
        )
    }

    private func crop(_ image: CGImage, to rect: ScreenshotPixelRect) throws -> CGImage {
        guard let cropped = image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else {
            throw DecodeError.invalidImage
        }
        return cropped
    }

    private func decodeImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DecodeError.invalidImage
        }
        return image
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &bytes,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw DecodeError.invalidImage
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func pixel(atX x: Int, y: Int, width: Int, bytes: [UInt8]) -> [UInt8] {
        let index = (y * width + x) * 4
        return Array(bytes[index..<(index + 4)])
    }

    private func changedPixelCount(_ bytes: [UInt8]) -> Int {
        stride(from: 0, to: bytes.count, by: 4).reduce(into: 0) { count, index in
            if bytes[index] < 250 || bytes[index + 1] < 250 || bytes[index + 2] < 250 {
                count += 1
            }
        }
    }

    private func changedPixelCount(_ bytes: [UInt8], in rect: CGRect, imageWidth: Int) -> Int {
        let region = rect.integral
        return (Int(region.minY)..<Int(region.maxY)).reduce(into: 0) { count, y in
            for x in Int(region.minX)..<Int(region.maxX) {
                let pixel = pixel(atX: x, y: y, width: imageWidth, bytes: bytes)
                if pixel[0] < 250 || pixel[1] < 250 || pixel[2] < 250 {
                    count += 1
                }
            }
        }
    }

    private func changedPixelBounds(_ bytes: [UInt8], imageWidth: Int) -> CGRect? {
        let height = bytes.count / 4 / imageWidth
        var minX = imageWidth
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<imageWidth {
                let value = pixel(atX: x, y: y, width: imageWidth, bytes: bytes)
                guard value[0] < 128 || value[1] < 128 || value[2] < 128 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func firstChangedPixelX(in bytes: [UInt8], imageWidth: Int) -> Int {
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[index] < 250 || bytes[index + 1] < 250 || bytes[index + 2] < 250 {
                return index / 4 % imageWidth
            }
        }
        return imageWidth
    }
}
private extension CGImageAlphaInfo {
    var hasAlpha: Bool {
        switch self {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return true
        }
    }
}

private enum DecodeError: Error {
    case invalidImage
}
