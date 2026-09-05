import CoreGraphics
import XCTest
@testable import BlocksScreenshotCore

final class ScreenshotSelectionReducerTests: XCTestCase {
    private let reducer = ScreenshotSelectionReducer()

    func testDisplayIntentDefaultsToCurrentDisplay() throws {
        let intent = try ScreenshotCaptureIntent(kind: .display)

        XCTAssertEqual(intent.displayScope, .current)
    }

    func testNonDisplayIntentRejectsDisplayScope() {
        XCTAssertThrowsError(
            try ScreenshotCaptureIntent(kind: .window, displayScope: .all)
        )
    }

    func testIntentDecodingPreservesDisplayScopeInvariant() throws {
        let invalid = Data(
            #"{"kind":"window","displayScope":{"kind":"all"}}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(ScreenshotCaptureIntent.self, from: invalid)
        )

        let display = try JSONDecoder().decode(
            ScreenshotCaptureIntent.self,
            from: Data(#"{"kind":"display","displayScope":{"kind":"displayID","id":77}}"#.utf8)
        )
        XCTAssertEqual(display.displayScope, .displayID(77))
    }

    func testWindowHoverPreviewsCandidateAndPointerUpCapturesIt() {
        let candidate = ScreenshotWindowCandidate(
            id: 42,
            frame: ScreenshotSelectionRect(x: 20, y: 30, width: 640, height: 480)
        )
        let preview = reducer.reduce(
            state: .ready,
            event: .pointerMoved(point: .init(x: 100, y: 100), windowCandidate: candidate)
        )

        XCTAssertEqual(preview.state, .windowPreview(candidate))
        XCTAssertEqual(preview.effects, [])

        let pressed = reducer.reduce(
            state: preview.state,
            event: .pointerDown(point: .init(x: 100, y: 100), windowCandidate: candidate)
        )
        XCTAssertEqual(pressed.state, .pendingClick(start: .init(x: 100, y: 100), windowCandidate: candidate))

        let capture = reducer.reduce(
            state: pressed.state,
            event: .pointerUp(
                point: .init(x: 100, y: 100),
                windowCandidate: candidate,
                resolvedRegion: nil
            )
        )

        XCTAssertEqual(capture.state, .capturing)
        XCTAssertEqual(capture.effects, [.captureWindow(candidate)])
    }

    func testWindowCandidateUsesOneExactFrameForHitTestingAndOutput() {
        let frame = ScreenshotSelectionRect(x: 20, y: 30, width: 640, height: 480)
        let candidate = ScreenshotWindowCandidate(
            id: 42,
            frame: frame
        )

        let preview = reducer.reduce(
            state: .ready,
            event: .pointerMoved(point: .init(x: 100, y: 100), windowCandidate: candidate)
        )
        let pressed = reducer.reduce(
            state: preview.state,
            event: .pointerDown(point: .init(x: 100, y: 100), windowCandidate: candidate)
        )
        let capture = reducer.reduce(
            state: pressed.state,
            event: .pointerUp(
                point: .init(x: 100, y: 100),
                windowCandidate: candidate,
                resolvedRegion: nil
            )
        )

        XCTAssertEqual(candidate.frame, frame)
        XCTAssertEqual(capture.effects, [.captureWindow(candidate)])
    }

    func testFirstDragTakesOverWindowPreviewAndCapturesRegionOnPointerUp() {
        let candidate = ScreenshotWindowCandidate(
            id: 7,
            frame: ScreenshotSelectionRect(x: 0, y: 0, width: 400, height: 300)
        )
        let start = ScreenshotSelectionPoint(x: 50, y: 60)
        let current = ScreenshotSelectionPoint(x: 250, y: 210)
        let preview = ScreenshotSelectionState.windowPreview(candidate)

        let pressed = reducer.reduce(
            state: preview,
            event: .pointerDown(point: start, windowCandidate: candidate)
        )
        let drawing = reducer.reduce(
            state: pressed.state,
            event: .pointerDragged(current: current, exceededThreshold: true)
        )

        XCTAssertEqual(drawing.state, .regionDrawing(start: start, current: current))
        XCTAssertEqual(drawing.effects, [])

        let region = ScreenshotSelectionRect(x: 50, y: 60, width: 200, height: 150)
        let capture = reducer.reduce(
            state: drawing.state,
            event: .pointerUp(point: current, windowCandidate: nil, resolvedRegion: region)
        )

        XCTAssertEqual(capture.state, .capturing)
        XCTAssertEqual(capture.effects, [.captureRegion(region)])
    }

    func testDragBelowThresholdRemainsPendingAndEmptyClickDoesNotCapture() {
        let start = ScreenshotSelectionPoint(x: 10, y: 20)
        let pressed = reducer.reduce(
            state: .ready,
            event: .pointerDown(point: start, windowCandidate: nil)
        )
        let unchanged = reducer.reduce(
            state: pressed.state,
            event: .pointerDragged(current: .init(x: 12, y: 21), exceededThreshold: false)
        )
        XCTAssertEqual(unchanged.state, .pendingClick(start: start, windowCandidate: nil))

        let released = reducer.reduce(
            state: unchanged.state,
            event: .pointerUp(point: .init(x: 12, y: 21), windowCandidate: nil, resolvedRegion: nil)
        )
        XCTAssertEqual(released.state, .ready)
        XCTAssertEqual(released.effects, [])
    }

    func testWindowHoverCannotTakeOverPendingOrActiveRegionGesture() {
        let candidate = ScreenshotWindowCandidate(
            id: 9,
            frame: .init(x: 0, y: 0, width: 400, height: 300)
        )
        let start = ScreenshotSelectionPoint(x: 20, y: 30)
        let pending = ScreenshotSelectionState.pendingClick(start: start, windowCandidate: candidate)
        let pendingMove = reducer.reduce(
            state: pending,
            event: .pointerMoved(point: .init(x: 25, y: 35), windowCandidate: nil)
        )
        XCTAssertEqual(pendingMove.state, pending)

        let drawing = ScreenshotSelectionState.regionDrawing(
            start: start,
            current: .init(x: 200, y: 180)
        )
        let drawingMove = reducer.reduce(
            state: drawing,
            event: .pointerMoved(point: .init(x: 210, y: 190), windowCandidate: candidate)
        )
        XCTAssertEqual(drawingMove.state, drawing)
    }

    func testActiveRegionGestureTracksEverySubsequentDragPoint() {
        let start = ScreenshotSelectionPoint(x: 20, y: 30)
        let drawing = ScreenshotSelectionState.regionDrawing(
            start: start,
            current: .init(x: 120, y: 130)
        )

        let updated = reducer.reduce(
            state: drawing,
            event: .pointerDragged(
                current: .init(x: 280, y: 240),
                exceededThreshold: true
            )
        )

        XCTAssertEqual(
            updated.state,
            .regionDrawing(start: start, current: .init(x: 280, y: 240))
        )
        XCTAssertEqual(updated.effects, [])
    }

    func testHintStateUsesRegionDrawingAfterDragInsteadOfWindowPreview() {
        let candidate = ScreenshotWindowCandidate(
            id: 9,
            frame: .init(x: 0, y: 0, width: 400, height: 300)
        )
        let start = ScreenshotSelectionPoint(x: 20, y: 30)
        let drawing = ScreenshotSelectionState.regionDrawing(
            start: start,
            current: .init(x: 200, y: 180)
        )

        XCTAssertEqual(
            reducer.hintState(for: .windowPreview(candidate), hasWindowCandidates: true),
            .window
        )
        XCTAssertEqual(
            reducer.hintState(for: drawing, hasWindowCandidates: true),
            .regionDrawing
        )
        XCTAssertEqual(
            reducer.hintState(for: .ready, hasWindowCandidates: false),
            .noCandidate
        )
        XCTAssertEqual(
            reducer.hintState(for: .displaySelection(nil), hasWindowCandidates: true),
            .display
        )
    }

    func testFEntersDisplayModeAndClickCapturesHoveredDisplay() {
        let display = ScreenshotDisplayCandidate(
            id: 99,
            frame: ScreenshotSelectionRect(x: -1920, y: 0, width: 1920, height: 1080)
        )
        let displayMode = reducer.reduce(
            state: .ready,
            event: .keyPressed(.displayMode, currentDisplay: nil)
        )

        XCTAssertEqual(displayMode.state, .displaySelection(nil))

        let hovered = reducer.reduce(
            state: displayMode.state,
            event: .displayHovered(display)
        )
        XCTAssertEqual(hovered.state, .displaySelection(display))

        let capture = reducer.reduce(
            state: hovered.state,
            event: .pointerUp(point: .init(x: -100, y: 100), windowCandidate: nil, resolvedRegion: nil)
        )

        XCTAssertEqual(capture.state, .capturing)
        XCTAssertEqual(capture.effects, [.captureDisplay(.displayID(99))])
    }

    func testFInitializesCurrentDisplaySoPointerUpCapturesWithoutMouseMove() {
        let display = ScreenshotDisplayCandidate(
            id: 77,
            frame: ScreenshotSelectionRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        let displayMode = reducer.reduce(
            state: .ready,
            event: .keyPressed(.displayMode, currentDisplay: display)
        )
        let capture = reducer.reduce(
            state: displayMode.state,
            event: .pointerUp(
                point: .init(x: 800, y: 500),
                windowCandidate: nil,
                resolvedRegion: nil
            )
        )

        XCTAssertEqual(displayMode.state, .displaySelection(display))
        XCTAssertEqual(capture.effects, [.captureDisplay(.displayID(77))])
    }

    func testShiftFImmediatelyCapturesAllDisplays() {
        let result = reducer.reduce(state: .windowPreview(.init(
            id: 1,
            frame: .init(x: 0, y: 0, width: 100, height: 100)
        )), event: .keyPressed(.allDisplays, currentDisplay: nil))

        XCTAssertEqual(result.state, .capturing)
        XCTAssertEqual(result.effects, [.captureDisplay(.all)])
    }

    func testMissingWindowCandidateNeverFallsBackToDisplayCapture() {
        let result = reducer.reduce(
            state: .ready,
            event: .pointerMoved(point: .init(x: 10, y: 20), windowCandidate: nil)
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(result.effects, [])
    }

    func testCaptureResultContainsResolvedKindAndStructuredTerminalOutcome() throws {
        let metadata = ScreenshotCaptureResultMetadata(
            captureID: "cap-1",
            kind: .display,
            displayScope: .all,
            pixelSize: .init(width: 3840, height: 2160),
            colorSpace: .sRGB
        )
        let completed = ScreenshotSessionOutcome.completed(metadata)

        let encoded = try JSONEncoder().encode(completed)
        let decoded = try JSONDecoder().decode(ScreenshotSessionOutcome.self, from: encoded)

        XCTAssertEqual(decoded, completed)
        XCTAssertEqual(ScreenshotSessionOutcome.cancelled, .cancelled)
        XCTAssertEqual(
            ScreenshotSessionOutcome.failed(.init(code: "capture_failed", message: "Capture failed")),
            .failed(.init(code: "capture_failed", message: "Capture failed"))
        )
    }

    func testRegionGeometryAppliesRatioFixedPixelsNudgeAndEdgeSnap() {
        let geometry = ScreenshotRegionGeometry()
        let rect = ScreenshotSelectionRect(x: 10, y: 20, width: 320, height: 300)

        XCTAssertEqual(
            geometry.constrain(rect, to: .ratio(width: 16, height: 9), outputScale: 2),
            .init(x: 10, y: 20, width: 320, height: 180)
        )
        XCTAssertEqual(
            geometry.constrain(rect, to: .fixedPixels(width: 800, height: 600), outputScale: 2),
            .init(x: 10, y: 20, width: 400, height: 300)
        )
        XCTAssertEqual(
            geometry.nudge(rect, outputPixelsX: 1, outputPixelsY: -10, outputScale: 2),
            .init(x: 10.5, y: 15, width: 320, height: 300)
        )
        XCTAssertEqual(
            geometry.snap(
                .init(x: 7, y: 12, width: 90, height: 85),
                verticalEdges: [0, 100],
                horizontalEdges: [10, 100],
                threshold: 4
            ),
            .init(x: 7, y: 10, width: 93, height: 90)
        )
    }

    func testAspectSelectionSwapsLandscapeAndPortraitDimensions() {
        let landscapeRatio = ScreenshotAspectSelection(
            orientation: .landscape,
            constraint: .ratio(width: 16, height: 9)
        )
        let portraitRatio = ScreenshotAspectSelection(
            orientation: .portrait,
            constraint: .ratio(width: 16, height: 9)
        )
        let landscapePixels = ScreenshotAspectSelection(
            orientation: .landscape,
            constraint: .fixedPixels(width: 600, height: 800)
        )
        let portraitPixels = ScreenshotAspectSelection(
            orientation: .portrait,
            constraint: .fixedPixels(width: 800, height: 600)
        )

        XCTAssertEqual(landscapeRatio.resolvedConstraint, .ratio(width: 16, height: 9))
        XCTAssertEqual(portraitRatio.resolvedConstraint, .ratio(width: 9, height: 16))
        XCTAssertEqual(landscapePixels.resolvedConstraint, .fixedPixels(width: 800, height: 600))
        XCTAssertEqual(portraitPixels.resolvedConstraint, .fixedPixels(width: 600, height: 800))
        XCTAssertEqual(
            ScreenshotAspectSelection(orientation: .portrait, constraint: .free).resolvedConstraint,
            .free
        )
    }

    func testAspectSelectionKeepsExistingGeometryInterfaceUsable() {
        let selection = ScreenshotAspectSelection(
            orientation: .portrait,
            constraint: .ratio(width: 16, height: 9)
        )
        let raw = ScreenshotSelectionRect(x: 10, y: 20, width: 320, height: 320)

        let constrained = ScreenshotRegionGeometry().constrain(
            raw,
            to: selection.resolvedConstraint,
            outputScale: 2
        )

        XCTAssertEqual(constrained.width / constrained.height, 9.0 / 16.0, accuracy: 0.000_001)
    }
}
