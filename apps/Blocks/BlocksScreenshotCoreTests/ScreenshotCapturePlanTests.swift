import XCTest
@testable import BlocksScreenshotCore

final class ScreenshotCapturePlanTests: XCTestCase {
    private let planner = ScreenshotCapturePlanner()

    func testCrossDisplayRegionUsesHighestScaleAndPreservesNegativeCoordinates() throws {
        let displays = [
            ScreenshotDisplayDescriptor(
                id: 1,
                selectionFrame: .init(x: -1920, y: 0, width: 1920, height: 1080),
                backingScale: 1
            ),
            ScreenshotDisplayDescriptor(
                id: 2,
                selectionFrame: .init(x: 0, y: 0, width: 1440, height: 900),
                backingScale: 2
            ),
        ]

        let plan = try planner.planRegion(
            ScreenshotSelectionRect(x: -100, y: 0, width: 300, height: 100),
            displays: displays
        )

        XCTAssertEqual(plan.outputScale, 2)
        XCTAssertEqual(plan.outputSize, ScreenshotPixelSize(width: 600, height: 200))
        XCTAssertEqual(plan.slices.count, 2)
        XCTAssertEqual(
            plan.slices[0],
            ScreenshotCaptureSlice(
                displayID: 1,
                sourcePixels: .init(x: 1820, y: 980, width: 100, height: 100),
                destinationPixels: .init(x: 0, y: 0, width: 200, height: 200)
            )
        )
        XCTAssertEqual(
            plan.slices[1],
            ScreenshotCaptureSlice(
                displayID: 2,
                sourcePixels: .init(x: 0, y: 1600, width: 400, height: 200),
                destinationPixels: .init(x: 200, y: 0, width: 400, height: 200)
            )
        )
    }

    func testRegionSlicesUseTopLeftPixelCoordinates() throws {
        let display = ScreenshotDisplayDescriptor(
            id: 1,
            selectionFrame: .init(x: 0, y: 0, width: 100, height: 100),
            backingScale: 2
        )

        let plan = try planner.planRegion(
            ScreenshotSelectionRect(x: 0, y: 60, width: 100, height: 20),
            displays: [display]
        )

        XCTAssertEqual(plan.slices, [
            ScreenshotCaptureSlice(
                displayID: 1,
                sourcePixels: .init(x: 0, y: 40, width: 200, height: 40),
                destinationPixels: .init(x: 0, y: 0, width: 200, height: 40)
            ),
        ])
    }

    func testFractionalRegionQuantizesSharedEdgesInsteadOfRoundingOriginAndSizeSeparately() throws {
        let display = ScreenshotDisplayDescriptor(
            id: 1,
            selectionFrame: .init(x: 0, y: 0, width: 100, height: 100),
            backingScale: 2
        )

        let plan = try planner.planRegion(
            ScreenshotSelectionRect(x: 0.25, y: 0.25, width: 99.75, height: 99.75),
            displays: [display]
        )

        XCTAssertEqual(plan.outputSize, .init(width: 200, height: 200))
        XCTAssertEqual(plan.slices, [
            ScreenshotCaptureSlice(
                displayID: 1,
                sourcePixels: .init(x: 1, y: 0, width: 199, height: 200),
                destinationPixels: .init(x: 0, y: 0, width: 200, height: 200)
            ),
        ])
        XCTAssertLessThanOrEqual(
            plan.slices[0].sourcePixels.x + plan.slices[0].sourcePixels.width,
            200
        )
        XCTAssertLessThanOrEqual(
            plan.slices[0].sourcePixels.y + plan.slices[0].sourcePixels.height,
            200
        )
    }

    func testFractionalCrossDisplayBoundaryProducesAdjacentDestinationSlices() throws {
        let displays = [
            ScreenshotDisplayDescriptor(
                id: 1,
                selectionFrame: .init(x: 0, y: 0, width: 100.25, height: 100),
                backingScale: 2
            ),
            ScreenshotDisplayDescriptor(
                id: 2,
                selectionFrame: .init(x: 100.25, y: 0, width: 99.75, height: 100),
                backingScale: 2
            ),
        ]

        let plan = try planner.planRegion(
            ScreenshotSelectionRect(x: 0, y: 0, width: 200, height: 100),
            displays: displays
        )

        XCTAssertEqual(plan.outputSize, .init(width: 400, height: 200))
        XCTAssertEqual(plan.slices.count, 2)
        XCTAssertEqual(plan.slices[0].destinationPixels.x + plan.slices[0].destinationPixels.width,
                       plan.slices[1].destinationPixels.x)
        XCTAssertEqual(plan.slices[1].destinationPixels.x + plan.slices[1].destinationPixels.width,
                       plan.outputSize.width)
    }

    func testRegionOutputScaleUsesEveryIntersectingDisplayInsteadOfRegionCenter() throws {
        let displays = [
            ScreenshotDisplayDescriptor(
                id: 1,
                selectionFrame: .init(x: -1000, y: 0, width: 1000, height: 800),
                backingScale: 1
            ),
            ScreenshotDisplayDescriptor(
                id: 2,
                selectionFrame: .init(x: 0, y: 0, width: 1000, height: 800),
                backingScale: 2
            ),
        ]
        let region = ScreenshotSelectionRect(x: -900, y: 100, width: 1000, height: 400)

        XCTAssertEqual(try planner.outputScale(for: region, displays: displays), 2)
    }

    func testFixedPixelRegionResolvesScaleOscillationOnMixedDPIDisplays() throws {
        let displays = [
            ScreenshotDisplayDescriptor(
                id: 1,
                selectionFrame: .init(x: -1000, y: 0, width: 1000, height: 800),
                backingScale: 1
            ),
            ScreenshotDisplayDescriptor(
                id: 2,
                selectionFrame: .init(x: 0, y: 0, width: 1000, height: 800),
                backingScale: 2
            ),
        ]
        let raw = ScreenshotSelectionRect(x: -500, y: 100, width: 600, height: 400)

        let resolved = try ScreenshotRegionGeometry().resolveFixedPixelRegion(
            raw,
            width: 800,
            height: 600,
            displays: displays
        )
        let plan = try planner.planRegion(resolved.rect, displays: displays)

        XCTAssertEqual(resolved.outputScale, 2)
        XCTAssertEqual(plan.outputScale, resolved.outputScale)
        XCTAssertEqual(plan.outputSize, .init(width: 800, height: 600))
    }

    func testRegionOutsideKnownDisplaysFailsInsteadOfCapturingAFullDisplay() {
        let display = ScreenshotDisplayDescriptor(
            id: 1,
            selectionFrame: .init(x: 0, y: 0, width: 1000, height: 800),
            backingScale: 2
        )

        XCTAssertThrowsError(
            try planner.planRegion(
                ScreenshotSelectionRect(x: 2000, y: 2000, width: 100, height: 100),
                displays: [display]
            )
        ) { error in
            XCTAssertEqual(error as? ScreenshotCapturePlanError, .regionOutsideDisplays)
        }
    }

    func testOutputDimensionLimitIsFailClosed() {
        let display = ScreenshotDisplayDescriptor(
            id: 1,
            selectionFrame: .init(x: 0, y: 0, width: 20_000, height: 1_000),
            backingScale: 2
        )

        XCTAssertThrowsError(
            try planner.planRegion(display.selectionFrame, displays: [display])
        ) { error in
            XCTAssertEqual(error as? ScreenshotCapturePlanError, .outputDimensionExceeded)
        }
    }

    func testTotalPixelLimitIsFailClosed() {
        let display = ScreenshotDisplayDescriptor(
            id: 1,
            selectionFrame: .init(x: 0, y: 0, width: 12_000, height: 12_000),
            backingScale: 1
        )

        XCTAssertThrowsError(
            try planner.planRegion(display.selectionFrame, displays: [display])
        ) { error in
            XCTAssertEqual(error as? ScreenshotCapturePlanError, .outputPixelCountExceeded)
        }
    }

    func testAllDisplaysPreservesPhysicalLayoutAndTransparentGap() throws {
        let displays = [
            ScreenshotDisplayDescriptor(
                id: 1,
                selectionFrame: .init(x: 0, y: 0, width: 100, height: 100),
                backingScale: 1
            ),
            ScreenshotDisplayDescriptor(
                id: 2,
                selectionFrame: .init(x: 150, y: 20, width: 100, height: 100),
                backingScale: 1
            ),
        ]

        let plan = try planner.planDisplays(
            scope: .all,
            currentDisplayID: 1,
            displays: displays
        )

        XCTAssertEqual(plan.selectionRegion, .init(x: 0, y: 0, width: 250, height: 120))
        XCTAssertEqual(plan.outputSize, .init(width: 250, height: 120))
        XCTAssertEqual(plan.slices.map(\.destinationPixels), [
            .init(x: 0, y: 20, width: 100, height: 100),
            .init(x: 150, y: 0, width: 100, height: 100),
        ])
    }

    func testCurrentDisplayRequiresMatchingDescriptor() {
        let display = ScreenshotDisplayDescriptor(
            id: 1,
            selectionFrame: .init(x: 0, y: 0, width: 100, height: 100),
            backingScale: 2
        )

        XCTAssertThrowsError(
            try planner.planDisplays(scope: .current, currentDisplayID: 2, displays: [display])
        ) { error in
            XCTAssertEqual(error as? ScreenshotCapturePlanError, .displayNotFound)
        }
    }

    func testWindowPlanSlicesAcrossDisplaysAtHighestScale() throws {
        let displays = [
            ScreenshotDisplayDescriptor(
                id: 1,
                selectionFrame: .init(x: -1000, y: 0, width: 1000, height: 800),
                backingScale: 1
            ),
            ScreenshotDisplayDescriptor(
                id: 2,
                selectionFrame: .init(x: 0, y: 0, width: 1200, height: 900),
                backingScale: 2
            ),
        ]
        let window = ScreenshotWindowCandidate(
            id: 9,
            frame: .init(x: -100, y: 50, width: 500, height: 300)
        )

        let plan = try planner.planWindow(window, displays: displays)

        XCTAssertEqual(plan.selectionRegion, window.frame)
        XCTAssertEqual(plan.outputScale, 2)
        XCTAssertEqual(plan.outputSize, .init(width: 1000, height: 600))
        XCTAssertEqual(plan.slices.count, 2)
        XCTAssertEqual(plan.slices.map(\.displayID), [1, 2])
        XCTAssertEqual(plan.slices.map(\.destinationPixels), [
            .init(x: 0, y: 0, width: 200, height: 600),
            .init(x: 200, y: 0, width: 800, height: 600),
        ])
    }

    func testWindowPlanUsesExactWindowFrame() throws {
        let display = ScreenshotDisplayDescriptor(
            id: 1,
            selectionFrame: .init(x: 0, y: 0, width: 1_000, height: 800),
            backingScale: 2
        )
        let frame = ScreenshotSelectionRect(x: 200, y: 100, width: 400, height: 300)
        let window = ScreenshotWindowCandidate(
            id: 9,
            frame: frame
        )

        let plan = try planner.planWindow(window, displays: [display])

        XCTAssertEqual(plan.selectionRegion, frame)
        XCTAssertEqual(plan.outputSize, .init(width: 800, height: 600))
    }
}
