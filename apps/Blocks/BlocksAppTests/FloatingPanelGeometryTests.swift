import AppKit
import XCTest
@testable import Blocks

@MainActor
final class FloatingPanelGeometryTests: XCTestCase {
    func testBottomFrameRefreshesAgainstTheCurrentVisibleFrame() {
        let beforeDockChange = CGRect(x: -1_440, y: 24, width: 1_440, height: 876)
        let afterDockChange = CGRect(x: -1_440, y: 96, width: 1_440, height: 804)

        let before = FloatingPanelFrameStore.clipboardBottomFrame(
            visibleFrame: beforeDockChange,
            height: 320
        )
        let after = FloatingPanelFrameStore.clipboardBottomFrame(
            visibleFrame: afterDockChange,
            height: before.height
        )

        XCTAssertEqual(before.minY, beforeDockChange.minY)
        XCTAssertEqual(after.minY, afterDockChange.minY)
        XCTAssertEqual(after.width, afterDockChange.width)
        XCTAssertEqual(after.height, before.height)
    }

    func testScreenResolverPrefersTheDisplayContainingMostOfThePanel() {
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: -1_280, y: 0, width: 1_280, height: 800),
        ]

        XCTAssertEqual(
            FloatingPanelScreenResolver.screenIndex(
                containingMostOf: CGRect(x: -1_200, y: 32, width: 960, height: 300),
                screenFrames: screenFrames
            ),
            1
        )
        XCTAssertEqual(
            FloatingPanelScreenResolver.screenIndex(
                containingMostOf: CGRect(x: -180, y: 32, width: 1_000, height: 300),
                screenFrames: screenFrames
            ),
            0
        )
        XCTAssertNil(
            FloatingPanelScreenResolver.screenIndex(
                containingMostOf: CGRect(x: 2_000, y: 32, width: 320, height: 300),
                screenFrames: screenFrames
            )
        )
    }

    func testVisibleFrameObserverForwardsScreenParameterChangesAndStops() async {
        let center = NotificationCenter()
        let observer = FloatingPanelVisibleFrameObserver(notificationCenter: center)
        let forwarded = expectation(description: "screen parameters forwarded")

        observer.start {
            forwarded.fulfill()
        }
        XCTAssertTrue(observer.isObserving)

        center.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        await fulfillment(of: [forwarded], timeout: 1)

        observer.stop()
        XCTAssertFalse(observer.isObserving)
    }

    func testAppKitSurfaceBackingIsMaskedWhileItsHostKeepsShadowOverflow() {
        let surface = BlocksAppKitGlassSurfaceView(
            frame: CGRect(x: 0, y: 0, width: 240, height: 96)
        )
        surface.blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
            role: .panel,
            cornerRadius: 18,
            drawsShadow: true
        )
        surface.layoutSubtreeIfNeeded()

        guard let backing = surface.subviews.first else {
            return XCTFail("Expected the surface to install one clipped backing view.")
        }
        XCTAssertEqual(surface.layer?.cornerRadius, 18)
        XCTAssertFalse(surface.layer?.masksToBounds ?? true)
        XCTAssertEqual(backing.layer?.cornerRadius, 18)
        XCTAssertTrue(backing.layer?.masksToBounds ?? false)
    }
}
